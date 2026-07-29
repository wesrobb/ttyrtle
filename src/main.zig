const std = @import("std");
const ghostty = @import("ghostty-vt");
const win32 = @import("win32");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const wm = win32.ui.windows_and_messaging;
const gdi32 = win32.gdi32;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Win32Terminal");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("win32-terminal");

var terminal: ?ghostty.Terminal = null;
var render_state: ghostty.RenderState = .empty;

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    terminal = try .init(
        std.Io.Threaded.global_single_threaded.io(),
        allocator,
        .{ .rows = 24, .cols = 80 },
    );
    defer {
        render_state.deinit(allocator);
        terminal.?.deinit(allocator);
    }

    var stream = terminal.?.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[38;2;126;231;135mHello from libghostty.\x1b[0m");
    try render_state.update(allocator, &terminal.?);

    const instance = kernel32.GetModuleHandleW(null) orelse
        return error.GetModuleHandleFailed;

    const window_class: wm.WNDCLASSEXW = .{
        .cbSize = @sizeOf(wm.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = user32.LoadCursorW(null, wm.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (user32.RegisterClassExW(&window_class) == 0)
        return error.RegisterClassFailed;

    const window = user32.CreateWindowExW(
        .{},
        class_name,
        window_title,
        wm.WS_OVERLAPPEDWINDOW,
        wm.CW_USEDEFAULT,
        wm.CW_USEDEFAULT,
        900,
        560,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;

    _ = user32.ShowWindow(window, wm.SW_SHOWDEFAULT);
    _ = user32.UpdateWindow(window);

    var message: wm.MSG = undefined;
    while (user32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = user32.TranslateMessage(&message);
        _ = user32.DispatchMessageW(&message);
    }
}

fn windowProc(
    window: foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    switch (message) {
        wm.WM_PAINT => {
            paint(window);
            return 0;
        },
        wm.WM_DESTROY => {
            user32.PostQuitMessage(0);
            return 0;
        },
        else => return user32.DefWindowProcW(window, message, wparam, lparam),
    }
}

fn paint(window: foundation.HWND) void {
    var paint_state: gdi.PAINTSTRUCT = undefined;
    const dc = user32.BeginPaint(window, &paint_state) orelse return;
    defer _ = user32.EndPaint(window, &paint_state);

    const background = gdi32.CreateSolidBrush(rgb(12, 16, 20)) orelse return;
    defer _ = gdi32.DeleteObject(background);
    _ = user32.FillRect(dc, &paint_state.rcPaint, background);

    _ = gdi32.SetBkMode(dc, gdi.TRANSPARENT);
    _ = gdi32.SetTextColor(dc, rgb(126, 231, 135));

    var text: [81:0]u16 = [_:0]u16{0} ** 81;
    var length: usize = 0;

    if (render_state.row_data.len > 0) {
        const rows = render_state.row_data.items(.cells);
        const cells = rows[0].items(.raw);
        for (cells) |cell| {
            if (!cell.hasText()) break;
            const codepoint = cell.codepoint();
            if (codepoint > 0x7f or length == text.len - 1) break;
            text[length] = @intCast(codepoint);
            length += 1;
        }
    }

    if (length > 0) {
        _ = gdi32.TextOutW(dc, 24, 24, &text, @intCast(length));
    }
}

fn rgb(red: u8, green: u8, blue: u8) win32.zig.COLORREF {
    return .rgb(red, green, blue);
}
