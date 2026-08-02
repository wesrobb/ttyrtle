const std = @import("std");
const win32 = @import("win32");
const workspace = @import("workspace.zig");

const foundation = win32.foundation;
const kernel32 = win32.kernel32;

/// Owns terminal tabs after the UI has detached them. The queue is intrusive:
/// closing a tab never has to allocate before returning to the message pump.
pub const Manager = struct {
    pub const worker_count = 4;

    allocator: std.mem.Allocator,
    completion_event: foundation.HANDLE,
    work_event: foundation.HANDLE,
    mutex: std.atomic.Mutex = .unlocked,
    head: ?*workspace.Tab = null,
    tail: ?*workspace.Tab = null,
    pending: usize = 0,
    stopping: bool = false,
    workers: [worker_count]?std.Thread = [_]?std.Thread{null} ** worker_count,

    pub fn init(self: *Manager, allocator: std.mem.Allocator, completion_event: foundation.HANDLE) !void {
        self.* = .{
            .allocator = allocator,
            .completion_event = completion_event,
            .work_event = kernel32.CreateEventW(null, 0, 0, null) orelse
                return error.CreateRetirementWorkEventFailed,
        };
        errdefer _ = kernel32.CloseHandle(self.work_event);
        errdefer self.stopAndJoin();
        for (&self.workers) |*slot| slot.* = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn deinit(self: *Manager) void {
        self.stopAndJoin();
        std.debug.assert(self.pending == 0);
        _ = kernel32.CloseHandle(self.work_event);
        self.* = undefined;
    }

    /// Returns false for a duplicate retirement request. The first request is
    /// the only owner permitted to hand this tab to a cleanup worker.
    pub fn enqueue(self: *Manager, item: *workspace.Tab) bool {
        self.lock();
        if (item.retiring) {
            self.mutex.unlock();
            return false;
        }
        std.debug.assert(!self.stopping);
        item.retiring = true;
        item.retirement_next = null;
        if (self.tail) |tail| tail.retirement_next = item else self.head = item;
        self.tail = item;
        self.pending += 1;
        self.mutex.unlock();
        _ = kernel32.SetEvent(self.work_event);
        return true;
    }

    pub fn pendingCount(self: *Manager) usize {
        self.lock();
        const result = self.pending;
        self.mutex.unlock();
        return result;
    }

    fn stopAndJoin(self: *Manager) void {
        self.lock();
        self.stopping = true;
        self.mutex.unlock();
        for (0..worker_count) |_| _ = kernel32.SetEvent(self.work_event);
        for (&self.workers) |*slot| if (slot.*) |thread| {
            thread.join();
            slot.* = null;
        };
    }

    fn take(self: *Manager) ?*workspace.Tab {
        while (true) {
            self.lock();
            if (self.head) |item| {
                self.head = item.retirement_next;
                if (self.head == null) self.tail = null;
                item.retirement_next = null;
                const more_work = self.head != null;
                self.mutex.unlock();
                if (more_work) _ = kernel32.SetEvent(self.work_event);
                return item;
            }
            const stopping = self.stopping;
            self.mutex.unlock();
            if (stopping) return null;
            _ = kernel32.WaitForSingleObject(self.work_event, std.math.maxInt(u32));
        }
    }

    fn finish(self: *Manager) void {
        self.lock();
        std.debug.assert(self.pending > 0);
        self.pending -= 1;
        self.mutex.unlock();
        _ = kernel32.SetEvent(self.completion_event);
    }

    fn lock(self: *Manager) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn workerMain(self: *Manager) void {
        while (self.take()) |item| {
            // ConPTY joins, process waits, and terminal model destruction are
            // intentionally all off the UI thread.
            item.deinit(self.allocator);
            self.allocator.destroy(item);
            self.finish();
        }
    }
};
