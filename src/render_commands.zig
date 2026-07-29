const std = @import("std");
const terminal = @import("terminal.zig");

pub const cell_width = 8;
pub const origin_x = 24;
pub const origin_y = 24;
pub const max_text_runs = 80;
pub const max_utf16_units = 160;

pub const TextRun = struct {
    x: i32,
    y: i32,
    color: terminal.Rgb,
    text: [max_utf16_units:0]u16 = [_:0]u16{0} ** max_utf16_units,
    length: usize = 0,
};

pub const Frame = struct {
    background: terminal.Rgb = .{ .red = 12, .green = 16, .blue = 20 },
    text_runs: [max_text_runs]TextRun = undefined,
    text_run_count: usize = 0,

    pub fn build(model: *const terminal.TerminalModel) Frame {
        var frame: Frame = .{};
        var active_run: ?usize = null;

        for (0..model.columns()) |column| {
            const cell = model.cell(0, column) orelse break;
            if (cell.spacer) continue;
            const codepoint = cell.codepoint orelse break;

            if (active_run == null or
                !std.meta.eql(frame.text_runs[active_run.?].color, cell.foreground))
            {
                if (frame.text_run_count == max_text_runs) break;
                const index = frame.text_run_count;
                frame.text_runs[index] = .{
                    .x = origin_x + @as(i32, @intCast(column)) * cell_width,
                    .y = origin_y,
                    .color = cell.foreground,
                };
                frame.text_run_count += 1;
                active_run = index;
            }

            appendUtf16(&frame.text_runs[active_run.?], codepoint) catch break;
        }

        return frame;
    }
};

fn appendUtf16(run: *TextRun, codepoint: u21) error{NoSpaceLeft}!void {
    const required: usize = if (codepoint <= 0xffff) 1 else 2;
    if (run.length + required > run.text.len - 1) return error.NoSpaceLeft;

    if (required == 1) {
        run.text[run.length] = @intCast(codepoint);
        run.length += 1;
        return;
    }

    const value = codepoint - 0x10000;
    run.text[run.length] = @intCast(0xd800 + (value >> 10));
    run.text[run.length + 1] = @intCast(0xdc00 + (value & 0x3ff));
    run.length += 2;
}

test "frame groups adjacent terminal cells by foreground color" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\x1b[31mred\x1b[32mgreen");
    const frame = Frame.build(&model);

    try std.testing.expectEqual(@as(usize, 2), frame.text_run_count);
    try std.testing.expectEqual(@as(usize, 3), frame.text_runs[0].length);
    try std.testing.expectEqual(@as(usize, 5), frame.text_runs[1].length);
    try std.testing.expect(frame.text_runs[0].x < frame.text_runs[1].x);
    try std.testing.expect(
        !std.meta.eql(frame.text_runs[0].color, frame.text_runs[1].color),
    );
}

test "frame encodes non-BMP codepoints as UTF-16 surrogate pairs" {
    var model: terminal.TerminalModel = undefined;
    try model.init(std.testing.allocator, 4, 20);
    defer model.deinit();

    try model.write("\xf0\x9f\x91\xbb");
    const frame = Frame.build(&model);

    try std.testing.expectEqual(@as(usize, 1), frame.text_run_count);
    try std.testing.expectEqual(@as(usize, 2), frame.text_runs[0].length);
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("👻"),
        frame.text_runs[0].text[0..2],
    );
}
