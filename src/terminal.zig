const std = @import("std");
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
        self.stream.nextSlice(bytes);
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
        return .{
            .row = self.render_state.cursor.active.y,
            .column = self.render_state.cursor.active.x,
            .style = switch (self.render_state.cursor.visual_style) {
                .bar => .bar,
                .block => .block,
                .underline => .underline,
                .block_hollow => .block_hollow,
            },
            .color = rgb(raw_color),
            .visible = self.render_state.cursor.visible and
                self.render_state.cursor.viewport != null,
            .blinking = self.render_state.cursor.blinking,
        };
    }

    pub fn background(self: *const TerminalModel) Rgb {
        return rgb(self.render_state.colors.background);
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
        };
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

test "UTF-8 terminal text can be read back without loss" {
    var model: TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("h\xc3\xa9llo");

    var text: [32]u8 = undefined;
    const length = try model.rowTextUtf8(0, &text);
    try std.testing.expectEqualStrings("héllo", text[0..length]);
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
