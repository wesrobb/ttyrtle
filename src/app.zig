const std = @import("std");
const win32 = @import("win32");
const conpty = @import("conpty.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const render_commands = @import("render_commands.zig");
const terminal = @import("terminal.zig");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const wm = win32.ui.windows_and_messaging;
const gdi32 = win32.gdi32;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ttyrtle");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("ttyrtle");

pub const Mode = enum {
    normal,
    smoke,
    integration,
    integration_input,
    integration_host_close,
};

var model: terminal.TerminalModel = undefined;
var model_initialized = false;
var active_mode: Mode = .normal;
var paint_completed = false;
var integration_succeeded = false;
var output_finished = false;
var session: ?*conpty.Session = null;
var input_translator: input.Translator = .{};
var terminal_metrics: geometry.Metrics = .forDpi(geometry.base_dpi);

const integration_marker = "CONPTY_STEP_1_OK";
const integration_command =
    "cmd.exe /d /q /s /c \"echo \x1b[38;2;12;34;56m" ++
    integration_marker ++ "\x1b[0m > CON & ping -n 2 127.0.0.1 >nul\"";
const integration_input_text = "\xc3\xa9";
const integration_input_marker = "CONPTY_STEP_2_OK";
const integration_input_command =
    "cmd.exe /d /q /v:on /c " ++
    "\"set /p value=& echo " ++ integration_input_marker ++ " >CON\"";
const integration_host_close_command =
    "cmd.exe /d /q /c " ++
    "\"for /L %i in (1,1,200) do @echo shutdown-output-%i >CON " ++
    "& ping -n 30 127.0.0.1 >nul\"";

pub fn run(mode: Mode) !void {
    const allocator = std.heap.smp_allocator;
    active_mode = mode;
    paint_completed = false;
    integration_succeeded = false;
    output_finished = false;
    session = null;
    input_translator = .{};
    terminal_metrics = .forDpi(geometry.base_dpi);

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

    terminal_metrics = .forDpi(user32.GetDpiForWindow(window));
    try resizeForClient(window);

    if (mode != .smoke) {
        session = try conpty.Session.create(
            allocator,
            window,
            .{ .columns = model.columns(), .rows = model.rows() },
            switch (mode) {
                .integration => integration_command,
                .integration_input => integration_input_command,
                .integration_host_close => integration_host_close_command,
                else => null,
            },
        );
        if (mode == .integration_input) try queueIntegrationInput();
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
    if (mode == .integration_host_close)
        _ = user32.PostMessageW(window, wm.WM_CLOSE, 0, 0);

    var message: wm.MSG = undefined;
    while (true) {
        const result = user32.GetMessageW(&message, null, 0, 0);
        if (result == 0) break;
        if (result < 0) return error.GetMessageFailed;
        _ = user32.TranslateMessage(&message);
        _ = user32.DispatchMessageW(&message);
    }

    if (mode == .smoke and !paint_completed) return error.SmokePaintFailed;
    if (isIntegrationMode(mode) and !integration_succeeded)
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
        wm.WM_SIZE => {
            if (wparam != wm.SIZE_MINIMIZED) {
                resizeForClient(window) catch {
                    std.log.err("failed to resize terminal for client area", .{});
                };
            }
            return 0;
        },
        wm.WM_DPICHANGED => {
            terminal_metrics = .forDpi(@truncate(wparam));
            const suggested: *const foundation.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = user32.SetWindowPos(
                window,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                wm.SWP_NOZORDER,
            );
            resizeForClient(window) catch {
                std.log.err("failed to resize terminal after DPI change", .{});
            };
            return 0;
        },
        conpty.output_message => {
            handleConptyOutput(window);
            return 0;
        },
        conpty.child_exit_message => {
            if (session) |active_session| {
                _ = active_session.beginClosing();
                if (active_session.childExitCode()) |code|
                    std.log.info("ConPTY child exited with code {d}", .{code});
                if (output_finished) _ = user32.DestroyWindow(window);
            }
            return 0;
        },
        conpty.input_failure_message => {
            if (session) |active_session| {
                if (active_session.inputFailureCode()) |code|
                    std.log.err(
                        "WriteFile for ConPTY input failed with Win32 error {d}",
                        .{code},
                    );
            }
            return 0;
        },
        wm.WM_KEYDOWN, wm.WM_SYSKEYDOWN, wm.WM_KEYUP, wm.WM_SYSKEYUP => {
            handleKeyMessage(message, wparam, lparam);
            return 0;
        },
        wm.WM_CHAR, wm.WM_SYSCHAR => {
            handleCharacterMessage(@truncate(wparam));
            return 0;
        },
        wm.WM_DEADCHAR, wm.WM_SYSDEADCHAR => {
            input_translator.deadCharacter();
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

fn handleKeyMessage(message: u32, wparam: usize, lparam: isize) void {
    if (active_mode == .smoke or session == null) return;

    const is_down = message == wm.WM_KEYDOWN or message == wm.WM_SYSKEYDOWN;
    const bits: usize = @bitCast(lparam);
    const action: input.Action = if (!is_down)
        .release
    else if ((bits & (@as(usize, 1) << 30)) != 0)
        .repeat
    else
        .press;
    const event = input_translator.keyEvent(
        @truncate(wparam),
        @truncate((bits >> 16) & 0xff),
        action,
        currentModifiers(),
        (bits & (@as(usize, 1) << 24)) != 0,
        @truncate(bits & 0xffff),
    ) orelse return;
    encodeAndQueueInput(event);
}

fn handleCharacterMessage(code_unit: u16) void {
    if (active_mode == .smoke or session == null) return;
    const event = input_translator.characterEvent(
        code_unit,
        currentModifiers(),
    ) orelse return;
    encodeAndQueueInput(event);
}

fn queueIntegrationInput() !void {
    try queueEncodedInput(.{
        .key = .unidentified,
        .action = .press,
        .utf8 = integration_input_text,
    });
    try queueEncodedInput(.{
        .key = .enter,
        .action = .press,
    });
}

fn encodeAndQueueInput(event: input.NormalizedKey) void {
    queueEncodedInput(event) catch {
        std.log.err("failed to encode or queue ConPTY input", .{});
    };
}

fn queueEncodedInput(event: input.NormalizedKey) !void {
    const active_session = session orelse return;
    const encoded = input.encodeAlloc(
        std.heap.smp_allocator,
        event,
        &model.core,
    ) catch return error.InputEncodingFailed;
    if (encoded.len == 0) {
        std.heap.smp_allocator.free(encoded);
        return;
    }
    errdefer std.heap.smp_allocator.free(encoded);
    try active_session.queueInputOwned(encoded);
}

fn currentModifiers() input.Mods {
    return .{
        .shift = keyIsDown(0x10),
        .ctrl = keyIsDown(0x11),
        .alt = keyIsDown(0x12),
        .super = keyIsDown(0x5b) or keyIsDown(0x5c),
        .caps_lock = keyIsToggled(0x14),
        .num_lock = keyIsToggled(0x90),
    };
}

fn keyIsDown(virtual_key: i32) bool {
    return (@as(u16, @bitCast(user32.GetKeyState(virtual_key))) & 0x8000) != 0;
}

fn keyIsToggled(virtual_key: i32) bool {
    return (@as(u16, @bitCast(user32.GetKeyState(virtual_key))) & 1) != 0;
}

fn paint(window: foundation.HWND) bool {
    if (!model_initialized) return false;

    var paint_state: gdi.PAINTSTRUCT = undefined;
    const dc = user32.BeginPaint(window, &paint_state) orelse return false;
    defer _ = user32.EndPaint(window, &paint_state);

    var frame = render_commands.Frame.build(
        std.heap.smp_allocator,
        &model,
        terminal_metrics,
    ) catch
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

fn resizeForClient(window: foundation.HWND) !void {
    if (!model_initialized) return;

    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0)
        return error.GetClientRectFailed;
    const dimensions = terminal_metrics.dimensions(
        client.right - client.left,
        client.bottom - client.top,
    ) orelse return;
    if (dimensions.rows == model.rows() and dimensions.columns == model.columns())
        return;

    const old_dimensions: geometry.Dimensions = .{
        .columns = model.columns(),
        .rows = model.rows(),
    };
    try model.resize(
        dimensions.rows,
        dimensions.columns,
        terminal_metrics.cell_width,
        terminal_metrics.cell_height,
    );
    errdefer model.resize(
        old_dimensions.rows,
        old_dimensions.columns,
        terminal_metrics.cell_width,
        terminal_metrics.cell_height,
    ) catch {};

    if (session) |active_session| _ = try active_session.resize(dimensions);
    _ = user32.InvalidateRect(window, null, 0);
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
            if (isIntegrationMode(active_mode)) _ = user32.DestroyWindow(window);
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

    if (isIntegrationMode(active_mode) and batch.finished) {
        const marker = if (active_mode == .integration_input)
            integration_input_marker
        else
            integration_marker;
        integration_succeeded = batch.failure == null and
            terminalContains(marker);
        _ = user32.DestroyWindow(window);
    } else if (batch.finished) {
        output_finished = true;
        if (active_session.childExitCode() != null)
            _ = user32.DestroyWindow(window);
    }
}

fn isIntegrationMode(mode: Mode) bool {
    return mode == .integration or mode == .integration_input;
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
