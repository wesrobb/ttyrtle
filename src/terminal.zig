const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");
const frame_trace = @import("frame_trace.zig");

pub const Rgb = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const CellSnapshot = struct {
    codepoint: ?u21,
    grapheme: []const u21,
    foreground: Rgb,
    background: Rgb,
    spacer: bool,
    bold: bool,
    faint: bool,
    underline: bool,
    selected: bool,
};

pub const CursorStyle = enum {
    bar,
    block,
    underline,
    block_hollow,
};

pub const Cursor = struct {
    row: u32,
    column: u32,
    style: CursorStyle,
    color: Rgb,
    visible: bool,
    blinking: bool,
};

pub const ReplySink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
};

pub const RenderDamage = union(enum) {
    none,
    partial: []const u16,
    full,
};

const SelectionRange = ?[2]u16;

const counters_enabled = builtin.mode == .Debug or builtin.is_test;

/// Per-terminal primary-screen history budget. Configuration will replace this
/// application default in a later milestone.
pub const default_scrollback_bytes: usize = 10 * 1024 * 1024;

pub const TerminalModel = struct {
    pub const Diagnostics = struct {
        output_batches: u64,
        chunks_parsed: u64,
        render_refreshes: u64,
        core_resizes: u64,
        parse_trace: frame_trace.Stats,
        render_state_trace: frame_trace.Stats,
        damage_trace: frame_trace.Stats,
        resize_trace: frame_trace.Stats,
    };
    allocator: std.mem.Allocator,
    core: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    render_state: ghostty.RenderState,
    reply_sink: ?ReplySink,
    reply_failed: bool,
    title_changed: bool,
    bell_count: usize,
    cell_width: u32,
    cell_height: u32,
    cursor_blink_visible: bool,
    selection_refresh: bool,
    selection_snapshot: std.ArrayListUnmanaged(SelectionRange),
    damage_full: bool,
    damage_rows: std.ArrayListUnmanaged(u16),
    output_batch_count: if (counters_enabled) u64 else void,
    chunks_parsed_count: if (counters_enabled) u64 else void,
    render_refresh_count: if (counters_enabled) u64 else void,
    core_resize_count: if (counters_enabled) u64 else void,
    parse_trace: frame_trace.Counter,
    render_state_trace: frame_trace.Counter,
    damage_trace: frame_trace.Counter,
    resize_trace: frame_trace.Counter,

    pub fn init(
        self: *TerminalModel,
        allocator: std.mem.Allocator,
        row_count: u16,
        column_count: u16,
    ) !void {
        self.* = .{
            .allocator = allocator,
            .core = try .init(
                std.Io.Threaded.global_single_threaded.io(),
                allocator,
                .{
                    .rows = row_count,
                    .cols = column_count,
                    .max_scrollback_bytes = default_scrollback_bytes,
                },
            ),
            .stream = undefined,
            .render_state = .empty,
            .reply_sink = null,
            .reply_failed = false,
            .title_changed = false,
            .bell_count = 0,
            .cell_width = 0,
            .cell_height = 0,
            .cursor_blink_visible = true,
            .selection_refresh = false,
            .selection_snapshot = .empty,
            .damage_full = false,
            .damage_rows = .empty,
            .output_batch_count = if (counters_enabled) 0 else {},
            .chunks_parsed_count = if (counters_enabled) 0 else {},
            .render_refresh_count = if (counters_enabled) 0 else {},
            .core_resize_count = if (counters_enabled) 0 else {},
            .parse_trace = .{},
            .render_state_trace = .{},
            .damage_trace = .{},
            .resize_trace = .{},
        };
        errdefer self.core.deinit(allocator);

        var handler = self.core.vtHandler();
        handler.effects.write_pty = writePty;
        handler.effects.device_attributes = deviceAttributes;
        handler.effects.size = reportSize;
        handler.effects.title_changed = titleChanged;
        handler.effects.bell = bell;
        handler.effects.xtversion = xtversion;
        self.stream = .initAlloc(allocator, handler);
        errdefer self.stream.deinit();
        errdefer self.render_state.deinit(allocator);

        try self.refresh();
    }

    pub fn deinit(self: *TerminalModel) void {
        self.stream.deinit();
        self.render_state.deinit(self.allocator);
        self.core.deinit(self.allocator);
        self.selection_snapshot.deinit(self.allocator);
        self.damage_rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn write(self: *TerminalModel, bytes: []const u8) !void {
        const chunks = [_][]const u8{bytes};
        try self.writeBatch(&chunks);
    }

    pub fn writeBatch(
        self: *TerminalModel,
        chunks: []const []const u8,
    ) !void {
        if (counters_enabled) {
            self.output_batch_count +|= 1;
            self.chunks_parsed_count +|= chunks.len;
        }
        const parse_start = frame_trace.timestamp();
        for (chunks) |bytes| self.stream.nextSlice(bytes);
        self.parse_trace.recordSince(parse_start);
        if (self.reply_failed) {
            self.reply_failed = false;
            return error.ReplyDeliveryFailed;
        }
        try self.refresh();
        // A retained viewport may have had its oldest pages evicted or its
        // pinned selection remapped by output, neither of which is expressible
        // as a reliable row-local cache update.
        if (!self.viewportFollowsBottom()) self.markFullDamage();
    }

    /// Scroll the visible viewport. Negative deltas move into history.
    pub fn scrollViewport(self: *TerminalModel, delta: isize) !void {
        self.core.scrollViewport(.{ .delta = delta });
        try self.refresh();
        self.markFullDamage();
    }

    pub fn scrollViewportPage(self: *TerminalModel, direction: enum { up, down }) !void {
        const page_rows: isize = @intCast(@max(self.rows() -| 1, 1));
        try self.scrollViewport(if (direction == .up) -page_rows else page_rows);
    }

    pub fn scrollViewportTop(self: *TerminalModel) !void {
        self.core.scrollViewport(.top);
        try self.refresh();
        self.markFullDamage();
    }

    pub fn scrollViewportBottom(self: *TerminalModel) !void {
        self.core.scrollViewport(.bottom);
        try self.refresh();
        self.markFullDamage();
    }

    pub fn viewportFollowsBottom(self: *const TerminalModel) bool {
        return self.core.screens.active.pages.viewport == .active;
    }

    pub fn setReplySink(self: *TerminalModel, sink: ?ReplySink) void {
        self.reply_sink = sink;
    }

    pub fn takeTitleChanged(self: *TerminalModel) bool {
        const changed = self.title_changed;
        self.title_changed = false;
        return changed;
    }

    pub fn takeBellCount(self: *TerminalModel) usize {
        const count = self.bell_count;
        self.bell_count = 0;
        return count;
    }

    pub fn resize(
        self: *TerminalModel,
        row_count: u16,
        column_count: u16,
        cell_width: u32,
        cell_height: u32,
    ) !void {
        const resize_start = frame_trace.timestamp();
        defer self.resize_trace.recordSince(resize_start);
        if (counters_enabled) self.core_resize_count +|= 1;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
        try self.stream.handler.resize(.{
            .rows = row_count,
            .cols = column_count,
            .cell_size_px = .{
                .width = cell_width,
                .height = cell_height,
            },
        });
        try self.refresh();
        self.markFullDamage();
    }

    fn fromHandler(handler: *VtHandler) *TerminalModel {
        return @fieldParentPtr("core", handler.terminal);
    }

    fn writePty(handler: *VtHandler, bytes: [:0]const u8) void {
        const self = fromHandler(handler);
        const sink = self.reply_sink orelse return;
        sink.write(sink.context, bytes) catch {
            self.reply_failed = true;
        };
    }

    fn titleChanged(handler: *VtHandler) void {
        fromHandler(handler).title_changed = true;
    }

    fn bell(handler: *VtHandler) void {
        fromHandler(handler).bell_count +|= 1;
    }

    fn deviceAttributes(
        _: *VtHandler,
    ) DeviceAttributes {
        return .{};
    }

    fn reportSize(handler: *VtHandler) ?ReportSize {
        const self = fromHandler(handler);
        return .{
            .rows = self.rows(),
            .columns = self.columns(),
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
        };
    }

    fn xtversion(_: *VtHandler) []const u8 {
        return "ttyrtle 0.1";
    }

    pub fn refresh(self: *TerminalModel) !void {
        const old_cursor_row = renderCursorRow(&self.render_state);
        const render_state_start = frame_trace.timestamp();
        try self.render_state.update(self.allocator, &self.core);
        self.render_state_trace.recordSince(render_state_start);
        if (counters_enabled) self.render_refresh_count +|= 1;
        const damage_start = frame_trace.timestamp();
        try self.collectRenderDamage(old_cursor_row);
        self.damage_trace.recordSince(damage_start);
    }

    pub fn diagnostics(self: *const TerminalModel) Diagnostics {
        if (!counters_enabled) return .{
            .output_batches = 0,
            .chunks_parsed = 0,
            .render_refreshes = 0,
            .core_resizes = 0,
            .parse_trace = .{},
            .render_state_trace = .{},
            .damage_trace = .{},
            .resize_trace = .{},
        };
        return .{
            .output_batches = self.output_batch_count,
            .chunks_parsed = self.chunks_parsed_count,
            .render_refreshes = self.render_refresh_count,
            .core_resizes = self.core_resize_count,
            .parse_trace = self.parse_trace.snapshot(),
            .render_state_trace = self.render_state_trace.snapshot(),
            .damage_trace = self.damage_trace.snapshot(),
            .resize_trace = self.resize_trace.snapshot(),
        };
    }
    pub fn damage(self: *const TerminalModel) RenderDamage {
        if (self.damage_full) return .full;
        if (self.damage_rows.items.len == 0) return .none;
        return .{ .partial = self.damage_rows.items };
    }

    pub fn acknowledgeDamage(self: *TerminalModel) void {
        self.damage_full = false;
        self.damage_rows.clearRetainingCapacity();
    }

    pub fn markFullDamage(self: *TerminalModel) void {
        self.damage_full = true;
        self.damage_rows.clearRetainingCapacity();
    }

    pub fn rows(self: *const TerminalModel) u16 {
        return self.render_state.rows;
    }

    pub fn columns(self: *const TerminalModel) u16 {
        return self.render_state.cols;
    }

    pub fn cursor(self: *const TerminalModel) Cursor {
        const raw_color = self.render_state.colors.cursor orelse
            self.render_state.colors.foreground;
        const viewport = self.render_state.cursor.viewport;
        return .{
            .row = if (viewport) |position|
                position.y
            else
                self.render_state.cursor.active.y,
            .column = if (viewport) |position|
                position.x
            else
                self.render_state.cursor.active.x,
            .style = switch (self.render_state.cursor.visual_style) {
                .bar => .bar,
                .block => .block,
                .underline => .underline,
                .block_hollow => .block_hollow,
            },
            .color = rgb(raw_color),
            .visible = self.render_state.cursor.visible and
                viewport != null and
                (!self.render_state.cursor.blinking or self.cursor_blink_visible),
            .blinking = self.render_state.cursor.blinking,
        };
    }

    pub fn toggleCursorBlink(self: *TerminalModel) void {
        self.cursor_blink_visible = !self.cursor_blink_visible;
        if (self.render_state.cursor.blinking and
            self.render_state.cursor.visible)
        {
            if (renderCursorRow(&self.render_state)) |row|
                self.mergeDamageRow(row) catch self.markFullDamage();
        }
    }

    pub fn resetCursorBlink(self: *TerminalModel) void {
        if (self.cursor_blink_visible) return;
        self.cursor_blink_visible = true;
        if (self.render_state.cursor.blinking and
            self.render_state.cursor.visible)
        {
            if (renderCursorRow(&self.render_state)) |row|
                self.mergeDamageRow(row) catch self.markFullDamage();
        }
    }

    pub fn background(self: *const TerminalModel) Rgb {
        return rgb(self.render_state.colors.background);
    }

    pub fn startSelection(self: *TerminalModel, row: u32, column: u32) void {
        self.setSelection(row, column, row, column);
    }

    pub fn updateSelection(self: *TerminalModel, row: u32, column: u32) void {
        const screen = self.core.screens.active;
        const anchor = screen.selection orelse return;
        const start = anchor.start();
        const end = self.viewportPin(row, column) orelse return;
        self.snapshotVisibleSelection() catch {
            self.markFullDamage();
            return;
        };
        screen.select(.init(start, end, false)) catch self.markFullDamage();
        self.refreshSelection() catch self.markFullDamage();
        self.markChangedVisibleSelectionRows();
    }

    pub fn clearSelection(self: *TerminalModel) void {
        self.snapshotVisibleSelection() catch {
            self.markFullDamage();
            return;
        };
        self.core.screens.active.clearSelection();
        self.refreshSelection() catch self.markFullDamage();
        self.markChangedVisibleSelectionRows();
    }

    pub fn selectionTextAlloc(
        self: *const TerminalModel,
        allocator: std.mem.Allocator,
    ) ![:0]const u8 {
        const selection = self.core.screens.active.selection orelse
            return allocator.allocSentinel(u8, 0, 0);
        const result = try self.core.screens.active.selectionString(allocator, .{
            .sel = selection,
        });
        return result;
    }

    pub fn cell(self: *const TerminalModel, row: usize, column: usize) ?CellSnapshot {
        if (row >= self.render_state.row_data.len) return null;

        const rows_slice = self.render_state.row_data.slice();
        const row_cells = rows_slice.items(.cells);
        const cells = row_cells[row].slice();
        const raw_cells = cells.items(.raw);
        if (column >= raw_cells.len) return null;

        const render_cells = row_cells[row].slice();
        const raw = raw_cells[column];
        const spacer = switch (raw.wide) {
            .spacer_head, .spacer_tail => true,
            else => false,
        };

        const style: ghostty.Style = if (raw.style_id == 0)
            .{}
        else
            cells.items(.style)[column];
        var foreground = style.fg(.{
            .default = self.render_state.colors.foreground,
            .palette = &self.render_state.colors.palette,
            .bold = .bright,
        });
        var cell_background = style.bg(
            &raw,
            &self.render_state.colors.palette,
        ) orelse self.render_state.colors.background;
        if (style.flags.inverse) std.mem.swap(
            ghostty.color.RGB,
            &foreground,
            &cell_background,
        );
        if (style.flags.faint) {
            foreground.r = @intCast(
                (@as(u16, foreground.r) + cell_background.r) / 2,
            );
            foreground.g = @intCast(
                (@as(u16, foreground.g) + cell_background.g) / 2,
            );
            foreground.b = @intCast(
                (@as(u16, foreground.b) + cell_background.b) / 2,
            );
        }
        const grapheme = if (raw.content_tag == .codepoint_grapheme)
            render_cells.items(.grapheme)[column]
        else
            &.{};

        return .{
            .codepoint = if (raw.hasText()) raw.codepoint() else null,
            .grapheme = grapheme,
            .foreground = rgb(foreground),
            .background = rgb(cell_background),
            .spacer = spacer,
            .bold = style.flags.bold,
            .faint = style.flags.faint,
            .underline = style.flags.underline != .none,
            .selected = if (self.render_state.row_data.items(.selection)[row]) |range|
                column >= range[0] and column <= range[1]
            else
                false,
        };
    }

    /// Stable representation of everything ttyrtle draws for one viewport row.
    /// The retained renderer uses this to recognize a physical terminal scroll.
    pub fn rowFingerprint(self: *const TerminalModel, row: usize) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (0..self.columns()) |column| {
            const snapshot = self.cell(row, column) orelse continue;
            hash = fingerprintMix(hash, snapshot.codepoint orelse 0);
            for (snapshot.grapheme) |codepoint|
                hash = fingerprintMix(hash, codepoint);
            hash = fingerprintMix(hash, @intFromBool(snapshot.spacer));
            hash = fingerprintMix(hash, @intFromBool(snapshot.bold));
            hash = fingerprintMix(hash, @intFromBool(snapshot.faint));
            hash = fingerprintMix(hash, @intFromBool(snapshot.underline));
            hash = fingerprintMix(hash, @intFromBool(snapshot.selected));
            hash = fingerprintMix(hash, snapshot.foreground.red);
            hash = fingerprintMix(hash, snapshot.foreground.green);
            hash = fingerprintMix(hash, snapshot.foreground.blue);
            hash = fingerprintMix(hash, snapshot.background.red);
            hash = fingerprintMix(hash, snapshot.background.green);
            hash = fingerprintMix(hash, snapshot.background.blue);
        }
        return hash;
    }

    fn viewportPin(self: *TerminalModel, row: u32, column: u32) ?ghostty.Pin {
        return self.core.screens.active.pages.pin(.{ .viewport = .{
            .x = @intCast(@min(column, self.columns() -| 1)),
            .y = @min(row, self.rows() -| 1),
        } });
    }

    fn setSelection(self: *TerminalModel, start_row: u32, start_column: u32, end_row: u32, end_column: u32) void {
        const start = self.viewportPin(start_row, start_column) orelse return;
        const end = self.viewportPin(end_row, end_column) orelse return;
        self.snapshotVisibleSelection() catch {
            self.markFullDamage();
            return;
        };
        self.core.screens.active.select(.init(start, end, false)) catch self.markFullDamage();
        self.refreshSelection() catch self.markFullDamage();
        self.markChangedVisibleSelectionRows();
    }

    fn refreshSelection(self: *TerminalModel) !void {
        self.selection_refresh = true;
        defer self.selection_refresh = false;
        try self.refresh();
    }

    fn snapshotVisibleSelection(self: *TerminalModel) !void {
        const selection = self.render_state.row_data.items(.selection);
        try self.selection_snapshot.resize(self.allocator, selection.len);
        @memcpy(self.selection_snapshot.items, selection);
    }

    fn markChangedVisibleSelectionRows(self: *TerminalModel) void {
        const current = self.render_state.row_data.items(.selection);
        const row_count = @max(self.selection_snapshot.items.len, current.len);
        for (0..row_count) |row| {
            const previous: SelectionRange = if (row < self.selection_snapshot.items.len)
                self.selection_snapshot.items[row]
            else
                null;
            const next: SelectionRange = if (row < current.len) current[row] else null;
            if (!std.meta.eql(previous, next))
                self.mergeDamageRow(@intCast(row)) catch self.markFullDamage();
        }
    }

    fn collectRenderDamage(
        self: *TerminalModel,
        old_cursor_row: ?u16,
    ) !void {
        switch (self.render_state.dirty) {
            .false => {},
            .partial => {
                const dirty_rows = self.render_state.row_data.items(.dirty);
                for (dirty_rows, 0..) |dirty, row| {
                    if (dirty) try self.mergeDamageRow(@intCast(row));
                }
            },
            .full => if (!self.selection_refresh) self.markFullDamage(),
        }

        const new_cursor_row = renderCursorRow(&self.render_state);
        if (old_cursor_row != new_cursor_row) {
            if (old_cursor_row) |row| try self.mergeDamageRow(row);
            if (new_cursor_row) |row| try self.mergeDamageRow(row);
        }

        self.render_state.dirty = .false;
        @memset(self.render_state.row_data.items(.dirty), false);
    }

    fn mergeDamageRow(self: *TerminalModel, row: u16) !void {
        if (self.damage_full or row >= self.rows()) return;
        for (self.damage_rows.items) |existing| {
            if (existing == row) return;
        }
        try self.damage_rows.append(self.allocator, row);
        if (self.damage_rows.items.len == self.rows()) self.markFullDamage();
    }

    pub fn rowTextUtf8(
        self: *const TerminalModel,
        row: usize,
        output: []u8,
    ) error{NoSpaceLeft}!usize {
        var written: usize = 0;
        for (0..self.columns()) |column| {
            const snapshot = self.cell(row, column) orelse break;
            if (snapshot.spacer) continue;
            const codepoint = snapshot.codepoint orelse break;

            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
            if (written + length > output.len) return error.NoSpaceLeft;
            @memcpy(output[written..][0..length], encoded[0..length]);
            written += length;
        }
        return written;
    }
};

