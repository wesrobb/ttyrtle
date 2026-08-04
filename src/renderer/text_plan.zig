const std = @import("std");

pub const SpanKind = enum { direct_glyph, shaped };

pub const Span = struct {
    kind: SpanKind,
    utf16_start: usize,
    utf16_len: usize,
    cell_start: u16,
    cell_count: u16,
    grid_width: u16,
    shape_fingerprint: u64,
    scalar: u21 = 0,
    glyph_index: u16 = 0,
};

pub const TextPlan = struct {
    row_generation: u64 = 0,
    font_generation: u64 = 0,
    spans: std.ArrayListUnmanaged(Span) = .empty,

    pub fn deinit(self: *TextPlan, allocator: std.mem.Allocator) void {
        self.spans.deinit(allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *TextPlan) void {
        self.spans.clearRetainingCapacity();
        self.row_generation = 0;
        self.font_generation = 0;
    }

    pub fn containingCell(self: *const TextPlan, cell: u16) ?*const Span {
        for (self.spans.items) |*span| {
            if (cell >= span.cell_start and cell < span.cell_start + span.cell_count)
                return span;
        }
        return null;
    }
};

/// Returns the exclusive end of the maximal direct-glyph run beginning at
/// `start`. Callers supply the effective-color comparison because color runs
/// are owned by the retained renderer row rather than the text plan.
pub fn directRunEnd(
    spans: []const Span,
    start: usize,
    color_context: anytype,
    comptime same_color: fn (@TypeOf(color_context), usize, usize) bool,
) usize {
    std.debug.assert(start < spans.len);
    std.debug.assert(spans[start].kind == .direct_glyph);
    const first = spans[start];
    var end = start + 1;
    var previous = first;
    while (end < spans.len) : (end += 1) {
        const next = spans[end];
        if (next.kind != .direct_glyph or
            previous.utf16_start + previous.utf16_len != next.utf16_start or
            previous.cell_start + previous.cell_count != next.cell_start or
            !same_color(color_context, first.utf16_start, next.utf16_start))
            break;
        previous = next;
    }
    return end;
}

pub fn directGlyphAdvance(cell_count: u16, cell_width: u32, scale: f32) f32 {
    return @as(f32, @floatFromInt(@as(u32, cell_count) * cell_width)) * scale;
}

pub const GlyphResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (*anyopaque, u21) anyerror!u16,

    pub fn resolve(self: GlyphResolver, scalar: u21) !u16 {
        return self.resolveFn(self.context, scalar);
    }
};

pub fn build(
    plan: *TextPlan,
    allocator: std.mem.Allocator,
    utf16: []const u16,
    graphemes: anytype,
    row_generation: u64,
    font_generation: u64,
    resolver: GlyphResolver,
) !void {
    plan.spans.clearRetainingCapacity();
    errdefer plan.spans.clearRetainingCapacity();

    for (graphemes) |grapheme| {
        if (grapheme.text_start >= utf16.len or grapheme.text_len == 0) continue;
        const end = @min(utf16.len, grapheme.text_start + grapheme.text_len);
        const text = utf16[grapheme.text_start..end];
        const scalar = singleScalar(text);
        const glyph = if (scalar) |value|
            if (!requiresShaping(value)) try resolver.resolve(value) else 0
        else
            0;
        const direct = scalar != null and glyph != 0 and !requiresShaping(scalar.?);
        if (direct) {
            try plan.spans.append(allocator, .{
                .kind = .direct_glyph,
                .utf16_start = grapheme.text_start,
                .utf16_len = text.len,
                .cell_start = grapheme.cell_start,
                .cell_count = grapheme.cell_count,
                .grid_width = grapheme.cell_count,
                .shape_fingerprint = fingerprint(text, &.{grapheme.cell_count}),
                .scalar = scalar.?,
                .glyph_index = glyph,
            });
            continue;
        }

        if (plan.spans.items.len != 0 and plan.spans.items[plan.spans.items.len - 1].kind == .shaped) {
            const previous = &plan.spans.items[plan.spans.items.len - 1];
            if (previous.utf16_start + previous.utf16_len == grapheme.text_start and
                previous.cell_start + previous.cell_count == grapheme.cell_start)
            {
                previous.utf16_len += text.len;
                previous.cell_count += grapheme.cell_count;
                previous.grid_width += grapheme.cell_count;
                previous.shape_fingerprint = fingerprint(
                    utf16[previous.utf16_start .. previous.utf16_start + previous.utf16_len],
                    &.{previous.grid_width},
                );
                continue;
            }
        }
        try plan.spans.append(allocator, .{
            .kind = .shaped,
            .utf16_start = grapheme.text_start,
            .utf16_len = text.len,
            .cell_start = grapheme.cell_start,
            .cell_count = grapheme.cell_count,
            .grid_width = grapheme.cell_count,
            .shape_fingerprint = fingerprint(text, &.{grapheme.cell_count}),
        });
    }
    plan.row_generation = row_generation;
    plan.font_generation = font_generation;
}

