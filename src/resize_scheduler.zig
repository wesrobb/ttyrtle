/// Coalesces expensive renderer-target changes during Win32 interactive sizing.
/// Terminal dimensions remain synchronous; this owns only pixel surface work.
const std = @import("std");

pub const SurfaceSize = struct {
    width: u32,
    height: u32,
    dpi: u32,
};

pub const Scheduler = struct {
    interactive: bool = false,
    timer_armed: bool = false,
    pending: ?SurfaceSize = null,

    pub const Request = union(enum) {
        immediate: SurfaceSize,
        queued: struct { arm_timer: bool },
    };

    pub fn enter(self: *Scheduler) void {
        self.interactive = true;
    }

    pub fn request(self: *Scheduler, size: SurfaceSize) Request {
        if (!self.interactive) return .{ .immediate = size };
        self.pending = size;
        const arm_timer = !self.timer_armed;
        self.timer_armed = true;
        return .{ .queued = .{ .arm_timer = arm_timer } };
    }

    pub fn onTimer(self: *Scheduler) ?SurfaceSize {
        self.timer_armed = false;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    pub fn exit(self: *Scheduler) ?SurfaceSize {
        self.interactive = false;
        self.timer_armed = false;
        const pending = self.pending;
        self.pending = null;
        return pending;
    }

    pub fn cancel(self: *Scheduler) void {
        self.timer_armed = false;
        self.pending = null;
    }
};

test "non-interactive requests apply immediately" {
    var scheduler: Scheduler = .{};
    const requested: SurfaceSize = .{ .width = 80, .height = 24, .dpi = 96 };
    switch (scheduler.request(requested)) {
        .immediate => |size| try std.testing.expectEqual(requested, size),
        .queued => return error.UnexpectedQueuedResize,
    }
}

test "interactive requests retain only the latest surface and arm once" {
    var scheduler: Scheduler = .{};
    scheduler.enter();
    try std.testing.expect(switch (scheduler.request(.{ .width = 1, .height = 2, .dpi = 96 })) {
        .queued => |request| request.arm_timer,
        else => false,
    });
    try std.testing.expect(switch (scheduler.request(.{ .width = 3, .height = 4, .dpi = 96 })) {
        .queued => |request| !request.arm_timer,
        else => false,
    });
    try std.testing.expectEqual(SurfaceSize{ .width = 3, .height = 4, .dpi = 96 }, scheduler.onTimer().?);
    try std.testing.expect(scheduler.onTimer() == null);
}

test "exit flushes pending interactive surface" {
    var scheduler: Scheduler = .{};
    scheduler.enter();
    _ = scheduler.request(.{ .width = 11, .height = 12, .dpi = 144 });
    try std.testing.expectEqual(SurfaceSize{ .width = 11, .height = 12, .dpi = 144 }, scheduler.exit().?);
    try std.testing.expect(!scheduler.interactive);
    try std.testing.expect(!scheduler.timer_armed);
}

test "cancel clears pending resize without leaving interactive sizing" {
    var scheduler: Scheduler = .{};
    scheduler.enter();
    _ = scheduler.request(.{ .width = 11, .height = 12, .dpi = 144 });
    scheduler.cancel();
    try std.testing.expect(scheduler.interactive);
    try std.testing.expect(!scheduler.timer_armed);
    try std.testing.expect(scheduler.pending == null);
}