fn renderCursorRow(state: *const ghostty.RenderState) ?u16 {
    const viewport = state.cursor.viewport orelse return null;
    if (!state.cursor.visible or viewport.y >= state.rows) return null;
    return viewport.y;
}

fn rgb(color: ghostty.color.RGB) Rgb {
    return .{ .red = color.r, .green = color.g, .blue = color.b };
}

fn fingerprintMix(hash: u64, value: anytype) u64 {
    return (hash ^ @as(u64, @intCast(value))) *% 0x100000001b3;
}

const VtHandler = @FieldType(ghostty.TerminalStream, "handler");
const Effects = @FieldType(VtHandler, "effects");
const DeviceAttributesFn = @typeInfo(
    @FieldType(Effects, "device_attributes"),
).optional.child;
const DeviceAttributes = @typeInfo(
    @typeInfo(DeviceAttributesFn).pointer.child,
).@"fn".return_type.?;
const ReportSizeFn = @typeInfo(
    @FieldType(Effects, "size"),
).optional.child;
const OptionalReportSize = @typeInfo(
    @typeInfo(ReportSizeFn).pointer.child,
).@"fn".return_type.?;
const ReportSize = @typeInfo(OptionalReportSize).optional.child;

test "VT output updates text, truecolor, and cursor state" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\x1b[38;2;12;34;56mHello\x1b[0m");

    var text: [32]u8 = undefined;
    const length = try model.rowTextUtf8(0, &text);
    try std.testing.expectEqualStrings("Hello", text[0..length]);

    const first = model.cell(0, 0).?;
    try std.testing.expectEqual(Rgb{ .red = 12, .green = 34, .blue = 56 }, first.foreground);
    const cursor = model.cursor();
    try std.testing.expectEqual(@as(u32, 0), cursor.row);
    try std.testing.expectEqual(@as(u32, 5), cursor.column);
}

test "cursor position uses viewport coordinates" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    model.render_state.cursor.active = .{ .x = 17, .y = 9 };
    model.render_state.cursor.viewport = .{
        .x = 3,
        .y = 2,
        .wide_tail = false,
    };

    const cursor = model.cursor();
    try std.testing.expectEqual(@as(u32, 2), cursor.row);
    try std.testing.expectEqual(@as(u32, 3), cursor.column);
}

