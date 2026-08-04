const std = @import("std");

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

pub fn exceededThreshold(anchor: Point, point: Point, horizontal: i32, vertical: i32) bool {
    return @abs(point.x - anchor.x) >= @max(horizontal, 1) or
        @abs(point.y - anchor.y) >= @max(vertical, 1);
}

pub fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.left and point.x < rect.right and
        point.y >= rect.top and point.y < rect.bottom;
}

/// Returns a boundary in `[0, items.len]`. Item rectangles are clipped to the
/// control rectangle so partially visible native tabs cannot create slots in
/// the overflow-button area.
pub fn insertionSlot(control: Rect, items: []const Rect, point: Point) ?usize {
    if (!contains(control, point)) return null;
    if (items.len == 0) return 0;
    for (items, 0..) |item, index| {
        const left = @max(item.left, control.left);
        const right = @min(item.right, control.right);
        if (right <= left) continue;
        if (point.x < left + @divTrunc(right - left, 2)) return index;
    }
    return items.len;
}

pub fn localIndexForSlot(current_index: usize, slot: usize, count: usize) usize {
    if (count == 0) return 0;
    const adjusted = if (slot > current_index) slot - 1 else slot;
    return @min(adjusted, count - 1);
}

/// Tear-out is armed only after the pointer clears the source rectangle by a
/// full drag threshold in at least one axis.
pub fn tearOutArmed(source: Rect, point: Point, horizontal: i32, vertical: i32) bool {
    const outside_x = if (point.x < source.left)
        source.left - point.x
    else if (point.x >= source.right)
        point.x - source.right + 1
    else
        0;
    const outside_y = if (point.y < source.top)
        source.top - point.y
    else if (point.y >= source.bottom)
        point.y - source.bottom + 1
    else
        0;
    return outside_x >= @max(horizontal, 1) or outside_y >= @max(vertical, 1);
}

pub fn scale(value: i32, from_dpi: u32, to_dpi: u32) i32 {
    if (from_dpi == 0) return value;
    return @intCast(@divTrunc(
        @as(i64, value) * @as(i64, to_dpi) + @as(i64, from_dpi / 2),
        @as(i64, from_dpi),
    ));
}

pub fn clampToWorkArea(rect: Rect, work: Rect, minimum_visible_width: i32, minimum_visible_height: i32) Rect {
    const width = @min(rect.right - rect.left, work.right - work.left);
    const height = @min(rect.bottom - rect.top, work.bottom - work.top);
    const visible_width = @min(@max(minimum_visible_width, 1), width);
    const visible_height = @min(@max(minimum_visible_height, 1), height);
    const left = std.math.clamp(rect.left, work.left - width + visible_width, work.right - visible_width);
    const top = std.math.clamp(rect.top, work.top, work.bottom - visible_height);
    return .{ .left = left, .top = top, .right = left + width, .bottom = top + height };
}

test "drag threshold uses independent horizontal and vertical metrics" {
    const anchor: Point = .{ .x = 10, .y = 10 };
    try std.testing.expect(!exceededThreshold(anchor, .{ .x = 13, .y = 15 }, 4, 6));
    try std.testing.expect(exceededThreshold(anchor, .{ .x = 14, .y = 10 }, 4, 6));
    try std.testing.expect(exceededThreshold(anchor, .{ .x = 10, .y = 16 }, 4, 6));
}

test "insertion slots cover clipped items whitespace and empty strips" {
    const control: Rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 20 };
    const items = [_]Rect{
        .{ .left = -10, .top = 0, .right = 30, .bottom = 20 },
        .{ .left = 30, .top = 0, .right = 70, .bottom = 20 },
        .{ .left = 70, .top = 0, .right = 120, .bottom = 20 },
    };
    try std.testing.expectEqual(@as(?usize, 0), insertionSlot(control, &items, .{ .x = 1, .y = 2 }));
    try std.testing.expectEqual(@as(?usize, 1), insertionSlot(control, &items, .{ .x = 29, .y = 2 }));
    try std.testing.expectEqual(@as(?usize, 2), insertionSlot(control, &items, .{ .x = 51, .y = 2 }));
    try std.testing.expectEqual(@as(?usize, 3), insertionSlot(control, &items, .{ .x = 99, .y = 2 }));
    try std.testing.expectEqual(@as(?usize, 0), insertionSlot(control, &.{}, .{ .x = 4, .y = 2 }));
    try std.testing.expectEqual(@as(?usize, null), insertionSlot(control, &items, .{ .x = 100, .y = 2 }));
}

test "same source slot adjustment works in both directions" {
    try std.testing.expectEqual(@as(usize, 3), localIndexForSlot(1, 4, 4));
    try std.testing.expectEqual(@as(usize, 0), localIndexForSlot(3, 0, 4));
    try std.testing.expectEqual(@as(usize, 1), localIndexForSlot(1, 2, 4));
}

test "tear out arms outside threshold and disarms on reentry" {
    const source: Rect = .{ .left = 10, .top = 10, .right = 110, .bottom = 40 };
    try std.testing.expect(!tearOutArmed(source, .{ .x = 20, .y = 42 }, 4, 4));
    try std.testing.expect(tearOutArmed(source, .{ .x = 20, .y = 44 }, 4, 4));
    try std.testing.expect(!tearOutArmed(source, .{ .x = 20, .y = 20 }, 4, 4));
}

test "DPI scaling and negative-coordinate work-area clamping are stable" {
    try std.testing.expectEqual(@as(i32, 150), scale(100, 96, 144));
    try std.testing.expectEqual(@as(i32, 200), scale(100, 96, 192));
    const clamped = clampToWorkArea(
        .{ .left = -2400, .top = -300, .right = -1400, .bottom = 500 },
        .{ .left = -1920, .top = 0, .right = 0, .bottom = 1080 },
        120,
        40,
    );
    try std.testing.expectEqual(@as(i32, -2400), clamped.left);
    try std.testing.expectEqual(@as(i32, 0), clamped.top);
    try std.testing.expectEqual(@as(i32, -1400), clamped.right);
}
