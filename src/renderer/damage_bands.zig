const std = @import("std");

pub const RowOverhang = struct {
    above: u16 = 0,
    below: u16 = 0,
};

pub const Band = struct {
    destination_first: u16,
    destination_end: u16,
    source_first: u16,
    source_end: u16,
};

/// Converts DirectWrite's positive, outside-the-layout overhang to terminal
/// rows. One physical pixel is included for rasterization hinting and AA.
pub fn overhangRows(reported_dip: f32, cell_height_pixels: u32, dpi: u32) u16 {
    const scale = 96.0 / @as(f32, @floatFromInt(@max(dpi, 1)));
    const guarded = @max(0.0, reported_dip + scale);
    const cell_height_dip = @as(f32, @floatFromInt(@max(cell_height_pixels, 1))) * scale;
    return @intFromFloat(@ceil(guarded / cell_height_dip));
}

/// Builds merged destination bands and the rows whose ink can contribute to
/// each band. `pending` contains the newly measured values for dirty rows.
pub fn build(
    allocator: std.mem.Allocator,
    dirty: []const bool,
    retained: []const RowOverhang,
    pending: []const RowOverhang,
    scene_max: RowOverhang,
    output: *std.ArrayListUnmanaged(Band),
) !void {
    output.clearRetainingCapacity();
    const row_count = @min(dirty.len, @min(retained.len, pending.len));
    for (dirty[0..row_count], 0..) |is_dirty, row| {
        if (!is_dirty) continue;
        const above = @max(retained[row].above, pending[row].above);
        const below = @max(retained[row].below, pending[row].below);
        const first: u16 = @intCast(row -| @as(usize, above));
        const end: u16 = @intCast(@min(row_count, row + 1 + @as(usize, below)));

        if (output.items.len != 0) {
            const previous = &output.items[output.items.len - 1];
            if (first < previous.destination_end) {
                previous.destination_end = @max(previous.destination_end, end);
                continue;
            }
        }
        try output.append(allocator, .{
            .destination_first = first,
            .destination_end = end,
            .source_first = 0,
            .source_end = 0,
        });
    }

    for (output.items) |*band| {
        band.source_first = band.destination_first -| scene_max.below;
        band.source_end = @intCast(@min(
            row_count,
            @as(usize, band.destination_end) + scene_max.above,
        ));
    }
}

test "overhang conversion includes one physical pixel guard" {
    try std.testing.expectEqual(@as(u16, 1), overhangRows(0, 20, 96));
    try std.testing.expectEqual(@as(u16, 0), overhangRows(-1, 20, 96));
    try std.testing.expectEqual(@as(u16, 1), overhangRows(19, 20, 96));
    try std.testing.expectEqual(@as(u16, 2), overhangRows(20, 20, 96));
    try std.testing.expectEqual(@as(u16, 1), overhangRows(0, 40, 192));
}

test "bands clamp viewport edges and preserve asymmetric source expansion" {
    const retained = [_]RowOverhang{.{}} ** 5;
    var pending = retained;
    pending[0] = .{ .above = 3, .below = 1 };
    const dirty = [_]bool{ true, false, false, false, false };
    var bands: std.ArrayListUnmanaged(Band) = .empty;
    defer bands.deinit(std.testing.allocator);
    try build(std.testing.allocator, &dirty, &retained, &pending, .{
        .above = 2,
        .below = 1,
    }, &bands);
    try std.testing.expectEqualSlices(Band, &.{.{
        .destination_first = 0,
        .destination_end = 2,
        .source_first = 0,
        .source_end = 4,
    }}, bands.items);
}

test "sparse damage remains separate and overlapping damage bands merge" {
    const retained = [_]RowOverhang{.{}} ** 8;
    var pending = retained;
    pending[1] = .{ .above = 1, .below = 1 };
    pending[3] = .{ .above = 1, .below = 1 };
    pending[7] = .{ .above = 0, .below = 2 };
    const dirty = [_]bool{ false, true, false, true, false, false, false, true };
    var bands: std.ArrayListUnmanaged(Band) = .empty;
    defer bands.deinit(std.testing.allocator);
    try build(std.testing.allocator, &dirty, &retained, &pending, .{
        .above = 1,
        .below = 1,
    }, &bands);
    try std.testing.expectEqualSlices(Band, &.{
        .{ .destination_first = 0, .destination_end = 5, .source_first = 0, .source_end = 6 },
        .{ .destination_first = 7, .destination_end = 8, .source_first = 6, .source_end = 8 },
    }, bands.items);
}

test "old overhang expands a row whose replacement no longer overhangs" {
    var retained = [_]RowOverhang{.{}} ** 4;
    retained[2] = .{ .above = 2, .below = 0 };
    const pending = [_]RowOverhang{.{}} ** 4;
    const dirty = [_]bool{ false, false, true, false };
    var bands: std.ArrayListUnmanaged(Band) = .empty;
    defer bands.deinit(std.testing.allocator);
    try build(std.testing.allocator, &dirty, &retained, &pending, .{}, &bands);
    try std.testing.expectEqual(@as(u16, 0), bands.items[0].destination_first);
    try std.testing.expectEqual(@as(u16, 3), bands.items[0].destination_end);
}