test "UTF-8 terminal text can be read back without loss" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("h\xc3\xa9llo");

    var text: [32]u8 = undefined;
    const length = try model.rowTextUtf8(0, &text);
    try std.testing.expectEqualStrings("héllo", text[0..length]);
}

test "multiple output chunks match one combined terminal write" {
    const chunks = [_][]const u8{
        "first",
        "\x1b[2;4H",
        "\x1b[38;2;12;34;56msecond",
        "\x1b]2;batched\x07",
    };
    const combined = "first\x1b[2;4H\x1b[38;2;12;34;56msecond" ++
        "\x1b]2;batched\x07";

    var batched: TerminalModel = undefined;
    try batched.init(std.testing.allocator, 4, 20);
    defer batched.deinit();
    try batched.writeBatch(&chunks);

    var contiguous: TerminalModel = undefined;
    try contiguous.init(std.testing.allocator, 4, 20);
    defer contiguous.deinit();
    try contiguous.write(combined);

    var batched_text: [32]u8 = undefined;
    const batched_length = try batched.rowTextUtf8(1, &batched_text);
    var contiguous_text: [32]u8 = undefined;
    const contiguous_length = try contiguous.rowTextUtf8(1, &contiguous_text);
    try std.testing.expectEqualStrings(
        contiguous_text[0..contiguous_length],
        batched_text[0..batched_length],
    );
    try std.testing.expectEqual(contiguous.cursor(), batched.cursor());
    try std.testing.expectEqual(
        contiguous.cell(1, 3).?.foreground,
        batched.cell(1, 3).?.foreground,
    );
    try std.testing.expectEqualStrings(
        contiguous.core.getTitle().?,
        batched.core.getTitle().?,
    );
}

