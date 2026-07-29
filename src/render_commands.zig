const std = @import("std");
const terminal = @import("terminal.zig");

pub const cell_width = 8;
pub const cell_height = 16;
pub const origin_x = 24;
pub const origin_y = 24;

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

pub const Frame = struct {
    allocator: std.mem.Allocator,
    background: terminal.Rgb = .{ .red = 12, .green = 16, .blue = 20 },
    text_runs: std.ArrayListUnmanaged(TextRun) = .empty,

    pub fn build(
        allocator: std.mem.Allocator,
        model: *const terminal.TerminalModel,
    ) !Frame {
        var frame: Frame = .{ .allocator = allocator };
        errdefer frame.deinit();

        for (0..model.rows()) |row| {
            var active_run: ?usize = null;
            for (0..model.columns()) |column| {
                const cell = model.cell(row, column) orelse {
                    active_run = null;
                    continue;
                };
                if (cell.spacer) continue;
                const codepoint = cell.codepoint orelse {
                    active_run = null;
                    continue;
                };

                if (active_run == null or
                    !std.meta.eql(
                        frame.text_runs.items[active_run.?].color,
                        cell.foreground,
                    ))
                {
                    try frame.text_runs.append(allocator, .{
                        .x = origin_x + @as(i32, @intCast(column)) * cell_width,
                        .y = origin_y + @as(i32, @intCast(row)) * cell_height,
                        .color = cell.foreground,
                    });
                    active_run = frame.text_runs.items.len - 1;
                }

                try appendUtf16(
                    allocator,
                    &frame.text_runs.items[active_run.?],
                    codepoint,
                );
            }
        }
        for (frame.text_runs.items) |*run| try run.text.append(allocator, 0);

        return frame;
    }

    pub fn deinit(self: *Frame) void {
        for (self.text_runs.items) |*run| run.deinit(self.allocator);
        self.text_runs.deinit(self.allocator);
        self.* = undefined;
    }
};

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
    var frame = try Frame.build(std.testing.allocator, &model);
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
    var frame = try Frame.build(std.testing.allocator, &model);
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
    var frame = try Frame.build(std.testing.allocator, &model);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 2), frame.text_runs.items.len);
    try std.testing.expectEqual(origin_y, frame.text_runs.items[0].y);
    try std.testing.expectEqual(
        origin_y + 23 * cell_height,
        frame.text_runs.items[1].y,
    );
    try std.testing.expectEqual(
        origin_x + 79 * cell_width,
        frame.text_runs.items[1].x,
    );
}
