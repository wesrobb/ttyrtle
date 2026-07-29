const std = @import("std");

pub const InputQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) InputQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InputQueue) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        self.mutex.unlock(io);
        self.* = undefined;
    }

    /// Takes ownership of `bytes`. Ordering is preserved across producers.
    pub fn pushOwned(self: *InputQueue, bytes: []u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.closed) return error.Closed;
        try self.chunks.append(self.allocator, bytes);
        self.ready.signal(io);
    }

    /// Blocks until input is available or the queue is closed. The caller
    /// owns a returned chunk.
    pub fn take(self: *InputQueue) ?[]u8 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (self.chunks.items.len == 0 and !self.closed)
            self.ready.waitUncancelable(io, &self.mutex);
        if (self.chunks.items.len == 0) return null;
        return self.chunks.orderedRemove(0);
    }

    pub fn close(self: *InputQueue) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.ready.broadcast(io);
        self.mutex.unlock(io);
    }
};

test "input queue preserves owned byte order and closes cleanly" {
    var queue = InputQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.pushOwned(try std.testing.allocator.dupe(u8, "first"));
    try queue.pushOwned(try std.testing.allocator.dupe(u8, "second"));
    queue.close();

    const first = queue.take().?;
    defer std.testing.allocator.free(first);
    const second = queue.take().?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("first", first);
    try std.testing.expectEqualStrings("second", second);
    try std.testing.expect(queue.take() == null);
}

test "closed input queue rejects new ownership" {
    var queue = InputQueue.init(std.testing.allocator);
    defer queue.deinit();
    queue.close();

    const bytes = try std.testing.allocator.dupe(u8, "late");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.Closed, queue.pushOwned(bytes));
}

test "input queue wakes a blocked consumer thread" {
    const Context = struct {
        queue: *InputQueue,
        received: ?[]u8 = null,

        fn consume(context: *@This()) void {
            context.received = context.queue.take();
        }
    };

    var queue = InputQueue.init(std.testing.allocator);
    defer queue.deinit();
    var context: Context = .{ .queue = &queue };
    const thread = try std.Thread.spawn(.{}, Context.consume, .{&context});
    try queue.pushOwned(try std.testing.allocator.dupe(u8, "wake"));
    thread.join();

    const received = context.received.?;
    defer std.testing.allocator.free(received);
    try std.testing.expectEqualStrings("wake", received);
}