test "batch preserves UTF-8 CSI and OSC sequences split across chunks" {
    const chunks = [_][]const u8{
        "h\xc3",
        "\xa9\x1b[3",
        "1mR\x1b]2;spl",
        "it title\x07",
    };
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.writeBatch(&chunks);

    var text: [32]u8 = undefined;
    const length = try model.rowTextUtf8(0, &text);
    try std.testing.expectEqualStrings("héR", text[0..length]);
    const red = model.cell(0, 2).?.foreground;
    try std.testing.expect(red.red > red.green);
    try std.testing.expectEqual(red.green, red.blue);
    try std.testing.expectEqualStrings("split title", model.core.getTitle().?);
}

test "multi-chunk write refreshes render state once" {
    const chunks = [_][]const u8{ "one", " two", " three" };
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    const before = model.diagnostics();

    try model.writeBatch(&chunks);

    const after = model.diagnostics();
    try std.testing.expectEqual(before.output_batches + 1, after.output_batches);
    try std.testing.expectEqual(before.chunks_parsed + chunks.len, after.chunks_parsed);
    try std.testing.expectEqual(before.render_refreshes + 1, after.render_refreshes);
}

test "one-line terminal update reports only that row" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.acknowledgeDamage();

    try model.write("hello");

    const rows = switch (model.damage()) {
        .partial => |rows| rows,
        else => return error.ExpectedPartialDamage,
    };
    try std.testing.expectEqualSlices(u16, &.{0}, rows);
}

