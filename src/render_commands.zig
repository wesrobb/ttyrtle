const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry.zig");
const terminal = @import("terminal.zig");

pub const TextRun = struct {
    x: i32,
    y: i32,
    color: terminal.Rgb,
    text_start: usize,
    text_len: usize,
};

pub const Rectangle = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    color: terminal.Rgb,
    outline: bool = false,
};

pub const CellMetadata = struct {
    utf16_start: usize,
    utf16_len: usize,
    spacer: bool,
    selected: bool,
    cursor: bool,
};

/// One complete terminal grapheme in the row shaping buffer.
pub const GraphemeSpan = struct {
    text_start: usize,
    text_len: usize,
    cell_start: u16,
    cell_count: u8,
};

pub const CachedRow = struct {
    generation: u64 = 0,
    fingerprint: u64 = 0,
    selection_active: bool = false,
    utf16: std.ArrayListUnmanaged(u16) = .empty,
    utf16_to_cell: std.ArrayListUnmanaged(u16) = .empty,
    cells: std.ArrayListUnmanaged(CellMetadata) = .empty,
    rectangles: std.ArrayListUnmanaged(Rectangle) = .empty,
    text_runs: std.ArrayListUnmanaged(TextRun) = .empty,
    graphemes: std.ArrayListUnmanaged(GraphemeSpan) = .empty,

    fn deinit(self: *CachedRow, allocator: std.mem.Allocator) void {
        self.utf16.deinit(allocator);
        self.utf16_to_cell.deinit(allocator);
        self.cells.deinit(allocator);
        self.rectangles.deinit(allocator);
        self.text_runs.deinit(allocator);
        self.graphemes.deinit(allocator);
        self.* = undefined;
    }

    fn clearRetainingCapacity(self: *CachedRow) void {
        self.utf16.clearRetainingCapacity();
        self.utf16_to_cell.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        self.rectangles.clearRetainingCapacity();
        self.text_runs.clearRetainingCapacity();
        self.graphemes.clearRetainingCapacity();
    }

    /// Simple primary-font rows can use one DirectWrite spacing range instead
    /// of measuring and configuring every terminal cell independently.
    pub fn hasUniformAsciiGrid(self: *const CachedRow) bool {
        if (self.graphemes.items.len == 0 or
            self.graphemes.items.len != self.cells.items.len)
            return false;

        for (self.graphemes.items) |grapheme| {
            if (grapheme.text_len != 1 or grapheme.cell_count != 1 or
                grapheme.text_start >= self.utf16.items.len)
                return false;
            const code_unit = self.utf16.items[grapheme.text_start];
            if (code_unit < ' ' or code_unit > '~') return false;
        }
        return true;
    }
};

const counters_enabled = builtin.mode == .Debug or builtin.is_test;