pub fn fingerprint(text: []const u16, widths: []const u16) u64 {
    var hash = std.hash.Wyhash.init(0x74747972746c65);
    hash.update(std.mem.sliceAsBytes(text));
    hash.update(std.mem.sliceAsBytes(widths));
    return hash.final();
}

pub const ShapedKeyView = struct {
    hash: u64,
    font_generation: u64,
    layout_width: u32,
    layout_height: u32,
    text: []const u16,
    cell_widths: []const u8,

    pub fn eql(a: ShapedKeyView, b: ShapedKeyView) bool {
        return a.hash == b.hash and
            a.font_generation == b.font_generation and
            a.layout_width == b.layout_width and
            a.layout_height == b.layout_height and
            std.mem.eql(u16, a.text, b.text) and
            std.mem.eql(u8, a.cell_widths, b.cell_widths);
    }
};

pub fn leastRecentlyUsed(timestamps: []const u64) ?usize {
    if (timestamps.len == 0) return null;
    var oldest: usize = 0;
    for (timestamps[1..], 1..) |timestamp, index| {
        if (timestamp < timestamps[oldest]) oldest = index;
    }
    return oldest;
}

fn singleScalar(text: []const u16) ?u21 {
    if (text.len == 1) {
        const unit = text[0];
        if (unit >= 0xd800 and unit <= 0xdfff) return null;
        return @intCast(unit);
    }
    if (text.len != 2 or text[0] < 0xd800 or text[0] > 0xdbff or
        text[1] < 0xdc00 or text[1] > 0xdfff)
        return null;
    return @intCast(0x10000 +
        ((@as(u32, text[0]) - 0xd800) << 10) +
        (@as(u32, text[1]) - 0xdc00));
}

/// Scripts whose ordinary letters participate in context-sensitive joining
/// must stay together even when the primary font happens to contain them.
fn requiresShaping(scalar: u21) bool {
    return (scalar >= 0x0600 and scalar <= 0x08ff) or
        (scalar >= 0x0700 and scalar <= 0x074f) or
        (scalar >= 0x0780 and scalar <= 0x07bf) or
        (scalar >= 0x1800 and scalar <= 0x18af) or
        (scalar >= 0xa840 and scalar <= 0xa87f) or
        (scalar >= 0x10ac0 and scalar <= 0x10aff) or
        (scalar >= 0x10b80 and scalar <= 0x10baf) or
        (scalar >= 0x1e900 and scalar <= 0x1e95f);
}

pub fn GlyphIndexCache(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct { scalar: u21, glyph: u16 };
        entries: std.ArrayListUnmanaged(Entry) = .empty,
        next_fifo: usize = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entries.deinit(allocator);
            self.* = .{};
        }

        pub fn clear(self: *Self) void {
            self.entries.clearRetainingCapacity();
            self.next_fifo = 0;
        }

        pub fn getOrResolve(
            self: *Self,
            allocator: std.mem.Allocator,
            scalar: u21,
            resolver: GlyphResolver,
        ) !u16 {
            for (self.entries.items) |entry| if (entry.scalar == scalar) return entry.glyph;
            const glyph = try resolver.resolve(scalar);
            if (capacity == 0) return glyph;
            if (self.entries.items.len < capacity) {
                try self.entries.append(allocator, .{ .scalar = scalar, .glyph = glyph });
            } else {
                self.entries.items[self.next_fifo] = .{ .scalar = scalar, .glyph = glyph };
                self.next_fifo = (self.next_fifo + 1) % capacity;
            }
            return glyph;
        }
    };
}