test "palette change reports full damage" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.acknowledgeDamage();

    try model.write("\x1b]4;1;#010203\x07");

    try std.testing.expect(model.damage() == .full);
}

test "cursor movement damages old and new rows" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.acknowledgeDamage();

    try model.write("\x1b[2;1H");

    const rows = switch (model.damage()) {
        .partial => |rows| rows,
        else => return error.ExpectedPartialDamage,
    };
    try std.testing.expectEqualSlices(u16, &.{ 0, 1 }, rows);
}

test "cursor blinking damages only the cursor row" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.acknowledgeDamage();
    model.render_state.cursor.blinking = true;
    model.render_state.cursor.viewport = .{
        .x = 3,
        .y = 2,
        .wide_tail = false,
    };

    model.toggleCursorBlink();

    const rows = switch (model.damage()) {
        .partial => |rows| rows,
        else => return error.ExpectedPartialDamage,
    };
    try std.testing.expectEqualSlices(u16, &.{2}, rows);
}

test "selection changes damage only its old and new visible rows" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 5, 20);
    defer model.deinit();
    model.acknowledgeDamage();

    model.startSelection(1, 3);
    var rows = switch (model.damage()) {
        .partial => |value| value,
        else => return error.ExpectedPartialDamage,
    };
    try std.testing.expectEqualSlices(u16, &.{1}, rows);
    model.acknowledgeDamage();

    model.updateSelection(2, 4);
    rows = switch (model.damage()) {
        .partial => |value| value,
        else => return error.ExpectedPartialDamage,
    };
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, rows);
}

