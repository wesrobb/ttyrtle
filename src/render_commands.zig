const std = @import("std");
const geometry = @import("geometry.zig");
const terminal = @import("terminal.zig");

pub const TextRun = struct {
    x: i32,
    y: i32,
    color: terminal.Rgb,
    text: std.ArrayListUnmanaged(u16) = .empty,

    fn deinit(self: *TextRun, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

pub const Rectangle = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    color: terminal.Rgb,
    outline: bool = false,
};

pub const Frame = struct {
    allocator: std.mem.Allocator,
    background: terminal.Rgb = .{ .red = 12, .green = 16, .blue = 20 },
    rectangles: std.ArrayListUnmanaged(Rectangle) = .empty,
    text_runs: std.ArrayListUnmanaged(TextRun) = .empty,

    pub fn build(
        allocator: std.mem.Allocator,
        model: *const terminal.TerminalModel,
        metrics: geometry.Metrics,
    ) !Frame {
        var frame: Frame = .{ .allocator = allocator };
        errdefer frame.deinit();
        frame.background = model.background();
        const cursor = model.cursor();

        for (0..model.rows()) |row| {
            var active_run: ?usize = null;
            for (0..model.columns()) |column| {
                const cell = model.cell(row, column) orelse {
                    active_run = null;
                    continue;
                };
                const x: i32 = @intCast(
                    metrics.margin_x +
                        @as(u32, @intCast(column)) * metrics.cell_width,
                );
                const y: i32 = @intCast(
                    metrics.margin_y +
                        @as(u32, @intCast(row)) * metrics.cell_height,
                );
                const cell_background = if (cell.selected)
                    cell.foreground
                else
                    cell.background;
                const cell_foreground = if (cell.selected)
                    cell.background
                else
                    cell.foreground;
                if (!std.meta.eql(cell_background, frame.background)) {
                    try frame.rectangles.append(allocator, .{
                        .left = x,
                        .top = y,
                        .right = x + @as(i32, @intCast(metrics.cell_width)),
                        .bottom = y + @as(i32, @intCast(metrics.cell_height)),
                        .color = cell_background,
                    });
                }
                const cursor_here = cursor.visible and
                    cursor.row == row and cursor.column == column;
                if (cursor_here) try appendCursor(
                    allocator,
                    &frame,
                    cursor,
                    x,
                    y,
                    metrics,
                );
                if (cell.underline) {
                    try frame.rectangles.append(allocator, .{
                        .left = x,
                        .top = y + @as(i32, @intCast(metrics.cell_height)) - 2,
                        .right = x + @as(i32, @intCast(metrics.cell_width)),
                        .bottom = y + @as(i32, @intCast(metrics.cell_height)),
                        .color = cell.foreground,
                    });
                }
                if (cell.spacer) continue;
                const codepoint = cell.codepoint orelse {
                    active_run = null;
                    continue;
                };

                if (active_run == null or
                    !std.meta.eql(
                        frame.text_runs.items[active_run.?].color,
                        if (cursor_here and cursor.style == .block)
                            cell_background
                        else
                            cell_foreground,
                    ))
                {
                    try frame.text_runs.append(allocator, .{
                        .x = x,
                        .y = y,
                        .color = if (cursor_here and cursor.style == .block)
                            cell_background
                        else
                            cell_foreground,
                    });
                    active_run = frame.text_runs.items.len - 1;
                }

                try appendUtf16(
                    allocator,
                    &frame.text_runs.items[active_run.?],
                    codepoint,
                );
                for (cell.grapheme) |grapheme| try appendUtf16(
                    allocator,
                    &frame.text_runs.items[active_run.?],
                    grapheme,
                );
            }
        }
        for (frame.text_runs.items) |*run| try run.text.append(allocator, 0);

        return frame;
    }

    pub fn deinit(self: *Frame) void {
        for (self.text_runs.items) |*run| run.deinit(self.allocator);
        self.rectangles.deinit(self.allocator);
        self.text_runs.deinit(self.allocator);
        self.* = undefined;
    }
};

fn appendCursor(
    allocator: std.mem.Allocator,
    frame: *Frame,
    cursor: terminal.Cursor,
    x: i32,
    y: i32,
    metrics: geometry.Metrics,
) !void {
    const width: i32 = @intCast(metrics.cell_width);
    const height: i32 = @intCast(metrics.cell_height);
    try frame.rectangles.append(allocator, switch (cursor.style) {
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

fn appendUtf16(
    allocator: std.mem.Allocator,
    run: *TextRun,
    codepoint: u21,
) !void {
    if (codepoint <= 0xffff) {
        try run.text.append(allocator, @intCast(codepoint));
        return;
    }

    const value = codepoint - 0x10000;
    try run.text.append(allocator, @intCast(0xd800 + (value >> 10)));
    try run.text.append(allocator, @intCast(0xdc00 + (value & 0x3ff)));
}

test "frame groups adjacent terminal cells by foreground color" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\x1b[31mred\x1b[32mgreen");
    var frame = try Frame.build(std.testing.allocator, &model, .forDpi(96));
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 2), frame.text_runs.items.len);
    try std.testing.expectEqual(@as(usize, 4), frame.text_runs.items[0].text.items.len);
    try std.testing.expectEqual(@as(usize, 6), frame.text_runs.items[1].text.items.len);
    try std.testing.expect(frame.text_runs.items[0].x < frame.text_runs.items[1].x);
    try std.testing.expect(
        !std.meta.eql(frame.text_runs.items[0].color, frame.text_runs.items[1].color),
    );
}

test "frame encodes non-BMP codepoints as UTF-16 surrogate pairs" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\xf0\x9f\x91\xbb");
    var frame = try Frame.build(std.testing.allocator, &model, .forDpi(96));
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 1), frame.text_runs.items.len);
    try std.testing.expectEqual(@as(usize, 3), frame.text_runs.items[0].text.items.len);
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("👻"),
        frame.text_runs.items[0].text.items[0..2],
    );
}