const TestGrapheme = struct { text_start: usize, text_len: usize, cell_start: u16, cell_count: u8 };
const TestResolver = struct {
    calls: usize = 0,
    missing: u21 = 0,
    fn resolve(raw: *anyopaque, scalar: u21) !u16 {
        const self: *TestResolver = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return if (scalar == self.missing) 0 else @truncate(scalar + 1);
    }
    fn interface(self: *TestResolver) GlyphResolver {
        return .{ .context = self, .resolveFn = resolve };
    }
};

test "planner separates direct glyphs from maximal shaped spans" {
    var resolver: TestResolver = .{ .missing = 0x2603 };
    var plan: TextPlan = .{};
    defer plan.deinit(std.testing.allocator);
    const text = [_]u16{ 'A', 0x2500, 'e', 0x0301, 0x2603, 'B' };
    const graphemes = [_]TestGrapheme{
        .{ .text_start = 0, .text_len = 1, .cell_start = 0, .cell_count = 1 },
        .{ .text_start = 1, .text_len = 1, .cell_start = 1, .cell_count = 1 },
        .{ .text_start = 2, .text_len = 2, .cell_start = 2, .cell_count = 1 },
        .{ .text_start = 4, .text_len = 1, .cell_start = 3, .cell_count = 1 },
        .{ .text_start = 5, .text_len = 1, .cell_start = 4, .cell_count = 1 },
    };
    try build(&plan, std.testing.allocator, &text, &graphemes, 7, 3, resolver.interface());
    try std.testing.expectEqual(@as(usize, 4), plan.spans.items.len);
    try std.testing.expectEqual(SpanKind.direct_glyph, plan.spans.items[0].kind);
    try std.testing.expectEqual(SpanKind.direct_glyph, plan.spans.items[1].kind);
    try std.testing.expectEqual(SpanKind.shaped, plan.spans.items[2].kind);
    try std.testing.expectEqual(@as(usize, 3), plan.spans.items[2].utf16_len);
    try std.testing.expectEqual(SpanKind.direct_glyph, plan.spans.items[3].kind);
}

test "wide scalar is direct and joining script stays in one shaped span" {
    var resolver: TestResolver = .{};
    var plan: TextPlan = .{};
    defer plan.deinit(std.testing.allocator);
    const text = [_]u16{ 0x754c, 0x0633, 0x0644, 0x0627, 0x0645 };
    const graphemes = [_]TestGrapheme{
        .{ .text_start = 0, .text_len = 1, .cell_start = 0, .cell_count = 2 },
        .{ .text_start = 1, .text_len = 1, .cell_start = 2, .cell_count = 1 },
        .{ .text_start = 2, .text_len = 1, .cell_start = 3, .cell_count = 1 },
        .{ .text_start = 3, .text_len = 1, .cell_start = 4, .cell_count = 1 },
        .{ .text_start = 4, .text_len = 1, .cell_start = 5, .cell_count = 1 },
    };
    try build(&plan, std.testing.allocator, &text, &graphemes, 1, 1, resolver.interface());
    try std.testing.expectEqual(@as(usize, 2), plan.spans.items.len);
    try std.testing.expectEqual(@as(u16, 2), plan.spans.items[0].cell_count);
    try std.testing.expectEqual(SpanKind.shaped, plan.spans.items[1].kind);
    try std.testing.expectEqual(@as(usize, 4), plan.spans.items[1].utf16_len);
}

test "emoji sequence is shaped as one grapheme" {
    var resolver: TestResolver = .{};
    var plan: TextPlan = .{};
    defer plan.deinit(std.testing.allocator);
    // woman + ZWJ + laptop
    const text = [_]u16{ 0xd83d, 0xdc69, 0x200d, 0xd83d, 0xdcbb };
    const graphemes = [_]TestGrapheme{
        .{ .text_start = 0, .text_len = text.len, .cell_start = 0, .cell_count = 2 },
    };
    try build(&plan, std.testing.allocator, &text, &graphemes, 1, 1, resolver.interface());
    try std.testing.expectEqual(@as(usize, 1), plan.spans.items.len);
    try std.testing.expectEqual(SpanKind.shaped, plan.spans.items[0].kind);
    try std.testing.expectEqual(@as(u16, 2), plan.spans.items[0].cell_count);
}