test "selection extension damages only rows whose selected range changed" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 5, 20);
    defer model.deinit();
    model.acknowledgeDamage();

    model.startSelection(0, 3);
    model.updateSelection(3, 4);
    model.acknowledgeDamage();

    model.updateSelection(3, 5);

    const rows = switch (model.damage()) {
        .partial => |value| value,
        else => return error.ExpectedPartialDamage,
    };
    try std.testing.expectEqualSlices(u16, &.{3}, rows);
}

test "damage remains pending until acknowledged" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.acknowledgeDamage();

    try model.write("x");
    try model.refresh();
    try std.testing.expect(model.damage() == .partial);

    model.acknowledgeDamage();
    try std.testing.expect(model.damage() == .none);
}

test "row text reports insufficient output space" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 2, 10);
    defer model.deinit();

    try model.write("hello");

    var text: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, model.rowTextUtf8(0, &text));
}

test "resize updates grid and carries cell pixel geometry" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.resize(12, 40, 9, 18);

    try std.testing.expectEqual(@as(u16, 12), model.rows());
    try std.testing.expectEqual(@as(u16, 40), model.columns());
    try std.testing.expectEqual(@as(u32, 360), model.core.width_px);
    try std.testing.expectEqual(@as(u32, 216), model.core.height_px);
}

