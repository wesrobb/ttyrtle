const std = @import("std");
const win32 = @import("win32");
const conpty = @import("conpty.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const render_commands = @import("render_commands.zig");
const terminal = @import("terminal.zig");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const memory = win32.system.memory;
const ole = win32.system.ole;
const wm = win32.ui.windows_and_messaging;
const gdi32 = win32.gdi32;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ttyrtle");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("ttyrtle");
const terminal_font_name = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");

pub const Mode = enum {
    normal,
    smoke,
    integration,
    integration_input,
    integration_resize,
    integration_host_close,
};

var model: terminal.TerminalModel = undefined;
var model_initialized = false;
var active_mode: Mode = .normal;
var paint_completed = false;
var integration_succeeded = false;
var integration_resize_requested = false;
var integration_resize_target: geometry.Dimensions = .{ .columns = 1, .rows = 1 };
var output_finished = false;
var session: ?*conpty.Session = null;
var input_translator: input.Translator = .{};
var terminal_metrics: geometry.Metrics = .forDpi(geometry.base_dpi);
var selection_dragging = false;
var selection_anchor: ?terminal.Cursor = null;
var selection_head: ?terminal.Cursor = null;
var pressed_mouse_button: ?input.MouseButton = null;
var back_buffer: ?BackBuffer = null;
var render_cache: render_commands.RenderCache = undefined;
var render_cache_initialized = false;

const BackBuffer = struct {
    dc: gdi.CreatedHDC,
    bitmap: gdi.HBITMAP,
    previous_bitmap: gdi.HGDIOBJ,
    width: i32,
    height: i32,

    fn deinit(self: *BackBuffer) void {
        _ = gdi32.SelectObject(self.dc, self.previous_bitmap);
        _ = gdi32.DeleteObject(self.bitmap);
        _ = gdi32.DeleteDC(self.dc);
        self.* = undefined;
    }
};

const integration_marker = "CONPTY_STEP_1_OK";
const integration_command =
    "cmd.exe /d /q /s /c \"echo \x1b[38;2;12;34;56m" ++
    integration_marker ++ "\x1b[0m > CON & ping -n 2 127.0.0.1 >nul\"";
const integration_input_text = "\xc3\xa9";
const integration_input_marker = "CONPTY_STEP_2_OK";
const integration_input_command =
    "cmd.exe /d /q /v:on /c " ++
    "\"set /p value=& echo " ++ integration_input_marker ++ " >CON\"";
const integration_resize_ready = "CONPTY_STEP_3_RESIZE_READY";
const integration_resize_marker = "CONPTY_STEP_3_RESIZE_OK";
const integration_host_close_command =
    "cmd.exe /d /q /c " ++
    "\"for /L %i in (1,1,200) do @echo shutdown-output-%i >CON " ++
    "& ping -n 30 127.0.0.1 >nul\"";

pub fn run(mode: Mode) !void {
    const allocator = std.heap.smp_allocator;
    active_mode = mode;
    paint_completed = false;
    integration_succeeded = false;
    integration_resize_requested = false;
    integration_resize_target = .{ .columns = 1, .rows = 1 };
    output_finished = false;
    session = null;
    input_translator = .{};
    terminal_metrics = .forDpi(geometry.base_dpi);
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    pressed_mouse_button = null;
    back_buffer = null;
    defer deinitBackBuffer();
    render_cache = .init(allocator);
    render_cache_initialized = true;
    defer {
        render_cache.deinit();
        render_cache_initialized = false;
    }

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
    const cursor_timer = user32.SetTimer(window, 1, 500, null);
    defer {
        if (cursor_timer != 0) _ = user32.KillTimer(window, cursor_timer);
    }

    terminal_metrics = .forDpi(user32.GetDpiForWindow(window));
    try resizeForClient(window);

    var integration_resize_command: ?[]u8 = null;
    defer if (integration_resize_command) |command| allocator.free(command);
    if (mode == .integration_resize) {
        integration_resize_target = .{
            .columns = model.columns() +| 7,
            .rows = model.rows() +| 3,
        };
        const script = try std.fmt.allocPrint(
            allocator,
            "$ProgressPreference = 'SilentlyContinue'; " ++
                "& cmd.exe /d /q /c \"echo " ++ integration_resize_ready ++
                " > CON\"; $deadline = [DateTime]::UtcNow.AddSeconds(10); " ++
                "$columns = '(?<!\\d){d}(?!\\d)'; " ++
                "$rows = '(?<!\\d){d}(?!\\d)'; $matched = $false; " ++
                "do {{ $status = (& mode.com con | Out-String); " ++
                "if ($status -match $columns -and $status -match $rows) " ++
                "{{ $matched = $true; break }}; Start-Sleep -Milliseconds 25 }} " ++
                "while ([DateTime]::UtcNow -lt $deadline); " ++
                "if ($matched) " ++
                "{{ & cmd.exe /d /q /c \"echo " ++ integration_resize_marker ++
                " > CON\" }} else {{ & cmd.exe /d /q /c " ++
                "\"echo CONPTY_STEP_3_RESIZE_MISMATCH > CON\"; exit 1 }}",
            .{
                integration_resize_target.columns,
                integration_resize_target.rows,
            },
        );
        defer allocator.free(script);
        integration_resize_command = try encodedPowerShellCommand(allocator, script);
    }

    if (mode != .smoke) {
        session = try conpty.Session.create(
            allocator,
            window,
            .{ .columns = model.columns(), .rows = model.rows() },
            switch (mode) {
                .integration => integration_command,
                .integration_input => integration_input_command,
                .integration_resize => integration_resize_command.?,
                .integration_host_close => integration_host_close_command,
                else => null,
            },
        );
        model.setReplySink(.{
            .context = session.?,
            .write = queueTerminalReply,
        });
        if (mode == .integration_input) try queueIntegrationInput();
    }
    defer if (session) |active_session| {
        model.setReplySink(null);
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
            model.markFullDamage();
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
            invalidateRenderDamage(window);
            return 0;
        },
        wm.WM_TIMER => {
            if (wparam == 1) {
                model.toggleCursorBlink();
                invalidateRenderDamage(window);
            }
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
        wm.WM_SETFOCUS => {
            queueFocus(.gained);
            return 0;
        },
        wm.WM_KILLFOCUS => {
            queueFocus(.lost);
            return 0;
        },
        wm.WM_PASTE => {
            pasteClipboard(window);
            return 0;
        },
        wm.WM_LBUTTONDOWN,
        wm.WM_MBUTTONDOWN,
        wm.WM_RBUTTONDOWN,
        wm.WM_LBUTTONUP,
        wm.WM_MBUTTONUP,
        wm.WM_RBUTTONUP,
        wm.WM_MOUSEMOVE,
        wm.WM_MOUSEWHEEL,
        => {
            handleMouseMessage(window, message, wparam, lparam);
            return 0;
        },
        wm.WM_CLOSE => {
            if (session) |active_session| {
                model.setReplySink(null);
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
    if (is_down and currentModifiers().ctrl and currentModifiers().shift) {
        switch (wparam) {
            'V' => {
                pasteClipboard(null);
                return;
            },
            'C' => {
                copySelection(null);
                return;
            },
            else => {},
        }
    }
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

const MouseButton = input.MouseButton;

fn queueFocus(event: input.FocusEvent) void {
    if (active_mode == .smoke or session == null) return;
    const encoded = input.encodeFocusAlloc(
        std.heap.smp_allocator,
        event,
        &model.core,
    ) catch return;
    queueOwnedInput(encoded);
}

fn queueOwnedInput(encoded: []u8) void {
    if (encoded.len == 0) {
        std.heap.smp_allocator.free(encoded);
        return;
    }
    const active_session = session orelse {
        std.heap.smp_allocator.free(encoded);
        return;
    };
    active_session.queueInputOwned(encoded) catch {
        std.heap.smp_allocator.free(encoded);
    };
}

fn handleMouseMessage(
    window: foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
) void {
    const local_selection = model.core.flags.mouse_event == .none or
        currentModifiers().shift;
    var point = messagePoint(lparam);
    if (message == wm.WM_MOUSEWHEEL and
        user32.ScreenToClient(window, &point) == 0) return;
    const cell = pointToCell(point);

    if (local_selection) {
        switch (message) {
            wm.WM_LBUTTONDOWN => {
                const clamped_cell = clampSelectionCell(cell);
                model.startSelection(clamped_cell.row, clamped_cell.column);
                selection_anchor = clamped_cell;
                selection_head = clamped_cell;
                selection_dragging = true;
                _ = user32.SetCapture(window);
                invalidateRenderDamage(window);
            },
            wm.WM_MOUSEMOVE => if (selection_dragging) {
                const clamped_cell = clampSelectionCell(cell);
                const previous = selection_head orelse clamped_cell;
                if (sameCell(previous, clamped_cell)) return;
                model.updateSelection(clamped_cell.row, clamped_cell.column);
                selection_head = clamped_cell;
                invalidateRenderDamage(window);
            },
            wm.WM_LBUTTONUP => if (selection_dragging) {
                const clamped_cell = clampSelectionCell(cell);
                const previous = selection_head orelse clamped_cell;
                if (!sameCell(previous, clamped_cell)) {
                    model.updateSelection(clamped_cell.row, clamped_cell.column);
                    selection_head = clamped_cell;
                    invalidateRenderDamage(window);
                }
                selection_dragging = false;
                _ = user32.ReleaseCapture();
            },
            else => {},
        }
        return;
    }

    const action: input.MouseAction = switch (message) {
        wm.WM_LBUTTONDOWN,
        wm.WM_MBUTTONDOWN,
        wm.WM_RBUTTONDOWN,
        wm.WM_MOUSEWHEEL,
        => .press,
        wm.WM_LBUTTONUP, wm.WM_MBUTTONUP, wm.WM_RBUTTONUP => .release,
        else => .motion,
    };
    const button: ?MouseButton = switch (message) {
        wm.WM_LBUTTONDOWN, wm.WM_LBUTTONUP => .left,
        wm.WM_MBUTTONDOWN, wm.WM_MBUTTONUP => .middle,
        wm.WM_RBUTTONDOWN, wm.WM_RBUTTONUP => .right,
        wm.WM_MOUSEWHEEL => if (signedHighWord(wparam) > 0) .four else .five,
        else => pressed_mouse_button,
    };
    if (action == .press and message != wm.WM_MOUSEWHEEL)
        pressed_mouse_button = button;
    if (action == .release) pressed_mouse_button = null;

    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0) return;
    const encoded = input.encodeMouseAlloc(
        std.heap.smp_allocator,
        .{
            .action = action,
            .button = button,
            .mods = currentModifiers(),
            .pos = .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            },
        },
        &model.core,
        @intCast(@max(client.right, 0)),
        @intCast(@max(client.bottom, 0)),
        terminal_metrics.cell_width,
        terminal_metrics.cell_height,
        terminal_metrics.margin_x,
        terminal_metrics.margin_y,
        pressed_mouse_button != null,
    ) catch return;
    queueOwnedInput(encoded);
}

fn messagePoint(lparam: isize) foundation.POINT {
    const bits: usize = @bitCast(lparam);
    return .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
}

fn signedHighWord(value: usize) i16 {
    return @bitCast(@as(u16, @truncate(value >> 16)));
}

fn pointToCell(point: foundation.POINT) terminal.Cursor {
    const x = @max(point.x - @as(i32, @intCast(terminal_metrics.margin_x)), 0);
    const y = @max(point.y - @as(i32, @intCast(terminal_metrics.margin_y)), 0);
    return .{
        .row = @intCast(@divTrunc(y, @as(i32, @intCast(terminal_metrics.cell_height)))),
        .column = @intCast(@divTrunc(x, @as(i32, @intCast(terminal_metrics.cell_width)))),
        .style = .block,
        .color = .{ .red = 0, .green = 0, .blue = 0 },
        .visible = false,
        .blinking = false,
    };
}

fn clampSelectionCell(cell: terminal.Cursor) terminal.Cursor {
    var clamped = cell;
    clamped.row = @min(clamped.row, model.rows() -| 1);
    clamped.column = @min(clamped.column, model.columns() -| 1);
    return clamped;
}

fn sameCell(left: terminal.Cursor, right: terminal.Cursor) bool {
    return left.row == right.row and left.column == right.column;
}

fn invalidateRenderDamage(window: foundation.HWND) void {
    switch (model.damage()) {
        .none => {},
        .full => _ = user32.InvalidateRect(window, null, 0),
        .partial => |rows| for (rows) |row| {
            const cell_width: i32 = @intCast(terminal_metrics.cell_width);
            const cell_height: i32 = @intCast(terminal_metrics.cell_height);
            const margin_x: i32 = @intCast(terminal_metrics.margin_x);
            const margin_y: i32 = @intCast(terminal_metrics.margin_y);
            const dirty: foundation.RECT = .{
                .left = margin_x,
                .top = margin_y + @as(i32, @intCast(row)) * cell_height,
                .right = margin_x +
                    @as(i32, @intCast(model.columns())) * cell_width,
                .bottom = margin_y + @as(i32, @intCast(row + 1)) * cell_height,
            };
            _ = user32.InvalidateRect(window, &dirty, 0);
        },
    }
}

fn pasteClipboard(window: ?foundation.HWND) void {
    if (session == null or user32.OpenClipboard(window) == 0) return;
    defer _ = user32.CloseClipboard();
    const handle = user32.GetClipboardData(@intFromEnum(ole.CF_UNICODETEXT)) orelse
        return;
    const locked = kernel32.GlobalLock(@intCast(@intFromPtr(handle))) orelse return;
    defer _ = kernel32.GlobalUnlock(@intCast(@intFromPtr(handle)));
    const wide: [*:0]const u16 = @ptrCast(@alignCast(locked));
    const utf8 = std.unicode.utf16LeToUtf8Alloc(
        std.heap.smp_allocator,
        std.mem.span(wide),
    ) catch return;
    defer std.heap.smp_allocator.free(utf8);
    const encoded = input.encodePasteAlloc(
        std.heap.smp_allocator,
        utf8,
        &model.core,
    ) catch return;
    queueOwnedInput(encoded);
}

fn copySelection(window: ?foundation.HWND) void {
    const utf8 = model.selectionTextAlloc(std.heap.smp_allocator) catch return;
    defer std.heap.smp_allocator.free(utf8);
    if (utf8.len == 0) return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(
        std.heap.smp_allocator,
        utf8,
    ) catch return;
    defer std.heap.smp_allocator.free(wide);

    if (user32.OpenClipboard(window) == 0) return;
    defer _ = user32.CloseClipboard();
    if (user32.EmptyClipboard() == 0) return;
    const byte_length = (wide.len + 1) * @sizeOf(u16);
    const memory_handle = kernel32.GlobalAlloc(memory.GMEM_MOVEABLE, byte_length);
    if (memory_handle == 0) return;
    const locked = kernel32.GlobalLock(memory_handle) orelse {
        _ = kernel32.GlobalFree(memory_handle);
        return;
    };
    const destination = @as([*]u8, @ptrCast(locked))[0..byte_length];
    @memcpy(destination[0 .. wide.len * @sizeOf(u16)], std.mem.sliceAsBytes(wide));
    @memset(destination[wide.len * @sizeOf(u16) ..], 0);
    _ = kernel32.GlobalUnlock(memory_handle);
    if (user32.SetClipboardData(
        @intFromEnum(ole.CF_UNICODETEXT),
        @ptrFromInt(@as(usize, @intCast(memory_handle))),
    ) == null) _ = kernel32.GlobalFree(memory_handle);
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

fn queueTerminalReply(context: *anyopaque, bytes: []const u8) !void {
    const active_session: *conpty.Session = @ptrCast(@alignCast(context));
    const owned = try std.heap.smp_allocator.dupe(u8, bytes);
    errdefer std.heap.smp_allocator.free(owned);
    try active_session.queueInputOwned(owned);
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
    if (!model_initialized or !render_cache_initialized) return false;

    var paint_state: gdi.PAINTSTRUCT = undefined;
    const dc = user32.BeginPaint(window, &paint_state) orelse return false;
    defer _ = user32.EndPaint(window, &paint_state);

    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0) return false;
    const buffer = ensureBackBuffer(
        dc,
        client.right - client.left,
        client.bottom - client.top,
    ) orelse return false;
    const target_dc = buffer.dc;
    const saved_dc = gdi32.SaveDC(target_dc);
    if (saved_dc == 0) return false;
    defer _ = gdi32.RestoreDC(target_dc, saved_dc);
    _ = gdi32.IntersectClipRect(
        target_dc,
        paint_state.rcPaint.left,
        paint_state.rcPaint.top,
        paint_state.rcPaint.right,
        paint_state.rcPaint.bottom,
    );

    render_cache.update(
        &model,
        terminal_metrics,
        model.damage(),
    ) catch return false;
    model.acknowledgeDamage();
    const background = gdi32.CreateSolidBrush(toColorRef(render_cache.background)) orelse
        return false;
    defer _ = gdi32.DeleteObject(background);
    const font = gdi32.CreateFontW(
        @intCast(terminal_metrics.cell_height),
        @intCast(terminal_metrics.cell_width),
        0,
        0,
        @intFromEnum(gdi.FW_NORMAL),
        0,
        0,
        0,
        @intFromEnum(gdi.DEFAULT_CHARSET),
        @intFromEnum(gdi.OUT_DEFAULT_PRECIS),
        @as(u8, @bitCast(gdi.CLIP_DEFAULT_PRECIS)),
        @intFromEnum(gdi.CLEARTYPE_QUALITY),
        @intFromEnum(gdi.FIXED_PITCH) | @intFromEnum(gdi.FF_MODERN),
        terminal_font_name,
    ) orelse return false;
    defer _ = gdi32.DeleteObject(font);
    const previous_font = gdi32.SelectObject(target_dc, font) orelse return false;
    defer _ = gdi32.SelectObject(target_dc, previous_font);

    _ = user32.FillRect(target_dc, &paint_state.rcPaint, background);
    _ = gdi32.SetBkMode(target_dc, gdi.TRANSPARENT);

    const first_row = paintFirstRow(paint_state.rcPaint);
    const last_row = paintLastRow(paint_state.rcPaint);
    if (first_row < render_cache.rows.items.len) {
        for (render_cache.rows.items[first_row..@min(
            last_row +| 1,
            render_cache.rows.items.len,
        )]) |*row| {
            for (row.rectangles.items) |rectangle| {
                const brush = gdi32.CreateSolidBrush(toColorRef(rectangle.color)) orelse
                    return false;
                defer _ = gdi32.DeleteObject(brush);
                const bounds: foundation.RECT = .{
                    .left = rectangle.left,
                    .top = rectangle.top,
                    .right = rectangle.right,
                    .bottom = rectangle.bottom,
                };
                _ = if (rectangle.outline)
                    user32.FrameRect(target_dc, &bounds, brush)
                else
                    user32.FillRect(target_dc, &bounds, brush);
            }

            for (row.text_runs.items) |text_run| {
                _ = gdi32.SetTextColor(target_dc, toColorRef(text_run.color));
                if (gdi32.TextOutW(
                    target_dc,
                    text_run.x,
                    text_run.y,
                    @ptrCast(row.utf16.items[text_run.text_start..].ptr),
                    @intCast(text_run.text_len),
                ) == 0) return false;
            }
        }
    }

    const width = paint_state.rcPaint.right - paint_state.rcPaint.left;
    const height = paint_state.rcPaint.bottom - paint_state.rcPaint.top;
    const copied = gdi32.BitBlt(
        dc,
        paint_state.rcPaint.left,
        paint_state.rcPaint.top,
        width,
        height,
        target_dc,
        paint_state.rcPaint.left,
        paint_state.rcPaint.top,
        gdi.SRCCOPY,
    ) != 0;
    return copied;
}

fn paintFirstRow(rect: foundation.RECT) usize {
    const margin_y: i32 = @intCast(terminal_metrics.margin_y);
    const cell_height: i32 = @intCast(terminal_metrics.cell_height);
    return @intCast(@divTrunc(@max(rect.top - margin_y, 0), cell_height));
}

fn paintLastRow(rect: foundation.RECT) usize {
    const margin_y: i32 = @intCast(terminal_metrics.margin_y);
    const cell_height: i32 = @intCast(terminal_metrics.cell_height);
    return @intCast(@divTrunc(@max(rect.bottom - 1 - margin_y, 0), cell_height));
}

fn ensureBackBuffer(dc: gdi.HDC, width: i32, height: i32) ?*BackBuffer {
    if (width <= 0 or height <= 0) return null;
    if (back_buffer) |*buffer| {
        if (buffer.width >= width and buffer.height >= height) return buffer;
        buffer.deinit();
        back_buffer = null;
    }

    const memory_dc = gdi32.CreateCompatibleDC(dc);
    if (@intFromPtr(memory_dc) == 0) return null;
    const bitmap = gdi32.CreateCompatibleBitmap(dc, width, height) orelse {
        _ = gdi32.DeleteDC(memory_dc);
        return null;
    };
    const previous_bitmap = gdi32.SelectObject(memory_dc, bitmap) orelse {
        _ = gdi32.DeleteObject(bitmap);
        _ = gdi32.DeleteDC(memory_dc);
        return null;
    };
    back_buffer = .{
        .dc = memory_dc,
        .bitmap = bitmap,
        .previous_bitmap = previous_bitmap,
        .width = width,
        .height = height,
    };
    return &back_buffer.?;
}

fn deinitBackBuffer() void {
    if (back_buffer) |*buffer| buffer.deinit();
    back_buffer = null;
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
    invalidateRenderDamage(window);
}

fn toColorRef(color: terminal.Rgb) win32.zig.COLORREF {
    return .rgb(color.red, color.green, color.blue);
}

fn handleConptyOutput(window: foundation.HWND) void {
    const active_session = session orelse return;
    var batch = active_session.drainOutput();
    defer batch.deinit();

    const changed = batch.chunks.items.len != 0;
    if (changed) {
        model.writeBatch(batch.chunks.items) catch {
            std.log.err("failed to apply ConPTY output to the terminal model", .{});
            if (isIntegrationMode(active_mode)) _ = user32.DestroyWindow(window);
            return;
        };
        model.resetCursorBlink();
    }

    applyTerminalEffects(window);
    if (changed) invalidateRenderDamage(window);

    if (active_mode == .integration_resize and
        !integration_resize_requested and
        terminalContains(integration_resize_ready))
    {
        integration_resize_requested = true;
        requestIntegrationResize(window) catch {
            std.log.err("failed to request integration resize", .{});
            _ = user32.DestroyWindow(window);
            return;
        };
    }

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
        const marker = switch (active_mode) {
            .integration_input => integration_input_marker,
            .integration_resize => integration_resize_marker,
            else => integration_marker,
        };
        integration_succeeded = batch.failure == null and
            terminalContains(marker);
        _ = user32.DestroyWindow(window);
    } else if (batch.finished) {
        output_finished = true;
        if (active_session.childExitCode() != null)
            _ = user32.DestroyWindow(window);
    }
}

fn applyTerminalEffects(window: foundation.HWND) void {
    if (model.takeTitleChanged()) {
        const title = model.core.getTitle() orelse "";
        const wide = std.unicode.utf8ToUtf16LeAllocZ(
            std.heap.smp_allocator,
            title,
        ) catch null;
        if (wide) |value| {
            defer std.heap.smp_allocator.free(value);
            _ = user32.SetWindowTextW(window, value);
        }
    }

    if (model.takeBellCount() > 0) _ = user32.MessageBeep(.{});
}

fn isIntegrationMode(mode: Mode) bool {
    return switch (mode) {
        .integration,
        .integration_input,
        .integration_resize,
        => true,
        else => false,
    };
}

fn requestIntegrationResize(window: foundation.HWND) !void {
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0)
        return error.GetClientRectFailed;
    var outer: foundation.RECT = undefined;
    if (user32.GetWindowRect(window, &outer) == 0)
        return error.GetWindowRectFailed;

    const client_width = client.right - client.left;
    const client_height = client.bottom - client.top;
    const outer_width = outer.right - outer.left;
    const outer_height = outer.bottom - outer.top;
    const desired_client_width: i32 = @intCast(
        @as(u32, integration_resize_target.columns) * terminal_metrics.cell_width +
            terminal_metrics.margin_x * 2,
    );
    const desired_client_height: i32 = @intCast(
        @as(u32, integration_resize_target.rows) * terminal_metrics.cell_height +
            terminal_metrics.margin_y * 2,
    );

    if (user32.SetWindowPos(
        window,
        null,
        0,
        0,
        outer_width + desired_client_width - client_width,
        outer_height + desired_client_height - client_height,
        .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) return error.SetWindowPosFailed;

    if (model.columns() != integration_resize_target.columns or
        model.rows() != integration_resize_target.rows)
        return error.ResizeDimensionsMismatch;
}

fn encodedPowerShellCommand(
    allocator: std.mem.Allocator,
    script: []const u8,
) ![]u8 {
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, script);
    defer allocator.free(utf16);
    const bytes = std.mem.sliceAsBytes(utf16);
    const encoded_length = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_length);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return std.fmt.allocPrint(
        allocator,
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {s}",
        .{encoded},
    );
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