pub const RenderCache = struct {
    pub const Diagnostics = struct {
        dirty_rows: u64,
        rebuilt_rows: u64,
        scroll_reuses: u64,
        scroll_reused_rows: u64,
        full_rebuilds: u64,
        rectangle_requests: u64,
        rectangle_commands: u64,
    };
    allocator: std.mem.Allocator,
    background: terminal.Rgb = .{ .red = 12, .green = 16, .blue = 20 },
    rows: std.ArrayListUnmanaged(CachedRow) = .empty,
    columns: u16 = 0,
    metrics: ?geometry.Metrics = null,
    /// Positive means the terminal viewport scrolled upward by this many rows
    /// during the most recent full-damage update.
    scroll_up_rows: u16 = 0,
    dirty_row_count: if (counters_enabled) u64 else void,
    rebuilt_row_count: if (counters_enabled) u64 else void,
    rectangle_request_count: if (counters_enabled) u64 else void,
    rectangle_merge_count: if (counters_enabled) u64 else void,
    scroll_reuse_count: if (counters_enabled) u64 else void,
    scroll_reused_row_count: if (counters_enabled) u64 else void,
    full_rebuild_count: if (counters_enabled) u64 else void,

    pub fn init(allocator: std.mem.Allocator) RenderCache {
        return .{
            .allocator = allocator,
            .dirty_row_count = if (counters_enabled) 0 else {},
            .rebuilt_row_count = if (counters_enabled) 0 else {},
            .rectangle_request_count = if (counters_enabled) 0 else {},
            .rectangle_merge_count = if (counters_enabled) 0 else {},
            .scroll_reuse_count = if (counters_enabled) 0 else {},
            .scroll_reused_row_count = if (counters_enabled) 0 else {},
            .full_rebuild_count = if (counters_enabled) 0 else {},
        };
    }

    pub fn deinit(self: *RenderCache) void {
        for (self.rows.items) |*row| row.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Copies all pending model damage into application-owned retained rows.
    /// The caller may acknowledge model damage after this returns successfully.
    pub fn update(
        self: *RenderCache,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
        damage: terminal.RenderDamage,
    ) !void {
        const dimensions_changed =
            self.rows.items.len != model.rows() or self.columns != model.columns();
        const metrics_changed = self.metrics == null or
            !std.meta.eql(self.metrics.?, metrics);

        if (dimensions_changed) try self.resize(model.rows(), model.columns());
        self.metrics = metrics;
        self.background = model.background();
        self.scroll_up_rows = 0;

        if (dimensions_changed or metrics_changed) {
            try self.rebuildAll(model, metrics);
            self.recordDirtyRows(self.rows.items.len);
            if (counters_enabled) self.full_rebuild_count +|= 1;
            return;
        }

        switch (damage) {
            .none => {},
            .full => {
                if (!try self.reuseScrolledRows(model, metrics)) {
                    try self.rebuildAll(model, metrics);
                    self.recordDirtyRows(self.rows.items.len);
                    if (counters_enabled) self.full_rebuild_count +|= 1;
                }
            },
            .partial => |dirty_rows| {
                // Ghostty commonly marks every row except one as dirty for a
                // physical scroll. Verify a scroll before rebuilding that
                // near-full viewport row by row.
                if (dirty_rows.len * 4 >= self.rows.items.len * 3 and
                    try self.reuseScrolledRows(model, metrics))
                {
                    return;
                } else {
                    var accepted: usize = 0;
                    for (dirty_rows) |row| {
                        if (row < self.rows.items.len) {
                            try self.rebuildRow(model, metrics, row);
                            accepted += 1;
                        }
                    }
                    self.recordDirtyRows(accepted);
                }
            },
        }
    }

    pub fn diagnostics(self: *const RenderCache) Diagnostics {
        if (!counters_enabled) return .{
            .dirty_rows = 0,
            .rebuilt_rows = 0,
            .scroll_reuses = 0,
            .scroll_reused_rows = 0,
            .full_rebuilds = 0,
            .rectangle_requests = 0,
            .rectangle_commands = 0,
        };
        return .{
            .dirty_rows = self.dirty_row_count,
            .rebuilt_rows = self.rebuilt_row_count,
            .scroll_reuses = self.scroll_reuse_count,
            .scroll_reused_rows = self.scroll_reused_row_count,
            .full_rebuilds = self.full_rebuild_count,
            .rectangle_requests = self.rectangle_request_count,
            .rectangle_commands = self.rectangle_request_count -
                self.rectangle_merge_count,
        };
    }

    fn recordDirtyRows(self: *RenderCache, count: usize) void {
        if (counters_enabled) self.dirty_row_count +|= @intCast(count);
    }

    fn resize(self: *RenderCache, row_count: u16, column_count: u16) !void {
        const old_length = self.rows.items.len;
        const new_length: usize = row_count;
        if (new_length < old_length) {
            for (self.rows.items[new_length..]) |*row| row.deinit(self.allocator);
            self.rows.shrinkRetainingCapacity(new_length);
        } else if (new_length > old_length) {
            try self.rows.resize(self.allocator, new_length);
            for (self.rows.items[old_length..]) |*row| row.* = .{};
        }
        self.columns = column_count;
    }

    fn rebuildAll(
        self: *RenderCache,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
    ) !void {
        for (self.rows.items, 0..) |_, row|
            try self.rebuildRow(model, metrics, @intCast(row));
    }

    fn rebuildRow(
        self: *RenderCache,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
        row_index: u16,
    ) !void {
        try self.rebuildRowWithCount(model, metrics, row_index, true);
    }

    /// Rebuild a row whose cached geometry depends on the cursor, without
    /// counting it as content damage in the scroll-reuse diagnostics.
    fn refreshCursorRow(
        self: *RenderCache,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
        row_index: u16,
    ) !void {
        try self.rebuildRowWithCount(model, metrics, row_index, false);
    }

    fn rebuildRowWithCount(
        self: *RenderCache,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
        row_index: u16,
        count_rebuild: bool,
    ) !void {
        const row = &self.rows.items[row_index];
        row.clearRetainingCapacity();
        const cursor = model.cursor();
        var active_run: ?usize = null;

        for (0..model.columns()) |column| {
            const cell = model.cell(row_index, column) orelse {
                active_run = null;
                const text_start = row.utf16.items.len;
                try appendUtf16(self.allocator, row, @intCast(column), ' ');
                try row.graphemes.append(self.allocator, .{
                    .text_start = text_start,
                    .text_len = 1,
                    .cell_start = @intCast(column),
                    .cell_count = 1,
                });
                try row.cells.append(self.allocator, .{
                    .utf16_start = text_start,
                    .utf16_len = 1,
                    .spacer = false,
                    .selected = false,
                    .cursor = false,
                });
                continue;
            };
            const x: i32 = @intCast(
                metrics.margin_x +
                    @as(u32, @intCast(column)) * metrics.cell_width,
            );
            const y: i32 = @intCast(
                metrics.margin_y +
                    @as(u32, row_index) * metrics.cell_height,
            );
            const cell_background = if (cell.selected)
                cell.foreground
            else
                cell.background;
            const cell_foreground = if (cell.selected)
                cell.background
            else
                cell.foreground;
            if (!std.meta.eql(cell_background, self.background)) {
                try self.appendRectangle(row, .{
                    .left = x,
                    .top = y,
                    .right = x + @as(i32, @intCast(metrics.cell_width)),
                    .bottom = y + @as(i32, @intCast(metrics.cell_height)),
                    .color = cell_background,
                });
            }

            const cursor_here = cursor.visible and
                cursor.row == row_index and cursor.column == column;
            if (cursor_here) try self.appendCursor(
                row,
                cursor,
                x,
                y,
                metrics,
            );
            if (cell.underline) {
                try self.appendRectangle(row, .{
                    .left = x,
                    .top = y + @as(i32, @intCast(metrics.underline_top)),
                    .right = x + @as(i32, @intCast(metrics.cell_width)),
                    .bottom = y + @as(i32, @intCast(@min(
                        metrics.cell_height,
                        metrics.underline_top + metrics.underline_thickness,
                    ))),
                    .color = cell.foreground,
                });
            }

            const text_start = row.utf16.items.len;
            if (cell.spacer) {
                active_run = null;
            } else if (cell.codepoint) |codepoint| {
                const text_color = if (cursor_here and cursor.style == .block)
                    cell_background
                else
                    cell_foreground;
                if (active_run == null or
                    !std.meta.eql(row.text_runs.items[active_run.?].color, text_color))
                {
                    try row.text_runs.append(self.allocator, .{
                        .x = x,
                        .y = y,
                        .color = text_color,
                        .text_start = text_start,
                        .text_len = 0,
                    });
                    active_run = row.text_runs.items.len - 1;
                }
                try appendUtf16(self.allocator, row, @intCast(column), codepoint);
                for (cell.grapheme) |grapheme|
                    try appendUtf16(self.allocator, row, @intCast(column), grapheme);
                row.text_runs.items[active_run.?].text_len =
                    row.utf16.items.len -
                    row.text_runs.items[active_run.?].text_start;
            } else {
                active_run = null;
                try appendUtf16(self.allocator, row, @intCast(column), ' ');
            }
            if (!cell.spacer) {
                const next_is_spacer = column + 1 < model.columns() and
                    if (model.cell(row_index, column + 1)) |next|
                        next.spacer
                    else
                        false;
                try row.graphemes.append(self.allocator, .{
                    .text_start = text_start,
                    .text_len = row.utf16.items.len - text_start,
                    .cell_start = @intCast(column),
                    .cell_count = if (next_is_spacer) 2 else 1,
                });
            }

            try row.cells.append(self.allocator, .{
                .utf16_start = text_start,
                .utf16_len = row.utf16.items.len - text_start,
                .spacer = cell.spacer,
                .selected = cell.selected,
                .cursor = cursor_here,
            });
        }
        row.generation +%= 1;
        row.fingerprint = model.rowFingerprint(row_index);
        row.selection_active = model.hasSelection();
        if (counters_enabled and count_rebuild) self.rebuilt_row_count +|= 1;
    }

    fn detectScrollUp(self: *const RenderCache, model: *const terminal.TerminalModel) ?usize {
        if (self.rows.items.len < 2) return null;
        // Find the current first row in the old cache, then verify that one
        // candidate. This recognizes an output burst of any viewport-sized
        // scroll distance without repeatedly hashing the full viewport.
        const first = model.rowFingerprint(0);
        for (1..self.rows.items.len) |shift| {
            if (self.rows.items[shift].fingerprint != first) continue;
            for (1..self.rows.items.len - shift) |row| {
                if (model.rowFingerprint(row) != self.rows.items[row + shift].fingerprint)
                    break;
            } else return shift;
        }
        return null;
    }

    fn rotateRowsUp(self: *RenderCache, count: usize) void {
        for (0..count) |_| {
            const moved = self.rows.orderedRemove(0);
            self.rows.appendAssumeCapacity(moved);
        }
    }

    fn rebaseRowGeometry(row: *CachedRow, delta_y: i32) void {
        for (row.text_runs.items) |*text_run| text_run.y += delta_y;
        for (row.rectangles.items) |*rectangle| {
            rectangle.top += delta_y;
            rectangle.bottom += delta_y;
        }
    }

    fn rowHasCursor(row: *const CachedRow) bool {
        for (row.cells.items) |cell|
            if (cell.cursor) return true;
        return false;
    }

    fn reuseScrolledRows(
        self: *RenderCache,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
    ) !bool {
        if (model.hasSelection()) return false;
        const rows = self.detectScrollUp(model) orelse return false;
        self.rotateRowsUp(rows);
        const start = self.rows.items.len - rows;
        const delta_y: i32 = -@as(i32, @intCast(rows * metrics.cell_height));
        for (self.rows.items[0..start]) |*row| rebaseRowGeometry(row, delta_y);

        // Retained rows still contain absolute drawing commands and the prior
        // cursor marker. Rebuild only the rows affected by cursor movement;
        // all other rows retain their rebased geometry.
        const cursor = model.cursor();
        for (self.rows.items[0..start], 0..) |*row, index| {
            if (rowHasCursor(row) or (cursor.visible and cursor.row == index))
                try self.refreshCursorRow(model, metrics, @intCast(index));
        }
        for (start..self.rows.items.len) |row|
            try self.rebuildRow(model, metrics, @intCast(row));
        self.scroll_up_rows = @intCast(rows);
        self.recordDirtyRows(rows);
        if (counters_enabled) {
            self.scroll_reuse_count +|= 1;
            self.scroll_reused_row_count +|= @intCast(self.rows.items.len - rows);
        }
        return true;
    }

    fn appendRectangle(
        self: *RenderCache,
        row: *CachedRow,
        rectangle: Rectangle,
    ) !void {
        if (counters_enabled) self.rectangle_request_count +|= 1;
        if (!rectangle.outline and row.rectangles.items.len != 0) {
            const previous = &row.rectangles.items[row.rectangles.items.len - 1];
            if (!previous.outline and
                previous.right == rectangle.left and
                previous.top == rectangle.top and
                previous.bottom == rectangle.bottom and
                std.meta.eql(previous.color, rectangle.color))
            {
                previous.right = rectangle.right;
                if (counters_enabled) self.rectangle_merge_count +|= 1;
                return;
            }
        }
        try row.rectangles.append(self.allocator, rectangle);
    }

    fn appendCursor(
        self: *RenderCache,
        row: *CachedRow,
        cursor: terminal.Cursor,
        x: i32,
        y: i32,
        metrics: geometry.Metrics,
    ) !void {
        const width: i32 = @intCast(metrics.cell_width);
        const height: i32 = @intCast(metrics.cell_height);
        try self.appendRectangle(row, switch (cursor.style) {
            .block => .{
                .left = x,
                .top = y,
                .right = x + width,
                .bottom = y + height,
                .color = cursor.color,
            },
            .block_hollow => .{
                .left = x,
                .top = y,
                .right = x + width,
                .bottom = y + height,
                .color = cursor.color,
                .outline = true,
            },
            .bar => .{
                .left = x,
                .top = y,
                .right = x + @max(1, @divTrunc(width, 6)),
                .bottom = y + height,
                .color = cursor.color,
            },
            .underline => .{
                .left = x,
                .top = y + height - @max(1, @divTrunc(height, 8)),
                .right = x + width,
                .bottom = y + height,
                .color = cursor.color,
            },
        });
    }
};

fn appendUtf16(
    allocator: std.mem.Allocator,
    row: *CachedRow,
    column: u16,
    codepoint: u21,
) !void {
    if (codepoint <= 0xffff) {
        try row.utf16.append(allocator, @intCast(codepoint));
        try row.utf16_to_cell.append(allocator, column);
        return;
    }

    const value = codepoint - 0x10000;
    try row.utf16.append(allocator, @intCast(0xd800 + (value >> 10)));
    try row.utf16_to_cell.append(allocator, column);
    try row.utf16.append(allocator, @intCast(0xdc00 + (value & 0x3ff)));
    try row.utf16_to_cell.append(allocator, column);
}

test "cache rebuilds only dirty rows" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);

    try cache.update(&model, metrics, model.damage());
    model.acknowledgeDamage();
    const generations = [_]u64{
        cache.rows.items[0].generation,
        cache.rows.items[1].generation,
        cache.rows.items[2].generation,
        cache.rows.items[3].generation,
    };
    const before = cache.diagnostics();

    try model.write("\x1b[3;1Hchanged\x1b[1;1H");
    try cache.update(&model, metrics, model.damage());

    try std.testing.expectEqual(generations[1], cache.rows.items[1].generation);
    try std.testing.expect(cache.rows.items[2].generation > generations[2]);
    try std.testing.expectEqual(generations[3], cache.rows.items[3].generation);
    const after = cache.diagnostics();
    try std.testing.expectEqual(before.dirty_rows + 2, after.dirty_rows);
    try std.testing.expectEqual(before.rebuilt_rows + 2, after.rebuilt_rows);
}