test "terminal queries deliver owned replies through the configured sink" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        replies: std.ArrayListUnmanaged([]u8) = .empty,

        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.replies.append(self.allocator, try self.allocator.dupe(u8, bytes));
        }

        fn deinit(self: *@This()) void {
            for (self.replies.items) |reply| self.allocator.free(reply);
            self.replies.deinit(self.allocator);
        }
    };

    var capture: Capture = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.setReplySink(.{ .context = &capture, .write = Capture.write });

    try model.write("\x1b[2;3H\x1b[6n\x1b[c");

    try std.testing.expectEqual(@as(usize, 2), capture.replies.items.len);
    try std.testing.expectEqualStrings("\x1b[2;3R", capture.replies.items[0]);
    try std.testing.expect(std.mem.startsWith(u8, capture.replies.items[1], "\x1b[?"));
}

test "terminal replies preserve ordering with queued keyboard input" {
    const Capture = struct {
        allocator: std.mem.Allocator,
        writes: std.ArrayListUnmanaged([]u8) = .empty,

        fn append(self: *@This(), bytes: []const u8) !void {
            try self.writes.append(
                self.allocator,
                try self.allocator.dupe(u8, bytes),
            );
        }

        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.append(bytes);
        }

        fn deinit(self: *@This()) void {
            for (self.writes.items) |bytes| self.allocator.free(bytes);
            self.writes.deinit(self.allocator);
        }
    };

    var capture: Capture = .{ .allocator = std.testing.allocator };
    defer capture.deinit();
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.setReplySink(.{ .context = &capture, .write = Capture.write });
    const output = [_][]const u8{ "\x1b[2;3H\x1b[", "6n" };

    try capture.append("keyboard-before");
    try model.writeBatch(&output);
    try capture.append("keyboard-after");

    try std.testing.expectEqual(@as(usize, 3), capture.writes.items.len);
    try std.testing.expectEqualStrings(
        "keyboard-before",
        capture.writes.items[0],
    );
    try std.testing.expectEqualStrings("\x1b[2;3R", capture.writes.items[1]);
    try std.testing.expectEqualStrings(
        "keyboard-after",
        capture.writes.items[2],
    );
}

