const std = @import("std");
const ghostty = @import("ghostty-vt");

pub const Rgb = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const CellSnapshot = struct {
    codepoint: ?u21,
    foreground: Rgb,
    spacer: bool,
};

pub const Cursor = struct {
    row: u32,
    column: u32,
};

pub const TerminalModel = struct {
    allocator: std.mem.Allocator,
    core: ghostty.Terminal,
    stream: ghostty.TerminalStream,
    render_state: ghostty.RenderState,

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
        };
        errdefer self.core.deinit(allocator);

        self.stream = self.core.vtStream();
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
        try self.refresh();
    }

    pub fn resize(
        self: *TerminalModel,
        row_count: u16,
        column_count: u16,
        cell_width: u32,
        cell_height: u32,
    ) !void {
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
        return .{
            .row = self.render_state.cursor.active.y,
            .column = self.render_state.cursor.active.x,
        };
    }

    pub fn cell(self: *const TerminalModel, row: usize, column: usize) ?CellSnapshot {
        if (row >= self.render_state.row_data.len) return null;

        const rows_slice = self.render_state.row_data.slice();
        const row_cells = rows_slice.items(.cells);
        const cells = row_cells[row].slice();
        const raw_cells = cells.items(.raw);
        if (column >= raw_cells.len) return null;

        const raw = raw_cells[column];
        const spacer = switch (raw.wide) {
            .spacer_head, .spacer_tail => true,
            else => false,
        };

        const style: ghostty.Style = if (raw.style_id == 0)
            .{}
        else
            cells.items(.style)[column];
        const foreground = style.fg(.{
            .default = self.render_state.colors.foreground,
            .palette = &self.render_state.colors.palette,
        });

        return .{
            .codepoint = if (raw.hasText()) raw.codepoint() else null,
            .foreground = .{
                .red = foreground.r,
                .green = foreground.g,
                .blue = foreground.b,
            },
            .spacer = spacer,
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
    try std.testing.expectEqual(Cursor{ .row = 0, .column = 5 }, model.cursor());
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
