const std = @import("std");

pub const Failure = union(enum) {
    out_of_memory,
    read_file: u32,
    post_message: u32,
};

pub const Batch = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayListUnmanaged([]u8),
    finished: bool,
    failure: ?Failure,

    pub fn deinit(self: *Batch) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const OutputQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    notification_posted: bool = false,
    finished: bool = false,
    failure: ?Failure = null,

    pub fn init(allocator: std.mem.Allocator) OutputQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OutputQueue) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);

        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        self.mutex.unlock(io);
        self.* = undefined;
    }

    /// Copies bytes into the queue. The return value tells the producer whether
    /// it must post the UI notification.
    pub fn push(self: *OutputQueue, bytes: []const u8) !bool {
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        try self.chunks.append(self.allocator, owned);
        return self.claimNotification();
    }

    /// Records reader completion and wakes the UI even when there are no
    /// remaining bytes.
    pub fn finish(self: *OutputQueue, failure: ?Failure) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.finished = true;
        self.failure = failure;
        return self.claimNotification();
    }

    /// Transfers all currently queued chunks to the caller in insertion order.
    /// Clearing the notification flag while holding the mutex ensures that a
    /// producer racing with this drain posts a fresh notification.
    pub fn drain(self: *OutputQueue) Batch {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const batch: Batch = .{
            .allocator = self.allocator,
            .chunks = self.chunks,
            .finished = self.finished,
            .failure = self.failure,
        };
        self.chunks = .empty;
        self.notification_posted = false;
        return batch;
    }

    fn claimNotification(self: *OutputQueue) bool {
        if (self.notification_posted) return false;
        self.notification_posted = true;
        return true;
    }
};

test "output queue preserves byte chunk order and coalesces notifications" {
    var queue = OutputQueue.init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(try queue.push("first"));
    try std.testing.expect(!(try queue.push("second")));

    var batch = queue.drain();
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 2), batch.chunks.items.len);
    try std.testing.expectEqualStrings("first", batch.chunks.items[0]);
    try std.testing.expectEqualStrings("second", batch.chunks.items[1]);
    try std.testing.expect(!batch.finished);
}

test "output arriving after a drain requests another notification" {
    var queue = OutputQueue.init(std.testing.allocator);
    defer queue.deinit();

    _ = try queue.push("before");
    var first = queue.drain();
    defer first.deinit();

    try std.testing.expect(try queue.push("after"));
    try std.testing.expect(!queue.finish(null));

    var second = queue.drain();
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.chunks.items.len);
    try std.testing.expectEqualStrings("after", second.chunks.items[0]);
    try std.testing.expect(second.finished);
}