test "reply failure is reported after every chunk has been parsed" {
    const FailingSink = struct {
        fn write(_: *anyopaque, _: []const u8) !void {
            return error.WriteFailed;
        }
    };

    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();
    model.setReplySink(.{ .context = &model, .write = FailingSink.write });
    const output = [_][]const u8{ "\x1b[6n", "still parsed" };

    try std.testing.expectError(
        error.ReplyDeliveryFailed,
        model.writeBatch(&output),
    );
    try model.refresh();

    var text: [32]u8 = undefined;
    const length = try model.rowTextUtf8(0, &text);
    try std.testing.expectEqualStrings("still parsed", text[0..length]);
}

test "title and bell effects are retained until consumed" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\x1b]2;working\x07\x07");

    try std.testing.expect(model.takeTitleChanged());
    try std.testing.expect(!model.takeTitleChanged());
    try std.testing.expectEqual(@as(usize, 1), model.takeBellCount());
    try std.testing.expectEqualStrings("working", model.core.getTitle().?);
}

test "selection extracts trimmed multiline Unicode text" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 3, 8);
    defer model.deinit();
    try model.write("héllo\r\nworld");
    model.startSelection(0, 1);
    model.updateSelection(1, 4);

    const text = try model.selectionTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("éllo\nworld", text);
    try std.testing.expect(model.cell(0, 1).?.selected);
    try std.testing.expect(!model.cell(0, 0).?.selected);
}

test "scrollback retains history and output does not dislodge a historical viewport" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 3, 16);
    defer model.deinit();

    try model.write("first\r\nsecond\r\nthird\r\nfourth\r\nfifth");
    try model.scrollViewportTop();
    try std.testing.expect(!model.viewportFollowsBottom());
    var buffer: [16]u8 = undefined;
    const first_length = try model.rowTextUtf8(0, &buffer);
    try std.testing.expectEqualStrings("first", buffer[0..first_length]);

    try model.write("\r\nsixth");
    try std.testing.expect(!model.viewportFollowsBottom());
    const retained_length = try model.rowTextUtf8(0, &buffer);
    try std.testing.expectEqualStrings("first", buffer[0..retained_length]);

    try model.scrollViewportBottom();
    try std.testing.expect(model.viewportFollowsBottom());
}

test "scrollback delta and page navigation clamp at live bottom" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 16);
    defer model.deinit();
    try model.write("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6");

    try model.scrollViewport(-1);
    try std.testing.expect(!model.viewportFollowsBottom());
    try model.scrollViewportPage(.down);
    try std.testing.expect(model.viewportFollowsBottom());
    try model.scrollViewportTop();
    try std.testing.expect(!model.viewportFollowsBottom());
    try model.scrollViewportPage(.up);
    try std.testing.expect(!model.viewportFollowsBottom());
}
