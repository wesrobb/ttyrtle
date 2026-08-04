const std = @import("std");
const frame_trace = @import("frame_trace.zig");

pub const read_chunk_bytes = 16 * 1024;
pub const ui_batch_bytes = 256 * 1024;
pub const backlog_bytes = 1024 * 1024;

pub const Failure = union(enum) {
    out_of_memory,
    read_file: u32,
    post_message: u32,
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged([]u8),
    byte_count: usize,
    oldest_enqueue_timestamp: i64,
    continuation_required: bool,
    finished: bool,
    failure: ?Failure,

    pub fn deinit(self: *Batch) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Diagnostics = struct {
    queued_bytes: usize,
    maximum_backlog: usize,
    abandoned: bool,
};

pub const OutputQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    space_available: std.Io.Condition = .init,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    enqueue_timestamps: std.ArrayListUnmanaged(i64) = .empty,
    queued_bytes: usize = 0,
    maximum_backlog: usize = 0,
    notification_posted: bool = false,
    finished: bool = false,
    abandoned: bool = false,
    failure: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator) OutputQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OutputQueue) void {
        self.abandon();
        self.chunks.deinit(self.allocator);
        self.enqueue_timestamps.deinit(self.allocator);
        self.* = undefined;
    }

    /// Copies one ConPTY read into the queue. A producer may exceed the bound
    /// by this one read, then waits until the UI drains space.
    pub fn push(self: *OutputQueue, bytes: []const u8) !bool {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.queued_bytes >= backlog_bytes and !self.abandoned)
            self.space_available.waitUncancelable(io, &self.mutex);
        if (self.abandoned) return error.Closed;

        try self.chunks.append(self.allocator, owned);
        errdefer _ = self.chunks.pop();
        try self.enqueue_timestamps.append(self.allocator, frame_trace.timestamp());
        self.queued_bytes += owned.len;
        self.maximum_backlog = @max(self.maximum_backlog, self.queued_bytes);
        return self.claimNotification();
    }

    pub fn finish(self: *OutputQueue, failure: ?Failure) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.abandoned) return false;
        self.finished = true;
        self.failure = failure;
        return self.claimNotification();
    }

    /// Transfers an ordered prefix. The target can be exceeded by at most one
    /// producer read chunk, and a non-empty queue always yields progress.
    pub fn drainUpTo(self: *OutputQueue, max_bytes: usize) !Batch {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var count: usize = 0;
        var bytes: usize = 0;
        while (count < self.chunks.items.len) : (count += 1) {
            if (count != 0 and bytes >= max_bytes) break;
            bytes += self.chunks.items[count].len;
        }
        var transferred: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer transferred.deinit(self.allocator);
        try transferred.appendSlice(self.allocator, self.chunks.items[0..count]);
        const oldest = if (count == 0) 0 else self.enqueue_timestamps.items[0];

        const remaining = self.chunks.items.len - count;
        std.mem.copyForwards([]u8, self.chunks.items[0..remaining], self.chunks.items[count..]);
        std.mem.copyForwards(i64, self.enqueue_timestamps.items[0..remaining], self.enqueue_timestamps.items[count..]);
        self.chunks.shrinkRetainingCapacity(remaining);
        self.enqueue_timestamps.shrinkRetainingCapacity(remaining);
        self.queued_bytes -= bytes;
        const continuation = remaining != 0;
        if (!continuation) self.notification_posted = false;
        if (bytes != 0) self.space_available.broadcast(io);
        return .{
            .allocator = self.allocator,
            .chunks = transferred,
            .byte_count = bytes,
            .oldest_enqueue_timestamp = oldest,
            .continuation_required = continuation,
            .finished = self.finished and !continuation,
            .failure = self.failure,
        };
    }

    pub fn abandon(self: *OutputQueue) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        if (!self.abandoned) {
            self.abandoned = true;
            for (self.chunks.items) |chunk| self.allocator.free(chunk);
            self.chunks.clearRetainingCapacity();
            self.enqueue_timestamps.clearRetainingCapacity();
            self.queued_bytes = 0;
            self.notification_posted = false;
            self.space_available.broadcast(io);
        }
        self.mutex.unlock(io);
    }

    pub fn diagnostics(self: *OutputQueue) Diagnostics {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .queued_bytes = self.queued_bytes,
            .maximum_backlog = self.maximum_backlog,
            .abandoned = self.abandoned,
        };
    }

    fn claimNotification(self: *OutputQueue) bool {
        if (self.notification_posted) return false;
        self.notification_posted = true;
        return true;
    }
};

test "limited drains preserve order ownership and final semantics" {
    var queue = OutputQueue.init(std.testing.allocator);
    defer queue.deinit();
    try std.testing.expect(try queue.push("first"));
    try std.testing.expect(!(try queue.push("second")));
    try std.testing.expect(!queue.finish(null));

    var first = try queue.drainUpTo(1);
    defer first.deinit();
    try std.testing.expectEqualStrings("first", first.chunks.items[0]);
    try std.testing.expect(first.continuation_required);
    try std.testing.expect(!first.finished);

    var second = try queue.drainUpTo(1);
    defer second.deinit();
    try std.testing.expectEqualStrings("second", second.chunks.items[0]);
    try std.testing.expect(!second.continuation_required);
    try std.testing.expect(second.finished);
}

test "abandoned output queue rejects future pushes" {
    var queue = OutputQueue.init(std.testing.allocator);
    defer queue.deinit();
    queue.abandon();
    try std.testing.expectError(error.Closed, queue.push("late"));
}

test "draining releases a producer waiting for queue space" {
    var queue = OutputQueue.init(std.testing.allocator);
    defer queue.deinit();
    const fill = try std.testing.allocator.alloc(u8, backlog_bytes);
    defer std.testing.allocator.free(fill);
    @memset(fill, 'x');
    _ = try queue.push(fill);

    const Context = struct {
        queue: *OutputQueue,
        pushed: bool = false,
        fn run(context: *@This()) void {
            _ = context.queue.push("released") catch return;
            context.pushed = true;
        }
    };
    var context: Context = .{ .queue = &queue };
    const producer = try std.Thread.spawn(.{}, Context.run, .{&context});
    var first = try queue.drainUpTo(backlog_bytes);
    defer first.deinit();
    producer.join();
    try std.testing.expect(context.pushed);
}

test "abandon releases a producer waiting for queue space" {
    var queue = OutputQueue.init(std.testing.allocator);
    defer queue.deinit();
    const fill = try std.testing.allocator.alloc(u8, backlog_bytes);
    defer std.testing.allocator.free(fill);
    @memset(fill, 'x');
    _ = try queue.push(fill);

    const Context = struct {
        queue: *OutputQueue,
        closed: bool = false,
        fn run(context: *@This()) void {
            _ = context.queue.push("blocked") catch |err| {
                context.closed = err == error.Closed;
                return;
            };
        }
    };
    var context: Context = .{ .queue = &queue };
    const producer = try std.Thread.spawn(.{}, Context.run, .{&context});
    queue.abandon();
    producer.join();
    try std.testing.expect(context.closed);
}