test "cache reuses retained rows when live output scrolls a full viewport" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    try model.write("zero\r\none\r\ntwo\r\nthree");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);
    try cache.update(&model, metrics, model.damage());
    model.acknowledgeDamage();
    const before = cache.diagnostics();
    const old_second_generation = cache.rows.items[1].generation;

    try model.write("\r\nfour");
    try std.testing.expect(model.damage() == .full);
    try cache.update(&model, metrics, model.damage());

    try std.testing.expectEqual(@as(u16, 1), cache.scroll_up_rows);
    try std.testing.expectEqual(old_second_generation, cache.rows.items[0].generation);
    const after = cache.diagnostics();
    try std.testing.expectEqual(before.rebuilt_rows + 1, after.rebuilt_rows);
}

test "reused scroll rows update absolute drawing coordinates" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    try model.write("zero\r\n\x1b[41mone\x1b[0m\r\ntwo\r\nthree");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);
    try cache.update(&model, metrics, model.damage());
    model.acknowledgeDamage();

    try model.write("\r\nfour");
    try cache.update(&model, metrics, model.damage());

    const first_row = &cache.rows.items[0];
    try std.testing.expect(first_row.text_runs.items.len != 0);
    for (first_row.text_runs.items) |text_run|
        try std.testing.expectEqual(@as(i32, @intCast(metrics.margin_y)), text_run.y);
    try std.testing.expect(first_row.rectangles.items.len != 0);
    for (first_row.rectangles.items) |rectangle| {
        try std.testing.expect(rectangle.top >= metrics.margin_y);
        try std.testing.expect(rectangle.bottom <= metrics.margin_y + metrics.cell_height);
    }
}

