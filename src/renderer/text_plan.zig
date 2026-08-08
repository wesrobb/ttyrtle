const std = @import("std");

/// All device-independent inputs which determine a complete row layout.
/// Colors, selection, cursor state, row position, and device generation are
/// deliberately absent.
pub const RowKeyView = struct {
    hash: u64,
    layout_width: u32,
    layout_height: u32,
    dpi: u32,
    font_generation: u64,
    fallback_generation: u64,
    typography_generation: u64,
    text: []const u16,
    cell_widths: []const u8,

    pub fn eql(self: RowKeyView, other: RowKeyView) bool {
        return self.hash == other.hash and
            self.layout_width == other.layout_width and
            self.layout_height == other.layout_height and
            self.dpi == other.dpi and
            self.font_generation == other.font_generation and
            self.fallback_generation == other.fallback_generation and
            self.typography_generation == other.typography_generation and
            std.mem.eql(u16, self.text, other.text) and
            std.mem.eql(u8, self.cell_widths, other.cell_widths);
    }
};

pub fn fingerprint(text: []const u16, cell_widths: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (text) |unit| {
        hash ^= unit;
        hash *%= 0x100000001b3;
    }
    hash ^= 0xff;
    hash *%= 0x100000001b3;
    for (cell_widths) |width| {
        hash ^= width;
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// Select the oldest entry, breaking equal timestamps by stable slot order.
pub fn leastRecentlyUsed(timestamps: []const u64) ?usize {
    if (timestamps.len == 0) return null;
    var oldest: usize = 0;
    for (timestamps[1..], 1..) |timestamp, index| {
        if (timestamp < timestamps[oldest]) oldest = index;
    }
    return oldest;
}

pub fn characterSpacing(grid_advance: f32, shaped_advance: f32, hit_count: u32) f32 {
    std.debug.assert(hit_count != 0);
    return (grid_advance - shaped_advance) / @as(f32, @floatFromInt(hit_count));
}

pub const Measurement = struct {
    advance: f32,
    hit_count: u32,
};

pub const SpacingAdjustment = struct {
    text_start: u32,
    text_length: u32,
    trailing_spacing: f32,
};

/// Measure the untouched row first, then apply every accumulated adjustment.
/// Keeping the mutation loop separate is important: DirectWrite invalidates a
/// layout after SetCharacterSpacing, so interleaving these operations reshapes
/// the remaining graphemes over and over.
pub fn measureThenApplySpacing(
    graphemes: anytype,
    cell_widths: []const u8,
    cell_width: f32,
    adjustments: *std.ArrayListUnmanaged(SpacingAdjustment),
    allocator: std.mem.Allocator,
    context: anytype,
    comptime measure_fn: anytype,
    comptime apply_fn: anytype,
) !void {
    adjustments.clearRetainingCapacity();
    for (graphemes, 0..) |grapheme, index| {
        const measurement = try measure_fn(
            context,
            @intCast(grapheme.text_start),
            @intCast(grapheme.text_len),
        );
        try adjustments.append(allocator, .{
            .text_start = @intCast(grapheme.text_start),
            .text_length = @intCast(grapheme.text_len),
            .trailing_spacing = characterSpacing(
                @as(f32, @floatFromInt(cell_widths[index])) * cell_width,
                measurement.advance,
                measurement.hit_count,
            ),
        });
    }
    for (adjustments.items) |adjustment| try apply_fn(context, adjustment);
}

test "row layout key ignores visual and positional state" {
    const text = std.unicode.utf8ToUtf16LeStringLiteral("A界");
    const widths = [_]u8{ 1, 2 };
    const key: RowKeyView = .{
        .hash = fingerprint(text, &widths),
        .layout_width = 80,
        .layout_height = 20,
        .dpi = 96,
        .font_generation = 2,
        .fallback_generation = 3,
        .typography_generation = 4,
        .text = text,
        .cell_widths = &widths,
    };
    try std.testing.expect(key.eql(key));
}

test "row layout key changes for every shaping input" {
    const text = std.unicode.utf8ToUtf16LeStringLiteral("ab");
    const widths = [_]u8{ 1, 1 };
    const base: RowKeyView = .{
        .hash = fingerprint(text, &widths),
        .layout_width = 80,
        .layout_height = 20,
        .dpi = 96,
        .font_generation = 1,
        .fallback_generation = 1,
        .typography_generation = 1,
        .text = text,
        .cell_widths = &widths,
    };
    var changed = base;
    changed.layout_width += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.layout_height += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.dpi += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.font_generation += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.fallback_generation += 1;
    try std.testing.expect(!base.eql(changed));
    changed = base;
    changed.typography_generation += 1;
    try std.testing.expect(!base.eql(changed));

    const other_text = std.unicode.utf8ToUtf16LeStringLiteral("ac");
    changed = base;
    changed.text = other_text;
    changed.hash = fingerprint(other_text, &widths);
    try std.testing.expect(!base.eql(changed));
    const other_widths = [_]u8{ 1, 2 };
    changed = base;
    changed.cell_widths = &other_widths;
    changed.hash = fingerprint(text, &other_widths);
    try std.testing.expect(!base.eql(changed));
}

test "layout fingerprint includes exact text and cell mapping" {
    const text = std.unicode.utf8ToUtf16LeStringLiteral("é👻");
    try std.testing.expectEqual(
        fingerprint(text, &.{ 1, 2 }),
        fingerprint(text, &.{ 1, 2 }),
    );
    try std.testing.expect(fingerprint(text, &.{ 1, 2 }) !=
        fingerprint(text, &.{ 1, 1 }));
    try std.testing.expect(fingerprint(text, &.{ 1, 2 }) !=
        fingerprint(std.unicode.utf8ToUtf16LeStringLiteral("é👻"), &.{ 1, 2 }));
}

test "least recently used eviction is deterministic" {
    try std.testing.expectEqual(@as(?usize, null), leastRecentlyUsed(&.{}));
    try std.testing.expectEqual(@as(?usize, 1), leastRecentlyUsed(&.{ 9, 2, 4 }));
    try std.testing.expectEqual(@as(?usize, 0), leastRecentlyUsed(&.{ 2, 2, 4 }));
}

test "character spacing preserves terminal grapheme boundaries" {
    const shaped = [_]f32{ 8.25, 17.5, 7.75 };
    const cells = [_]u8{ 1, 2, 1 };
    const cell_width: f32 = 9.0;
    var position: f32 = 0;
    for (shaped, cells) |advance, cell_count| {
        const grid = @as(f32, @floatFromInt(cell_count)) * cell_width;
        const spacing = characterSpacing(grid, advance, 1);
        position += advance + spacing;
        try std.testing.expectApproxEqAbs(grid, advance + spacing, 0.0001);
    }
    try std.testing.expectApproxEqAbs(4 * cell_width, position, 0.0001);
}

const TestGrapheme = struct {
    text_start: usize,
    text_len: usize,
};

const SpacingHarness = struct {
    measurements: []const Measurement,
    measured: usize = 0,
    applied: std.ArrayListUnmanaged(SpacingAdjustment) = .empty,

    fn measure(self: *SpacingHarness, _: u32, _: u32) !Measurement {
        if (self.applied.items.len != 0) return error.MutationBeforeMeasurementsCompleted;
        const result = self.measurements[self.measured];
        self.measured += 1;
        return result;
    }

    fn apply(self: *SpacingHarness, adjustment: SpacingAdjustment) !void {
        if (self.measured != self.measurements.len) return error.MeasurementsIncomplete;
        try self.applied.append(std.testing.allocator, adjustment);
    }
};

test "spacing adjustments preserve cell widths fragments and exact UTF-16 ranges" {
    const graphemes = [_]TestGrapheme{
        .{ .text_start = 0, .text_len = 1 },
        .{ .text_start = 1, .text_len = 2 }, // combining sequence
        .{ .text_start = 3, .text_len = 5 }, // surrogate pairs plus ZWJ
    };
    const widths = [_]u8{ 1, 1, 2 };
    const measurements = [_]Measurement{
        .{ .advance = 8, .hit_count = 1 },
        .{ .advance = 10, .hit_count = 2 },
        .{ .advance = 15, .hit_count = 1 },
    };
    var harness: SpacingHarness = .{ .measurements = &measurements };
    defer harness.applied.deinit(std.testing.allocator);
    var scratch: std.ArrayListUnmanaged(SpacingAdjustment) = .empty;
    defer scratch.deinit(std.testing.allocator);

    try measureThenApplySpacing(
        &graphemes,
        &widths,
        9,
        &scratch,
        std.testing.allocator,
        &harness,
        SpacingHarness.measure,
        SpacingHarness.apply,
    );

    try std.testing.expectEqual(graphemes.len, harness.measured);
    try std.testing.expectEqual(@as(usize, 3), harness.applied.items.len);
    try std.testing.expectEqual(@as(u32, 0), harness.applied.items[0].text_start);
    try std.testing.expectEqual(@as(u32, 1), harness.applied.items[0].text_length);
    try std.testing.expectApproxEqAbs(@as(f32, 1), harness.applied.items[0].trailing_spacing, 0.0001);
    try std.testing.expectEqual(@as(u32, 1), harness.applied.items[1].text_start);
    try std.testing.expectEqual(@as(u32, 2), harness.applied.items[1].text_length);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), harness.applied.items[1].trailing_spacing, 0.0001);
    try std.testing.expectEqual(@as(u32, 3), harness.applied.items[2].text_start);
    try std.testing.expectEqual(@as(u32, 5), harness.applied.items[2].text_length);
    try std.testing.expectApproxEqAbs(@as(f32, 3), harness.applied.items[2].trailing_spacing, 0.0001);
}