test "glyph cache is FIFO and caches unsupported glyphs" {
    var resolver: TestResolver = .{ .missing = 'x' };
    var cache: GlyphIndexCache(2) = .{};
    defer cache.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 0), try cache.getOrResolve(std.testing.allocator, 'x', resolver.interface()));
    _ = try cache.getOrResolve(std.testing.allocator, 'x', resolver.interface());
    try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    _ = try cache.getOrResolve(std.testing.allocator, 'a', resolver.interface());
    _ = try cache.getOrResolve(std.testing.allocator, 'b', resolver.interface());
    _ = try cache.getOrResolve(std.testing.allocator, 'x', resolver.interface());
    try std.testing.expectEqual(@as(usize, 4), resolver.calls);
}

test "shaped keys verify exact text widths dimensions and generation after hash match" {
    const base: ShapedKeyView = .{
        .hash = 42,
        .font_generation = 3,
        .layout_width = 20,
        .layout_height = 18,
        .text = &.{ 'e', 0x0301 },
        .cell_widths = &.{1},
    };
    try std.testing.expect(base.eql(base));
    var collision = base;
    collision.text = &.{ 'a', 0x0301 };
    try std.testing.expect(!base.eql(collision));
    collision = base;
    collision.cell_widths = &.{2};
    try std.testing.expect(!base.eql(collision));
    collision = base;
    collision.font_generation += 1;
    try std.testing.expect(!base.eql(collision));
    collision = base;
    collision.layout_width += 1;
    try std.testing.expect(!base.eql(collision));
}

test "LRU selection is deterministic" {
    try std.testing.expectEqual(@as(?usize, null), leastRecentlyUsed(&.{}));
    try std.testing.expectEqual(@as(?usize, 1), leastRecentlyUsed(&.{ 8, 2, 5 }));
    try std.testing.expectEqual(@as(?usize, 0), leastRecentlyUsed(&.{ 2, 2, 5 }));
}

test "clearing glyph cache invalidates its generation worth of results" {
    var resolver: TestResolver = .{};
    var cache: GlyphIndexCache(4) = .{};
    defer cache.deinit(std.testing.allocator);
    _ = try cache.getOrResolve(std.testing.allocator, 'A', resolver.interface());
    _ = try cache.getOrResolve(std.testing.allocator, 'A', resolver.interface());
    try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    cache.clear();
    _ = try cache.getOrResolve(std.testing.allocator, 'A', resolver.interface());
    try std.testing.expectEqual(@as(usize, 2), resolver.calls);
}

const RunColorContext = struct {
    boundaries: []const usize,
    colors: []const u8,

    fn same(self: RunColorContext, first: usize, next: usize) bool {
        return self.at(first) == self.at(next);
    }

    fn at(self: RunColorContext, position: usize) u8 {
        var result: u8 = 0;
        for (self.boundaries, self.colors) |boundary, color| {
            if (position < boundary) break;
            result = color;
        }
        return result;
    }
};

fn directSpan(utf16_start: usize, utf16_len: usize, cell_start: u16, cell_count: u16) Span {
    return .{
        .kind = .direct_glyph,
        .utf16_start = utf16_start,
        .utf16_len = utf16_len,
        .cell_start = cell_start,
        .cell_count = cell_count,
        .grid_width = cell_count,
        .shape_fingerprint = 0,
        .glyph_index = @intCast(utf16_start + 1),
    };
}