test "scroll reuse leaves exactly one cursor at the model cursor" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    try model.write("zero\r\none\r\ntwo\r\nthree");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);
    try cache.update(&model, metrics, model.damage());
    model.acknowledgeDamage();

    try model.write("\r\nfour");
    try cache.update(&model, metrics, model.damage());

    var cursor_count: usize = 0;
    for (cache.rows.items) |row| {
        for (row.cells.items) |cell| {
            cursor_count += @intFromBool(cell.cursor);
        }
    }
    const cursor = model.cursor();
    try std.testing.expect(cache.rows.items[cursor.row].cells.items[cursor.column].cursor);
    try std.testing.expectEqual(@as(usize, 1), cursor_count);
}

test "cache reuses retained rows for a coalesced multi-line scroll burst" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 5, 20);
    defer model.deinit();
    try model.write("zero\r\none\r\ntwo\r\nthree\r\nfour");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);
    try cache.update(&model, metrics, model.damage());
    model.acknowledgeDamage();
    const before = cache.diagnostics();
    const old_third_generation = cache.rows.items[2].generation;

    try model.write("\r\nfive\r\nsix");
    try cache.update(&model, metrics, model.damage());

    try std.testing.expectEqual(@as(u16, 2), cache.scroll_up_rows);
    try std.testing.expectEqual(old_third_generation, cache.rows.items[0].generation);
    const after = cache.diagnostics();
    try std.testing.expectEqual(before.rebuilt_rows + 2, after.rebuilt_rows);
}

