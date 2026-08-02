const geometry = @import("geometry.zig");

/// Owns the policy for live sizing.  The window surface follows every message,
/// while the terminal model is deliberately advanced by a low-priority timer.
/// Keeping this state free of Win32 makes the cancellation rules testable.
pub const ResizeCoordinator = struct {
    latest_surface: ?Surface = null,
    latest_grid: ?geometry.Dimensions = null,
    applied_grid: ?geometry.Dimensions = null,
    generation: u64 = 0,
    interactive: bool = false,
    timer_armed: bool = false,
    build_active: bool = false,

    pub const Surface = struct { width: u32, height: u32, dpi: u32 };

    pub fn enter(self: *ResizeCoordinator) void {
        self.interactive = true;
    }

    /// Returns true only when a fresh grid generation needs timer work.
    pub fn request(self: *ResizeCoordinator, surface: Surface, grid: ?geometry.Dimensions) bool {
        self.latest_surface = surface;
        if (sameGrid(self.latest_grid, grid)) return false;
        self.latest_grid = grid;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.build_active = false;
        self.timer_armed = grid != null;
        return grid != null;
    }

    pub fn beginLatest(self: *ResizeCoordinator) ?geometry.Dimensions {
        const grid = self.latest_grid orelse return null;
        self.applied_grid = grid;
        self.build_active = true;
        return grid;
    }

    pub fn finishBuild(self: *ResizeCoordinator) void {
        self.build_active = false;
        self.timer_armed = self.interactive and !sameGrid(self.applied_grid, self.latest_grid);
    }

    pub fn leave(self: *ResizeCoordinator) void {
        self.interactive = false;
        self.timer_armed = !sameGrid(self.applied_grid, self.latest_grid);
    }

    pub fn cancel(self: *ResizeCoordinator) void {
        if (self.build_active) {
            self.generation +%= 1;
            if (self.generation == 0) self.generation = 1;
        }
        self.build_active = false;
        self.timer_armed = self.latest_grid != null;
    }
};

fn sameGrid(a: ?geometry.Dimensions, b: ?geometry.Dimensions) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.rows == b.?.rows and a.?.columns == b.?.columns;
}

test "interactive resize coalesces crossed cells and starts latest generation" {
    var coordinator: ResizeCoordinator = .{};
    coordinator.enter();
    try @import("std").testing.expect(coordinator.request(.{ .width = 800, .height = 600, .dpi = 96 }, .{ .rows = 24, .columns = 80 }));
    try @import("std").testing.expect(!coordinator.request(.{ .width = 801, .height = 600, .dpi = 96 }, .{ .rows = 24, .columns = 80 }));
    try @import("std").testing.expect(coordinator.request(.{ .width = 900, .height = 600, .dpi = 96 }, .{ .rows = 24, .columns = 90 }));
    try @import("std").testing.expectEqual(@as(u64, 2), coordinator.generation);
    try @import("std").testing.expectEqual(@as(u16, 90), coordinator.beginLatest().?.columns);
}

test "completed generation is coherent and a newer request cancels it" {
    var coordinator: ResizeCoordinator = .{};
    _ = coordinator.request(.{ .width = 800, .height = 600, .dpi = 96 }, .{ .rows = 24, .columns = 80 });
    _ = coordinator.beginLatest();
    coordinator.finishBuild();
    try @import("std").testing.expect(!coordinator.build_active);
    coordinator.enter();
    _ = coordinator.request(.{ .width = 900, .height = 600, .dpi = 96 }, .{ .rows = 24, .columns = 90 });
    _ = coordinator.beginLatest();
    coordinator.cancel();
    try @import("std").testing.expect(!coordinator.build_active);
    try @import("std").testing.expect(coordinator.timer_armed);
}
