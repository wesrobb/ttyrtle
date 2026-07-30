const std = @import("std");
const builtin = @import("builtin");
const ghostty = @import("ghostty-vt");

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

pub const TerminalModel = struct {
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
    selection_anchor: ?Cursor,
    selection_head: ?Cursor,
    cursor_blink_visible: bool,
    render_refresh_count: if (builtin.is_test) usize else void,

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
                .{ .rows = row_count, .cols = column_count },
            ),
            .stream = undefined,
            .render_state = .empty,
            .reply_sink = null,
            .reply_failed = false,
            .title_changed = false,
            .bell_count = 0,
            .cell_width = 0,
            .cell_height = 0,
            .selection_anchor = null,
            .selection_head = null,
            .cursor_blink_visible = true,
            .render_refresh_count = if (builtin.is_test) 0 else {},
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
        for (chunks) |bytes| self.stream.nextSlice(bytes);
        if (self.reply_failed) {
            self.reply_failed = false;
            return error.ReplyDeliveryFailed;
        }
        try self.refresh();
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
        try self.render_state.update(self.allocator, &self.core);
        if (builtin.is_test) self.render_refresh_count +|= 1;
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
    }

    pub fn resetCursorBlink(self: *TerminalModel) void {
        self.cursor_blink_visible = true;
    }

    pub fn background(self: *const TerminalModel) Rgb {
        return rgb(self.render_state.colors.background);
    }

    pub fn startSelection(self: *TerminalModel, row: u32, column: u32) void {
        const point: Cursor = .{
            .row = @min(row, self.rows() -| 1),
            .column = @min(column, self.columns() -| 1),
            .style = .block,
            .color = .{ .red = 0, .green = 0, .blue = 0 },
            .visible = false,
            .blinking = false,
        };
        self.selection_anchor = point;
        self.selection_head = point;
    }

    pub fn updateSelection(self: *TerminalModel, row: u32, column: u32) void {
        if (self.selection_anchor == null) return;
        self.selection_head = .{
            .row = @min(row, self.rows() -| 1),
            .column = @min(column, self.columns() -| 1),
            .style = .block,
            .color = .{ .red = 0, .green = 0, .blue = 0 },
            .visible = false,
            .blinking = false,
        };
    }

    pub fn clearSelection(self: *TerminalModel) void {
        self.selection_anchor = null;
        self.selection_head = null;
    }

    pub fn selectionTextAlloc(
        self: *const TerminalModel,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const bounds = self.selectionBounds() orelse return allocator.alloc(u8, 0);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        for (bounds.start.row..bounds.end.row + 1) |row| {
            const first_column = if (row == bounds.start.row)
                bounds.start.column
            else
                0;
            const last_column = if (row == bounds.end.row)
                bounds.end.column
            else
                self.columns() - 1;
            var line: std.Io.Writer.Allocating = .init(allocator);
            defer line.deinit();
            for (first_column..last_column + 1) |column| {
                const snapshot = self.cell(row, column) orelse continue;
                if (snapshot.spacer) continue;
                const codepoint = snapshot.codepoint orelse ' ';
                try writeCodepoint(&line.writer, codepoint);
                for (snapshot.grapheme) |grapheme|
                    try writeCodepoint(&line.writer, grapheme);
            }
            const text = std.mem.trimEnd(u8, line.writer.buffered(), " ");
            try output.writer.writeAll(text);
            if (row != bounds.end.row) try output.writer.writeByte('\n');
        }
        return output.toOwnedSlice();
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
            .selected = self.isSelected(@intCast(row), @intCast(column)),
        };
    }

    const SelectionBounds = struct {
        start: Cursor,
        end: Cursor,
    };

    fn selectionBounds(self: *const TerminalModel) ?SelectionBounds {
        var start = self.selection_anchor orelse return null;
        var end = self.selection_head orelse return null;
        if (end.row < start.row or
            (end.row == start.row and end.column < start.column))
            std.mem.swap(Cursor, &start, &end);
        return .{ .start = start, .end = end };
    }

    fn isSelected(self: *const TerminalModel, row: u32, column: u32) bool {
        const bounds = self.selectionBounds() orelse return false;
        if (row < bounds.start.row or row > bounds.end.row) return false;
        if (row == bounds.start.row and column < bounds.start.column) return false;
        if (row == bounds.end.row and column > bounds.end.column) return false;
        return true;
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

fn rgb(color: ghostty.color.RGB) Rgb {
    return .{ .red = color.r, .green = color.g, .blue = color.b };
}

fn writeCodepoint(writer: *std.Io.Writer, codepoint: u21) !void {
    var encoded: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(codepoint, &encoded);
    try writer.writeAll(encoded[0..length]);
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
    const refresh_count = model.render_refresh_count;

    try model.writeBatch(&chunks);

    try std.testing.expectEqual(
        refresh_count + 1,
        model.render_refresh_count,
    );
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