test "cache retains UTF-16 cell mapping and combining graphemes" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 2, 10);
    defer model.deinit();
    try model.write("e\xcc\x81\xf0\x9f\x91\xbb");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.update(&model, .forDpi(96), model.damage());

    const row = &cache.rows.items[0];
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("é👻"),
        row.utf16.items[0..4],
    );
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 0, 1, 1, 3, 4, 5, 6, 7, 8, 9 },
        row.utf16_to_cell.items,
    );
    try std.testing.expectEqual(@as(u8, 2), row.graphemes.items[1].cell_count);
    try std.testing.expectEqual(@as(usize, 2), row.cells.items[0].utf16_len);
    try std.testing.expectEqual(@as(usize, 2), row.cells.items[1].utf16_len);
}

test "cache preserves wide selection inverse underline and cursor metadata" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 2, 12);
    defer model.deinit();
    try model.write(
        "\x1b[48;2;1;2;3mA\x1b[7;4mB\x1b[0m界\x1b[2 q",
    );
    model.startSelection(0, 0);
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);

    try cache.update(&model, metrics, model.damage());

    const row = &cache.rows.items[0];
    try std.testing.expect(row.cells.items[0].selected);
    try std.testing.expect(!row.cells.items[1].selected);
    try std.testing.expect(row.cells.items[3].spacer);
    try std.testing.expect(row.cells.items[4].cursor);
    const inverse = model.cell(0, 1).?;
    const inverse_x: i32 = @intCast(metrics.margin_x + metrics.cell_width);
    var found_inverse_background = false;
    var found_underline = false;
    var found_cursor = false;
    for (row.rectangles.items) |rectangle| {
        if (rectangle.left <= inverse_x and rectangle.right > inverse_x and
            std.meta.eql(rectangle.color, inverse.background))
            found_inverse_background = true;
        if (rectangle.left == inverse_x and
            rectangle.bottom - rectangle.top == metrics.underline_thickness)
            found_underline = true;
        if (rectangle.left ==
            @as(i32, @intCast(metrics.margin_x + 4 * metrics.cell_width)) and
            std.meta.eql(rectangle.color, model.cursor().color))
            found_cursor = true;
    }
    try std.testing.expect(found_inverse_background);
    try std.testing.expect(found_underline);
    try std.testing.expect(found_cursor);
}

