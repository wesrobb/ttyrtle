const std = @import("std");
const win32 = @import("win32");
const render_commands = @import("render_commands.zig");
const terminal = @import("terminal.zig");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const wm = win32.ui.windows_and_messaging;
const gdi32 = win32.gdi32;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Win32Terminal");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("win32-terminal");

pub const Mode = enum {
    normal,
    smoke,
};

var model: terminal.TerminalModel = undefined;
var model_initialized = false;
var smoke_mode = false;
var paint_completed = false;

pub fn run(mode: Mode) !void {
    const allocator = std.heap.smp_allocator;
    smoke_mode = mode == .smoke;
    paint_completed = false;

    try model.init(allocator, 24, 80);
    model_initialized = true;
    defer {
        model.deinit();
        model_initialized = false;
    }
    try model.write("\x1b[38;2;126;231;135mHello from libghostty.\x1b[0m");

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
    defer if (user32.IsWindow(window) != 0) {
        _ = user32.DestroyWindow(window);
    };

    _ = user32.ShowWindow(window, if (smoke_mode) wm.SW_HIDE else wm.SW_SHOWDEFAULT);
    if (smoke_mode) {
        _ = user32.SendMessageW(window, wm.WM_PAINT, 0, 0);
    } else {
        _ = user32.UpdateWindow(window);
    }

    var message: wm.MSG = undefined;
    while (true) {
        const result = user32.GetMessageW(&message, null, 0, 0);
        if (result == 0) break;
        if (result < 0) return error.GetMessageFailed;
        _ = user32.TranslateMessage(&message);
        _ = user32.DispatchMessageW(&message);
    }

    if (smoke_mode and !paint_completed) return error.SmokePaintFailed;
}

fn windowProc(
    window: foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    switch (message) {
        wm.WM_PAINT => {
            paint_completed = paint(window);
            if (smoke_mode) {
                _ = user32.PostMessageW(window, wm.WM_CLOSE, 0, 0);
            }
            return 0;
        },
        wm.WM_DESTROY => {
            user32.PostQuitMessage(0);
            return 0;
        },
        else => return user32.DefWindowProcW(window, message, wparam, lparam),
    }
}

fn paint(window: foundation.HWND) bool {
    if (!model_initialized) return false;

    var paint_state: gdi.PAINTSTRUCT = undefined;
    const dc = user32.BeginPaint(window, &paint_state) orelse return false;
    defer _ = user32.EndPaint(window, &paint_state);

    const frame = render_commands.Frame.build(&model);
    const background = gdi32.CreateSolidBrush(toColorRef(frame.background)) orelse
        return false;
    defer _ = gdi32.DeleteObject(background);

    _ = user32.FillRect(dc, &paint_state.rcPaint, background);
    _ = gdi32.SetBkMode(dc, gdi.TRANSPARENT);

    for (frame.text_runs[0..frame.text_run_count]) |*text_run| {
        _ = gdi32.SetTextColor(dc, toColorRef(text_run.color));
        if (gdi32.TextOutW(
            dc,
            text_run.x,
            text_run.y,
            &text_run.text,
            @intCast(text_run.length),
        ) == 0) return false;
    }

    return frame.text_run_count > 0;
}

fn toColorRef(color: terminal.Rgb) win32.zig.COLORREF {
    return .rgb(color.red, color.green, color.blue);
}