test "uniform ASCII and box-drawing sequence forms one direct run" {
    var resolver: TestResolver = .{};
    var plan: TextPlan = .{};
    defer plan.deinit(std.testing.allocator);
    const text = [_]u16{ 'A', 0x2500, 0x2502, 'B' };
    const graphemes = [_]TestGrapheme{
        .{ .text_start = 0, .text_len = 1, .cell_start = 0, .cell_count = 1 },
        .{ .text_start = 1, .text_len = 1, .cell_start = 1, .cell_count = 1 },
        .{ .text_start = 2, .text_len = 1, .cell_start = 2, .cell_count = 1 },
        .{ .text_start = 3, .text_len = 1, .cell_start = 3, .cell_count = 1 },
    };
    try build(&plan, std.testing.allocator, &text, &graphemes, 1, 1, resolver.interface());
    const colors = RunColorContext{ .boundaries = &.{0}, .colors = &.{1} };
    try std.testing.expectEqual(plan.spans.items.len, directRunEnd(plan.spans.items, 0, colors, RunColorContext.same));
}

test "foreground change splits a direct run at its boundary" {
    const spans = [_]Span{
        directSpan(0, 1, 0, 1),
        directSpan(1, 1, 1, 1),
        directSpan(2, 1, 2, 1),
        directSpan(3, 1, 3, 1),
    };
    const colors = RunColorContext{ .boundaries = &.{ 0, 2 }, .colors = &.{ 1, 2 } };
    try std.testing.expectEqual(@as(usize, 2), directRunEnd(&spans, 0, colors, RunColorContext.same));
    try std.testing.expectEqual(@as(usize, 4), directRunEnd(&spans, 2, colors, RunColorContext.same));
}

test "wide direct glyph stays in a run with a two-cell advance" {
    const spans = [_]Span{
        directSpan(0, 1, 0, 1),
        directSpan(1, 1, 1, 2),
        directSpan(2, 1, 3, 1),
    };
    const colors = RunColorContext{ .boundaries = &.{0}, .colors = &.{1} };
    try std.testing.expectEqual(spans.len, directRunEnd(&spans, 0, colors, RunColorContext.same));
    try std.testing.expectEqual(@as(f32, 25), directGlyphAdvance(spans[1].cell_count, 10, 1.25));
}

test "shaped and noncontiguous spans terminate direct runs" {
    const shaped: Span = .{
        .kind = .shaped,
        .utf16_start = 1,
        .utf16_len = 2,
        .cell_start = 1,
        .cell_count = 1,
        .grid_width = 1,
        .shape_fingerprint = 0,
    };
    const spans = [_]Span{
        directSpan(0, 1, 0, 1),
        shaped,
        directSpan(3, 1, 2, 1),
        directSpan(4, 1, 4, 1),
    };
    const colors = RunColorContext{ .boundaries = &.{0}, .colors = &.{1} };
    try std.testing.expectEqual(@as(usize, 1), directRunEnd(&spans, 0, colors, RunColorContext.same));
    try std.testing.expectEqual(@as(usize, 3), directRunEnd(&spans, 2, colors, RunColorContext.same));
}

test "noncontiguous UTF-16 ranges terminate a direct run" {
    const spans = [_]Span{
        directSpan(0, 1, 0, 1),
        directSpan(2, 1, 1, 1),
    };
    const colors = RunColorContext{ .boundaries = &.{0}, .colors = &.{1} };
    try std.testing.expectEqual(@as(usize, 1), directRunEnd(&spans, 0, colors, RunColorContext.same));
}

test "UTF-16 surrogate scalar contributes one direct glyph entry" {
    var resolver: TestResolver = .{};
    var plan: TextPlan = .{};
    defer plan.deinit(std.testing.allocator);
    const text = [_]u16{ 0xd83d, 0xde00, 'A' };
    const graphemes = [_]TestGrapheme{
        .{ .text_start = 0, .text_len = 2, .cell_start = 0, .cell_count = 2 },
        .{ .text_start = 2, .text_len = 1, .cell_start = 2, .cell_count = 1 },
    };
    try build(&plan, std.testing.allocator, &text, &graphemes, 1, 1, resolver.interface());
    const colors = RunColorContext{ .boundaries = &.{0}, .colors = &.{1} };
    try std.testing.expectEqual(@as(usize, 2), plan.spans.items.len);
    try std.testing.expectEqual(@as(usize, 2), plan.spans.items[0].utf16_len);
    try std.testing.expectEqual(@as(usize, 2), directRunEnd(plan.spans.items, 0, colors, RunColorContext.same));
}