test "cache resize drops stale rows and initializes new rows" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 3, 8);
    defer model.deinit();
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);
    try cache.update(&model, metrics, model.damage());

    try model.resize(1, 4, metrics.cell_width, metrics.cell_height);
    try cache.update(&model, metrics, model.damage());
    try std.testing.expectEqual(@as(usize, 1), cache.rows.items.len);
    try std.testing.expectEqual(@as(usize, 4), cache.rows.items[0].cells.items.len);

    try model.resize(5, 12, metrics.cell_width, metrics.cell_height);
    try cache.update(&model, metrics, model.damage());
    try std.testing.expectEqual(@as(usize, 5), cache.rows.items.len);
    for (cache.rows.items) |row|
        try std.testing.expectEqual(@as(usize, 12), row.cells.items.len);
}

fn expectGridMappedGraphemes(row: *const CachedRow) !void {
    for (row.graphemes.items) |grapheme| {
        try std.testing.expect(grapheme.cell_count == 1 or grapheme.cell_count == 2);
        for (row.utf16_to_cell.items[grapheme.text_start .. grapheme.text_start + grapheme.text_len]) |cell| try std.testing.expectEqual(grapheme.cell_start, cell);
    }
}

test "ASCII PowerShell prompts box drawing block elements and colored runs retain cells" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 2, 48);
    defer model.deinit();
    try model.write("\x1b[38;2;10;20;30mPS C:\\src>\x1b[0m ┌─┐ █▓▒░");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.update(&model, .forDpi(96), model.damage());
    const row = &cache.rows.items[0];
    try expectGridMappedGraphemes(row);
    try std.testing.expect(row.text_runs.items.len >= 2);
    try std.testing.expect(std.mem.indexOf(
        u16,
        row.utf16.items,
        std.unicode.utf8ToUtf16LeStringLiteral("PS C:\\src>"),
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u16,
        row.utf16.items,
        std.unicode.utf8ToUtf16LeStringLiteral("┌─┐ █▓▒░"),
    ) != null);
}

