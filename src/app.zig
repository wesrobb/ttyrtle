const std = @import("std");
const win32 = @import("win32");
const conpty = @import("conpty.zig");
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
    integration,
};

var model: terminal.TerminalModel = undefined;
var model_initialized = false;
var active_mode: Mode = .normal;
var paint_completed = false;
var integration_succeeded = false;
var session: ?*conpty.Session = null;

const integration_marker = "CONPTY_STEP_1_OK";
const integration_command =
    "cmd.exe /d /q /s /c \"echo \x1b[38;2;12;34;56m" ++
    integration_marker ++ "\x1b[0m > CON & ping -n 2 127.0.0.1 >nul\"";

pub fn run(mode: Mode) !void {
    const allocator = std.heap.smp_allocator;
    active_mode = mode;
    paint_completed = false;
    integration_succeeded = false;
    session = null;

    try model.init(allocator, 24, 80);
    model_initialized = true;
    defer {
        model.deinit();
        model_initialized = false;
    }
    if (mode == .smoke)
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
    defer _ = user32.UnregisterClassW(class_name, instance);

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

    if (mode != .smoke) {
        session = try conpty.Session.create(
            allocator,
            window,
            if (mode == .integration) integration_command else null,
        );
    }
    defer if (session) |active_session| {
        active_session.destroy();
        session = null;
    };

    _ = user32.ShowWindow(
        window,
        if (mode == .normal) wm.SW_SHOWDEFAULT else wm.SW_HIDE,
    );
    if (mode == .smoke) {
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

    if (mode == .smoke and !paint_completed) return error.SmokePaintFailed;
    if (mode == .integration and !integration_succeeded)
        return error.ConptyIntegrationFailed;
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
            if (active_mode == .smoke) {
                _ = user32.PostMessageW(window, wm.WM_CLOSE, 0, 0);
            }
            return 0;
        },
        conpty.output_message => {
            handleConptyOutput(window);
            return 0;
        },
        conpty.child_exit_message => {
            if (session) |active_session| active_session.closeAfterChildExit();
            return 0;
        },
        wm.WM_CLOSE => {
            if (session) |active_session| {
                active_session.destroy();
                session = null;
            }
            _ = user32.DestroyWindow(window);
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

    var frame = render_commands.Frame.build(std.heap.smp_allocator, &model) catch
        return false;
    defer frame.deinit();
    const background = gdi32.CreateSolidBrush(toColorRef(frame.background)) orelse
        return false;
    defer _ = gdi32.DeleteObject(background);

    _ = user32.FillRect(dc, &paint_state.rcPaint, background);
    _ = gdi32.SetBkMode(dc, gdi.TRANSPARENT);

    for (frame.text_runs.items) |*text_run| {
        _ = gdi32.SetTextColor(dc, toColorRef(text_run.color));
        if (gdi32.TextOutW(
            dc,
            text_run.x,
            text_run.y,
            @ptrCast(text_run.text.items.ptr),
            @intCast(text_run.text.items.len - 1),
        ) == 0) return false;
    }

    return true;
}

fn toColorRef(color: terminal.Rgb) win32.zig.COLORREF {
    return .rgb(color.red, color.green, color.blue);
}

fn handleConptyOutput(window: foundation.HWND) void {
    const active_session = session orelse return;
    var batch = active_session.drainOutput();
    defer batch.deinit();

    var changed = false;
    for (batch.chunks.items) |chunk| {
        model.write(chunk) catch {
            std.log.err("failed to apply ConPTY output to the terminal model", .{});
            if (active_mode == .integration) _ = user32.DestroyWindow(window);
            return;
        };
        changed = true;
    }

    if (changed) _ = user32.InvalidateRect(window, null, 0);

    if (batch.failure) |failure| {
        switch (failure) {
            .out_of_memory => std.log.err(
                "ConPTY output reader ran out of memory",
                .{},
            ),
            .read_file => |code| std.log.err(
                "ReadFile for ConPTY output failed with Win32 error {d}",
                .{code},
            ),
            .post_message => |code| std.log.err(
                "posting ConPTY output notification failed with Win32 error {d}",
                .{code},
            ),
        }
    }

    if (active_mode == .integration and batch.finished) {
        integration_succeeded = batch.failure == null and
            terminalContains(integration_marker);
        _ = user32.DestroyWindow(window);
    }
}

fn terminalContains(needle: []const u8) bool {
    for (0..model.rows()) |row| {
        for (0..model.columns()) |start| {
            if (start + needle.len > model.columns()) break;
            for (needle, start..) |expected, column| {
                const cell = model.cell(row, column) orelse break;
                if (cell.spacer or cell.codepoint != expected) break;
            } else return true;
        }
    }
    return false;
}