test "frame renders text on every row and preserves blank cell positions" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 24, 80);
    defer model.deinit();

    try model.write("top\x1b[24;80HX");
    const metrics: geometry.Metrics = .forDpi(96);
    var frame = try Frame.build(std.testing.allocator, &model, metrics);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 2), frame.text_runs.items.len);
    try std.testing.expectEqual(@as(i32, @intCast(metrics.margin_y)), frame.text_runs.items[0].y);
    try std.testing.expectEqual(
        @as(i32, @intCast(metrics.margin_y + 23 * metrics.cell_height)),
        frame.text_runs.items[1].y,
    );
    try std.testing.expectEqual(
        @as(i32, @intCast(metrics.margin_x + 79 * metrics.cell_width)),
        frame.text_runs.items[1].x,
    );
}

test "frame emits cell backgrounds inverse video and cursor geometry" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\x1b[48;2;1;2;3mA\x1b[7mB\x1b[0m\x1b[2 q");
    var frame = try Frame.build(std.testing.allocator, &model, .forDpi(96));
    defer frame.deinit();

    try std.testing.expect(frame.rectangles.items.len >= 3);
    const first = model.cell(0, 0).?;
    try std.testing.expectEqual(
        terminal.Rgb{ .red = 1, .green = 2, .blue = 3 },
        first.background,
    );
    const inverse = model.cell(0, 1).?;
    try std.testing.expectEqual(first.foreground, inverse.background);
    try std.testing.expectEqual(terminal.CursorStyle.block, model.cursor().style);
}

test "frame includes combining grapheme codepoints" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("e\xcc\x81");
    var frame = try Frame.build(std.testing.allocator, &model, .forDpi(96));
    defer frame.deinit();

    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("é"),
        frame.text_runs.items[0].text.items[0..2],
    );
}