test "combining precomposed CJK surrogate emoji ZWJ and mixed-script fallback retain grid advances" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 2, 64);
    defer model.deinit();
    try model.write("é é 界 𝄞 ☺️ 👩‍💻 Ελληνικά العربية हिन्दी");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.update(&model, .forDpi(96), model.damage());
    const row = &cache.rows.items[0];
    try expectGridMappedGraphemes(row);
    try std.testing.expect(std.mem.indexOf(
        u16,
        row.utf16.items,
        std.unicode.utf8ToUtf16LeStringLiteral("é"),
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u16,
        row.utf16.items,
        std.unicode.utf8ToUtf16LeStringLiteral("é"),
    ) != null);
    var saw_wide = false;
    var saw_surrogate = false;
    for (row.graphemes.items) |grapheme| {
        saw_wide = saw_wide or grapheme.cell_count == 2;
        saw_surrogate = saw_surrogate or grapheme.text_len >= 2 and
            row.utf16.items[grapheme.text_start] >= 0xd800 and
            row.utf16.items[grapheme.text_start] <= 0xdbff;
    }
    try std.testing.expect(saw_wide);
    try std.testing.expect(saw_surrogate);
    try std.testing.expect(std.mem.indexOf(
        u16,
        row.utf16.items,
        std.unicode.utf8ToUtf16LeStringLiteral("👩‍💻"),
    ) != null);
}

test "missing glyph candidate keeps a stable terminal-cell advance" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 1, 8);
    defer model.deinit();
    try model.write("A\xf4\x8f\xbf\xbfB");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.update(&model, .forDpi(96), model.damage());
    const row = &cache.rows.items[0];
    try expectGridMappedGraphemes(row);
    try std.testing.expectEqual(@as(u16, 1), row.graphemes.items[1].cell_start);
    try std.testing.expect(row.graphemes.items[1].cell_count == 1 or
        row.graphemes.items[1].cell_count == 2);
    try std.testing.expect(row.graphemes.items[2].cell_start >
        row.graphemes.items[1].cell_start);
}
test "steady-state row rebuild reuses retained storage" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 2, 10);
    defer model.deinit();
    try model.write("content");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);
    try cache.update(&model, metrics, model.damage());
    const row = &cache.rows.items[0];
    const capacities = .{
        row.utf16.capacity,
        row.utf16_to_cell.capacity,
        row.cells.capacity,
        row.rectangles.capacity,
        row.text_runs.capacity,
        row.graphemes.capacity,
    };

    model.markFullDamage();
    try cache.update(&model, metrics, model.damage());

    try std.testing.expectEqual(capacities[0], row.utf16.capacity);
    try std.testing.expectEqual(capacities[1], row.utf16_to_cell.capacity);
    try std.testing.expectEqual(capacities[2], row.cells.capacity);
    try std.testing.expectEqual(capacities[3], row.rectangles.capacity);
    try std.testing.expectEqual(capacities[4], row.text_runs.capacity);
    try std.testing.expectEqual(capacities[5], row.graphemes.capacity);
}

test "uniform ASCII grid excludes wide and combining graphemes" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 1, 8);
    defer model.deinit();
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();

    try model.write("ascii");
    try cache.update(&model, .forDpi(96), model.damage());
    try std.testing.expect(cache.rows.items[0].hasUniformAsciiGrid());

    try model.write("\x1b[1;1H界");
    try cache.update(&model, .forDpi(96), model.damage());
    try std.testing.expect(!cache.rows.items[0].hasUniformAsciiGrid());

    try model.write("\x1b[1;1He\xcc\x81");
    try cache.update(&model, .forDpi(96), model.damage());
    try std.testing.expect(!cache.rows.items[0].hasUniformAsciiGrid());
}

test "adjacent matching cell backgrounds share one rectangle command" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 1, 8);
    defer model.deinit();
    try model.write("\x1b[?25l\x1b[48;2;1;2;3mABC");
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    const metrics: geometry.Metrics = .forDpi(96);

    try cache.update(&model, metrics, model.damage());

    const row = &cache.rows.items[0];
    try std.testing.expectEqual(@as(usize, 1), row.rectangles.items.len);
    try std.testing.expectEqual(
        @as(i32, @intCast(metrics.margin_x)),
        row.rectangles.items[0].left,
    );
    try std.testing.expectEqual(
        @as(i32, @intCast(metrics.margin_x + 3 * metrics.cell_width)),
        row.rectangles.items[0].right,
    );
    const counts = cache.diagnostics();
    try std.testing.expectEqual(@as(u64, 3), counts.rectangle_requests);
    try std.testing.expectEqual(@as(u64, 1), counts.rectangle_commands);
}

test "outline rectangles remain independent commands" {
    var cache = RenderCache.init(std.testing.allocator);
    defer cache.deinit();
    var row: CachedRow = .{};
    defer row.deinit(std.testing.allocator);
    const color: terminal.Rgb = .{ .red = 1, .green = 2, .blue = 3 };

    try cache.appendRectangle(&row, .{
        .left = 0,
        .top = 0,
        .right = 8,
        .bottom = 16,
        .color = color,
        .outline = true,
    });
    try cache.appendRectangle(&row, .{
        .left = 8,
        .top = 0,
        .right = 16,
        .bottom = 16,
        .color = color,
        .outline = true,
    });

    try std.testing.expectEqual(@as(usize, 2), row.rectangles.items.len);
    const counts = cache.diagnostics();
    try std.testing.expectEqual(counts.rectangle_requests, counts.rectangle_commands);
}
