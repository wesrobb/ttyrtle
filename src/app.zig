const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const conpty = @import("conpty.zig");
const frame_trace = @import("frame_trace.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const render_commands = @import("render_commands.zig");
const renderer = @import("renderer.zig");
const terminal = @import("terminal.zig");
const workspace = @import("workspace.zig");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const memory = win32.system.memory;
const ole = win32.system.ole;
const file_system = win32.storage.file_system;
const controls = win32.ui.controls;
const wm = win32.ui.windows_and_messaging;
const comctl32 = win32.comctl32;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Ttyrtle");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("ttyrtle");
const tab_control_class =
    std.unicode.utf8ToUtf16LeStringLiteral("SysTabControl32");
const edit_control_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
const trace_file_name =
    std.unicode.utf8ToUtf16LeStringLiteral("ttyrtle-frame-trace.log");
const tab_control_id = 100;
const tcn_selchange: u32 = @bitCast(@as(i32, -551));
const context_menu_new_tab = 1;
const context_menu_rename_tab = 2;
const context_menu_close_tab = 3;
const context_menu_new_tab_label = std.unicode.utf8ToUtf16LeStringLiteral("New Tab");
const context_menu_rename_tab_label = std.unicode.utf8ToUtf16LeStringLiteral("Rename");
const context_menu_close_tab_label = std.unicode.utf8ToUtf16LeStringLiteral("Close");

pub const Mode = enum {
    normal,
    smoke,
    smoke_gdi,
    smoke_phase5,
    smoke_tabs,
    smoke_shortcuts,
    smoke_rename,
    smoke_tab_interactions,
    integration,
    integration_input,
    integration_resize,
    integration_host_close,
};

var workspace_ids: workspace.IdSource = .{};
var workspace_state: workspace.Workspace = undefined;
var model: *terminal.TerminalModel = undefined;
var model_initialized = false;
var tab_control: ?foundation.HWND = null;
var app_window: ?foundation.HWND = null;
var active_mode: Mode = .normal;
var paint_completed = false;
var integration_succeeded = false;
var integration_resize_requested = false;
var integration_resize_target: geometry.Dimensions = .{ .columns = 1, .rows = 1 };
var input_translator: input.Translator = .{};
var shortcut_state: ShortcutState = .{};
var test_modifiers: ?input.Mods = null;
var test_context_menu_command: ?usize = null;
var rename_editor: ?RenameEditor = null;
var terminal_metrics: geometry.Metrics = .forDpi(geometry.base_dpi);
var selection_dragging = false;
var selection_anchor: ?terminal.Cursor = null;
var selection_head: ?terminal.Cursor = null;
var pressed_mouse_button: ?input.MouseButton = null;
var active_renderer: renderer.Renderer = .{};
var render_cache: render_commands.RenderCache = undefined;
var render_cache_initialized = false;
var output_trace: frame_trace.Counter = .{};
var paint_trace: frame_trace.Counter = .{};
var cache_trace: frame_trace.Counter = .{};

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
    tab_control = null;
    input_translator = .{};
    shortcut_state = .{};
    test_modifiers = null;
    test_context_menu_command = null;
    rename_editor = null;
    terminal_metrics = .forDpi(geometry.base_dpi);
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    pressed_mouse_button = null;
    active_renderer = .{};
    defer active_renderer.deinit();
    render_cache = .init(allocator);
    render_cache_initialized = true;
    output_trace = .{};
    paint_trace = .{};
    cache_trace = .{};
    defer {
        render_cache.deinit();
        render_cache_initialized = false;
    }

    workspace_ids = .{};
    workspace_state = .init(allocator, &workspace_ids);
    _ = try workspace_state.createTab(24, 80);
    if (mode == .smoke_tabs) _ = try workspace_state.createTab(24, 80);
    model = &workspace_state.activeSession().?.model;
    model_initialized = true;
    defer {
        model_initialized = false;
        workspace_state.deinit();
    }
    defer logDebugCounters();
    if (isSmokeMode(mode))
        try model.write("\x1b[38;2;126;231;135mHello from libghostty.\x1b[0m");

    const instance = kernel32.GetModuleHandleW(null) orelse
        return error.GetModuleHandleFailed;
    const common_controls: controls.INITCOMMONCONTROLSEX = .{
        .dwSize = @sizeOf(controls.INITCOMMONCONTROLSEX),
        .dwICC = controls.ICC_TAB_CLASSES,
    };
    if (comctl32.InitCommonControlsEx(&common_controls) == 0)
        return error.InitCommonControlsFailed;

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

    var main_window_style = wm.WS_OVERLAPPEDWINDOW;
    main_window_style.CLIPCHILDREN = 1;
    const window = user32.CreateWindowExW(
        .{},
        class_name,
        window_title,
        main_window_style,
        wm.CW_USEDEFAULT,
        wm.CW_USEDEFAULT,
        900,
        560,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    app_window = window;
    defer app_window = null;
    defer if (user32.IsWindow(window) != 0) {
        _ = user32.DestroyWindow(window);
    };
    tab_control = try createTabControl(instance, window);
    defer tab_control = null;
    if (comctl32.SetWindowSubclass(tab_control, tabControlProc, 1, 0) == 0)
        return error.SubclassTabControlFailed;
    try syncNativeTabs();
    if (mode != .smoke_gdi)
        active_renderer.initialize(window);
    const cursor_timer = user32.SetTimer(window, 1, 500, null);
    defer {
        if (cursor_timer != 0) _ = user32.KillTimer(window, cursor_timer);
    }

    terminal_metrics = active_renderer.metricsForDpi(user32.GetDpiForWindow(window));
    try resizeForClient(window);
    if (mode == .smoke_tabs) try verifyNativeTabControl(window);
    if (mode == .smoke_shortcuts) try verifyShortcutDispatch(window);
    if (mode == .smoke_rename) try verifyInlineRename(window);
    if (mode == .smoke_tab_interactions) try verifyTabInteractions(window);

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

    if (!isSmokeMode(mode)) {
        const process = try conpty.Session.create(
            allocator,
            window,
            @intFromEnum(workspace_state.activeSession().?.id),
            .{ .columns = model.columns(), .rows = model.rows() },
            switch (mode) {
                .integration => integration_command,
                .integration_input => integration_input_command,
                .integration_resize => integration_resize_command.?,
                .integration_host_close => integration_host_close_command,
                else => null,
            },
        );
        workspace_state.activeSession().?.attachProcess(.{
            .context = process,
            .destroy = destroyConptyProcess,
        }) catch |err| {
            process.destroy();
            return err;
        };
        model.setReplySink(.{
            .context = process,
            .write = queueTerminalReply,
        });
        if (mode == .integration_input) try queueIntegrationInput();
    }

    _ = user32.ShowWindow(
        window,
        if (mode == .normal) wm.SW_SHOWDEFAULT else wm.SW_HIDE,
    );
    if (mode == .smoke_phase5) {
        try runPhase5Smoke(window);
    } else if (isSmokeMode(mode)) {
        for (0..3) |_| _ = user32.SendMessageW(window, wm.WM_PAINT, 0, 0);
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

    if (isSmokeMode(mode) and !paint_completed) return error.SmokePaintFailed;
    if (isIntegrationMode(mode) and !integration_succeeded)
        return error.ConptyIntegrationFailed;
}

fn createTabControl(
    instance: foundation.HINSTANCE,
    window: foundation.HWND,
) !foundation.HWND {
    return user32.CreateWindowExW(
        .{},
        tab_control_class,
        null,
        .{
            .CHILD = 1,
            .VISIBLE = 1,
            .CLIPSIBLINGS = 1,
            .TABSTOP = 1,
        },
        0,
        0,
        0,
        0,
        window,
        @ptrFromInt(tab_control_id),
        instance,
        null,
    ) orelse error.CreateTabControlFailed;
}

const RenameEditor = struct {
    window: foundation.HWND,
    tab_id: workspace.TabId,
};

fn beginRenameTab(id: workspace.TabId) !void {
    if (rename_editor) |editor| {
        if (editor.tab_id == id) return;
        finishRename(true);
    }
    const control = tab_control orelse return error.TabControlUnavailable;
    const index = nativeIndexForTab(id) orelse return error.UnknownTab;
    var bounds: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, index, @bitCast(@intFromPtr(&bounds))) == 0)
        return error.GetTabItemRectFailed;
    const tab = workspace_state.tab(id) orelse return error.UnknownTab;
    const label = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, tab.effectiveLabel());
    defer std.heap.smp_allocator.free(label);
    const instance = kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    const editor = user32.CreateWindowExW(
        wm.WS_EX_CLIENTEDGE,
        edit_control_class,
        label,
        .{ .CHILD = 1, .VISIBLE = 1, .TABSTOP = 1 },
        bounds.left + 1,
        bounds.top + 1,
        @max(bounds.right - bounds.left - 2, 1),
        @max(bounds.bottom - bounds.top - 2, 1),
        control,
        null,
        instance,
        null,
    ) orelse return error.CreateRenameEditorFailed;
    rename_editor = .{ .window = editor, .tab_id = id };
    if (comctl32.SetWindowSubclass(editor, renameEditorProc, 1, 0) == 0) {
        rename_editor = null;
        _ = user32.DestroyWindow(editor);
        return error.SubclassRenameEditorFailed;
    }
    const tab_font = user32.SendMessageW(control, wm.WM_GETFONT, 0, 0);
    if (tab_font != 0) _ = user32.SendMessageW(editor, wm.WM_SETFONT, @bitCast(tab_font), 1);
    _ = user32.SendMessageW(
        editor,
        controls.EM_SETMARGINS,
        wm.EC_LEFTMARGIN | wm.EC_RIGHTMARGIN,
        (@as(isize, 3) << 16) | 3,
    );
    _ = user32.SetFocus(editor);
    _ = user32.SendMessageW(editor, controls.EM_SETSEL, 0, -1);
}

fn repositionRenameEditor() void {
    const editor = rename_editor orelse return;
    const control = tab_control orelse return cancelRename();
    const index = nativeIndexForTab(editor.tab_id) orelse return cancelRename();
    var bounds: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, index, @bitCast(@intFromPtr(&bounds))) == 0)
        return cancelRename();
    _ = user32.SetWindowPos(
        editor.window,
        null,
        bounds.left + 1,
        bounds.top + 1,
        @max(bounds.right - bounds.left - 2, 1),
        @max(bounds.bottom - bounds.top - 2, 1),
        .{ .NOZORDER = 1, .NOACTIVATE = 1 },
    );
}

fn finishRename(commit: bool) void {
    const editor = rename_editor orelse return;
    rename_editor = null;
    defer _ = user32.DestroyWindow(editor.window);
    if (commit) {
        const length = user32.GetWindowTextLengthW(editor.window);
        if (length < 0) return;
        const wide = std.heap.smp_allocator.allocSentinel(u16, @intCast(length), 0) catch return;
        defer std.heap.smp_allocator.free(wide);
        _ = user32.GetWindowTextW(editor.window, wide, length + 1);
        const utf8 = std.unicode.utf16LeToUtf8Alloc(
            std.heap.smp_allocator,
            wide[0..@intCast(length)],
        ) catch return;
        defer std.heap.smp_allocator.free(utf8);
        const title = std.mem.trim(u8, utf8, " \t\r\n");
        _ = workspace_state.renameTab(editor.tab_id, if (title.len == 0) null else title) catch return;
        updateNativeTabLabel(editor.tab_id) catch {};
        if (workspace_state.active_tab_id == editor.tab_id) if (app_window) |window|
            updateWindowCaption(window);
    }
    if (app_window) |window| _ = user32.SetFocus(window);
}

fn cancelRename() void {
    finishRename(false);
}

fn renameEditorProc(
    control: ?foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
    _: usize,
    _: usize,
) callconv(.winapi) isize {
    switch (message) {
        wm.WM_KEYDOWN => switch (wparam) {
            0x0d => {
                finishRename(true);
                return 0;
            },
            0x1b => {
                cancelRename();
                return 0;
            },
            else => {},
        },
        wm.WM_KILLFOCUS => {
            finishRename(true);
            return 0;
        },
        wm.WM_NCDESTROY => {
            if (rename_editor) |editor| {
                if (editor.window == control) rename_editor = null;
            }
        },
        else => {},
    }
    return comctl32.DefSubclassProc(control, message, wparam, lparam);
}

fn tabControlProc(
    control: ?foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
    _: usize,
    _: usize,
) callconv(.winapi) isize {
    if (message == wm.WM_CONTEXTMENU) {
        const hwnd = control orelse return 0;
        if (lparam == -1) {
            showActiveTabContextMenu() catch |err|
                std.log.err("failed to show tab context menu: {}", .{err});
            return 0;
        }
        var point = messagePoint(lparam);
        if (user32.ScreenToClient(hwnd, &point) == 0) return 0;
        var hit: controls.TCHITTESTINFO = .{
            .pt = point,
            .flags = controls.TCHT_NOWHERE,
        };
        const index = user32.SendMessageW(hwnd, controls.TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
        if (index >= 0) if (nativeTabIdAt(@intCast(index))) |id| {
            showTabContextMenu(id, messagePoint(lparam)) catch |err|
                std.log.err("failed to show tab context menu: {}", .{err});
        };
        return 0;
    }
    if (message == wm.WM_LBUTTONDBLCLK) {
        const hwnd = control orelse return 0;
        var hit: controls.TCHITTESTINFO = .{
            .pt = messagePoint(lparam),
            .flags = controls.TCHT_NOWHERE,
        };
        const index = user32.SendMessageW(hwnd, controls.TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
        if (index >= 0) if (nativeTabIdAt(@intCast(index))) |id| {
            beginRenameTab(id) catch |err| std.log.err("failed to begin tab rename: {}", .{err});
            return 0;
        };
    }
    if (message == wm.WM_MBUTTONDOWN) {
        const hwnd = control orelse return 0;
        var hit: controls.TCHITTESTINFO = .{
            .pt = messagePoint(lparam),
            .flags = controls.TCHT_NOWHERE,
        };
        const index = user32.SendMessageW(
            hwnd,
            controls.TCM_HITTEST,
            0,
            @bitCast(@intFromPtr(&hit)),
        );
        if (index >= 0) if (nativeTabIdAt(@intCast(index))) |id| {
            if (app_window) |window| closeTerminalTab(window, id);
            return 0;
        };
        return 0;
    }
    if (message == wm.WM_LBUTTONUP) {
        const result = comctl32.DefSubclassProc(control, message, wparam, lparam);
        if (app_window) |window| _ = user32.SetFocus(window);
        return result;
    }
    return comctl32.DefSubclassProc(control, message, wparam, lparam);
}

fn showActiveTabContextMenu() !void {
    const id = workspace_state.active_tab_id orelse return;
    const control = tab_control orelse return error.TabControlUnavailable;
    const index = nativeIndexForTab(id) orelse return error.ActiveTabNotSynchronized;
    var bounds: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, index, @bitCast(@intFromPtr(&bounds))) == 0)
        return error.GetTabItemRectFailed;
    var point: foundation.POINT = .{ .x = bounds.left, .y = bounds.bottom };
    if (user32.ClientToScreen(control, &point) == 0) return error.ClientToScreenFailed;
    try showTabContextMenu(id, point);
}

fn showTabContextMenu(id: workspace.TabId, point: foundation.POINT) !void {
    const window = app_window orelse return error.AppWindowUnavailable;
    try activateTab(window, id);
    const menu = user32.CreatePopupMenu() orelse return error.CreateContextMenuFailed;
    defer _ = user32.DestroyMenu(menu);
    if (user32.AppendMenuW(menu, wm.MF_STRING, context_menu_new_tab, context_menu_new_tab_label) == 0)
        return error.AppendContextMenuItemFailed;
    if (user32.AppendMenuW(menu, wm.MF_STRING, context_menu_rename_tab, context_menu_rename_tab_label) == 0)
        return error.AppendContextMenuItemFailed;
    if (user32.AppendMenuW(menu, wm.MF_SEPARATOR, 0, null) == 0)
        return error.AppendContextMenuItemFailed;
    if (user32.AppendMenuW(menu, wm.MF_STRING, context_menu_close_tab, context_menu_close_tab_label) == 0)
        return error.AppendContextMenuItemFailed;
    if (test_context_menu_command) |command| {
        _ = user32.SendMessageW(window, wm.WM_COMMAND, command, 0);
        return;
    }
    _ = user32.SetForegroundWindow(window);
    _ = user32.TrackPopupMenu(menu, wm.TPM_RIGHTBUTTON, point.x, point.y, 0, window, null);
}

fn handleContextMenuCommand(window: foundation.HWND, command: usize) bool {
    switch (command) {
        context_menu_new_tab => createTerminalTab(window) catch |err|
            std.log.err("failed to create terminal tab from context menu: {}", .{err}),
        context_menu_rename_tab => if (workspace_state.active_tab_id) |id|
            beginRenameTab(id) catch |err|
                std.log.err("failed to rename terminal tab from context menu: {}", .{err}),
        context_menu_close_tab => if (workspace_state.active_tab_id) |id|
            closeTerminalTab(window, id),
        else => return false,
    }
    return true;
}

fn syncNativeTabs() !void {
    // Rebuilding item indices invalidates an editor's placement. This also
    // keeps future reorder operations from leaving an orphaned overlay.
    if (rename_editor != null) cancelRename();
    const control = tab_control orelse return error.TabControlUnavailable;
    _ = user32.SendMessageW(control, controls.TCM_DELETEALLITEMS, 0, 0);

    for (workspace_state.tabs.items, 0..) |tab, index| {
        const label = tab.effectiveLabel();
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(
            std.heap.smp_allocator,
            label,
        );
        defer std.heap.smp_allocator.free(wide);
        var item: controls.TCITEMW = .{
            .mask = .{ .TEXT = 1, .PARAM = 1 },
            .dwState = controls.TCIS_BUTTONPRESSED,
            .dwStateMask = controls.TCIS_BUTTONPRESSED,
            .pszText = wide.ptr,
            .cchTextMax = @intCast(wide.len),
            .iImage = -1,
            .lParam = @intCast(@intFromEnum(tab.id)),
        };
        const inserted = user32.SendMessageW(
            control,
            controls.TCM_INSERTITEMW,
            index,
            @bitCast(@intFromPtr(&item)),
        );
        if (inserted < 0) return error.InsertTabItemFailed;
    }

    const active_id = workspace_state.active_tab_id orelse return;
    const active_index = nativeIndexForTab(active_id) orelse
        return error.ActiveTabNotSynchronized;
    _ = user32.SendMessageW(
        control,
        controls.TCM_SETCURSEL,
        active_index,
        0,
    );
}

fn updateNativeTabLabel(id: workspace.TabId) !void {
    const control = tab_control orelse return error.TabControlUnavailable;
    const tab = workspace_state.tab(id) orelse return;
    const index = nativeIndexForTab(id) orelse return;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, tab.effectiveLabel());
    defer std.heap.smp_allocator.free(wide);
    var item: controls.TCITEMW = .{
        .mask = .{ .TEXT = 1 },
        .dwState = controls.TCIS_BUTTONPRESSED,
        .dwStateMask = controls.TCIS_BUTTONPRESSED,
        .pszText = wide.ptr,
        .cchTextMax = @intCast(wide.len),
        .iImage = -1,
        .lParam = 0,
    };
    if (user32.SendMessageW(control, controls.TCM_SETITEMW, index, @bitCast(@intFromPtr(&item))) == 0)
        return error.UpdateTabItemFailed;
}

fn updateWindowCaption(window: foundation.HWND) void {
    const tab = workspace_state.activeTab() orelse return;
    const session = tab.root.terminalSession();
    const caption = if (tab.title_override) |title|
        if (title.len != 0) title else session.model.core.getTitle() orelse "ttyrtle"
    else
        session.model.core.getTitle() orelse "ttyrtle";
    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, caption) catch return;
    defer std.heap.smp_allocator.free(wide);
    _ = user32.SetWindowTextW(window, wide);
}

const ConptyTabSetup = struct {
    window: foundation.HWND,
    dimensions: geometry.Dimensions,
};

fn startConptyTab(session: *workspace.TerminalSession, setup: *const ConptyTabSetup) !void {
    const process = try conpty.Session.create(
        std.heap.smp_allocator,
        setup.window,
        @intFromEnum(session.id),
        setup.dimensions,
        null,
    );
    errdefer process.destroy();
    try session.attachProcess(.{ .context = process, .destroy = destroyConptyProcess });
    session.model.setReplySink(.{ .context = process, .write = queueTerminalReply });
}

fn createTerminalTab(window: foundation.HWND) !void {
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0) return error.GetClientRectFailed;
    const dimensions: geometry.Dimensions = terminal_metrics.dimensions(client.right - client.left, client.bottom - client.top) orelse
        .{ .columns = 80, .rows = 24 };
    var setup: ConptyTabSetup = .{ .window = window, .dimensions = dimensions };
    const id = if (isSmokeMode(active_mode))
        try workspace_state.createTab(dimensions.rows, dimensions.columns)
    else
        try workspace_state.createTabWithSetup(
            dimensions.rows,
            dimensions.columns,
            &setup,
            startConptyTab,
        );
    try syncNativeTabs();
    try activateTab(window, id);
    updateWindowCaption(window);
    _ = user32.SetFocus(window);
}

fn closeTerminalTab(window: foundation.HWND, id: workspace.TabId) void {
    if (rename_editor) |editor| if (editor.tab_id == id) cancelRename();
    const tab = workspace_state.tab(id) orelse return;
    tab.root.terminalSession().closeProcess();
    _ = workspace_state.closeTab(id);
    if (workspace_state.activeTab()) |next| {
        model = &next.root.terminalSession().model;
        input_translator = .{};
        selection_dragging = false;
        syncNativeTabs() catch {};
        updateWindowCaption(window);
        model.markFullDamage();
        invalidateRenderDamage(window);
    } else {
        _ = user32.DestroyWindow(window);
    }
}

fn nativeIndexForTab(id: workspace.TabId) ?usize {
    const control = tab_control orelse return null;
    const count = user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0);
    if (count <= 0) return null;
    for (0..@as(usize, @intCast(count))) |index| {
        if (nativeTabIdAt(index) == id) return index;
    }
    return null;
}

fn nativeTabIdAt(index: usize) ?workspace.TabId {
    const control = tab_control orelse return null;
    var item: controls.TCITEMW = .{
        .mask = .{ .PARAM = 1 },
        .dwState = controls.TCIS_BUTTONPRESSED,
        .dwStateMask = controls.TCIS_BUTTONPRESSED,
        .pszText = null,
        .cchTextMax = 0,
        .iImage = -1,
        .lParam = 0,
    };
    if (user32.SendMessageW(
        control,
        controls.TCM_GETITEMW,
        index,
        @bitCast(@intFromPtr(&item)),
    ) == 0) return null;
    if (item.lParam < 0) return null;
    return @enumFromInt(@as(u64, @intCast(item.lParam)));
}

fn handleTabNotification(window: foundation.HWND, lparam: isize) bool {
    if (lparam == 0) return false;
    const header: *const controls.NMHDR =
        @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (header.hwndFrom != tab_control or header.code != tcn_selchange)
        return false;

    const control = tab_control orelse return false;
    const selected = user32.SendMessageW(control, controls.TCM_GETCURSEL, 0, 0);
    if (selected < 0) return true;
    const id = nativeTabIdAt(@intCast(selected)) orelse return true;
    activateTab(window, id) catch {
        std.log.err("failed to activate selected terminal tab", .{});
    };
    return true;
}

fn activateTab(window: foundation.HWND, id: workspace.TabId) !void {
    if (workspace_state.active_tab_id == id) return;
    if (!workspace_state.setActive(id)) return error.UnknownTab;
    if (tab_control) |control| {
        const native_index = nativeIndexForTab(id) orelse return error.ActiveTabNotSynchronized;
        _ = user32.SendMessageW(control, controls.TCM_SETCURSEL, native_index, 0);
    }
    model = &workspace_state.activeSession().?.model;
    input_translator = .{};
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    pressed_mouse_button = null;
    render_cache.deinit();
    render_cache = .init(std.heap.smp_allocator);
    // Row generations are model-local; retained GPU text layouts must not be
    // reused for a different terminal merely because their numbers match.
    active_renderer.invalidateTerminalContent();
    model.markFullDamage();
    try resizeForClient(window);
    updateWindowCaption(window);
    invalidateRenderDamage(window);
    _ = user32.SetFocus(window);
}

fn layoutTabControl(window: foundation.HWND) !void {
    const control = tab_control orelse return;
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0)
        return error.GetClientRectFailed;
    if (user32.SetWindowPos(
        control,
        null,
        0,
        0,
        @max(client.right - client.left, 0),
        @intCast(terminal_metrics.margin_y),
        .{ .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) return error.LayoutTabControlFailed;
}

fn verifyNativeTabControl(window: foundation.HWND) !void {
    const control = tab_control orelse return error.TabControlUnavailable;
    if (user32.GetDlgItem(window, tab_control_id) != control)
        return error.TabControlIdMismatch;
    if (user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0) !=
        @as(isize, @intCast(workspace_state.tabs.items.len)))
        return error.TabControlItemCountMismatch;
    if (user32.SendMessageW(control, controls.TCM_GETCURSEL, 0, 0) != 0)
        return error.TabControlSelectionMismatch;
    for (workspace_state.tabs.items, 0..) |tab, index| {
        if (nativeTabIdAt(index) != tab.id)
            return error.TabControlIdentityMismatch;
    }

    var bounds: foundation.RECT = undefined;
    if (user32.GetWindowRect(control, &bounds) == 0)
        return error.GetTabControlRectFailed;
    if (bounds.bottom - bounds.top != @as(i32, @intCast(terminal_metrics.margin_y)))
        return error.TabControlHeightMismatch;

    const first_id = workspace_state.tabs.items[0].id;
    const second_id = workspace_state.tabs.items[1].id;
    var notification: controls.NMHDR = .{
        .hwndFrom = control,
        .idFrom = tab_control_id,
        .code = tcn_selchange,
    };
    _ = user32.SendMessageW(control, controls.TCM_SETCURSEL, 1, 0);
    _ = user32.SendMessageW(
        window,
        wm.WM_NOTIFY,
        tab_control_id,
        @bitCast(@intFromPtr(&notification)),
    );
    if (workspace_state.active_tab_id != second_id)
        return error.NativeTabSelectionDidNotActivateWorkspaceTab;

    _ = user32.SendMessageW(control, controls.TCM_SETCURSEL, 0, 0);
    _ = user32.SendMessageW(
        window,
        wm.WM_NOTIFY,
        tab_control_id,
        @bitCast(@intFromPtr(&notification)),
    );
    if (workspace_state.active_tab_id != first_id)
        return error.NativeTabSelectionDidNotRestoreWorkspaceTab;

    // Runtime creation must insert the native item before activation tries to
    // synchronize its selection. This covers the Ctrl+Shift+T lifecycle
    // without requiring physical modifier-key state in a hidden test window.
    const count_before_create = workspace_state.tabs.items.len;
    try createTerminalTab(window);
    if (workspace_state.tabs.items.len != count_before_create + 1)
        return error.RuntimeTabCreationDidNotAddWorkspaceTab;
    if (user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0) !=
        @as(isize, @intCast(workspace_state.tabs.items.len)))
        return error.RuntimeTabCreationDidNotSynchronizeNativeItem;
    const created = workspace_state.active_tab_id orelse
        return error.RuntimeTabCreationDidNotActivateTab;
    const created_index = nativeIndexForTab(created) orelse
        return error.RuntimeTabCreationMissingNativeIdentity;
    if (user32.SendMessageW(control, controls.TCM_GETCURSEL, 0, 0) !=
        @as(isize, @intCast(created_index)))
        return error.RuntimeTabCreationDidNotSelectNativeItem;
    closeTerminalTab(window, created);
    if (workspace_state.tabs.items.len != count_before_create)
        return error.RuntimeTabCloseDidNotRemoveWorkspaceTab;
}

fn verifyShortcutDispatch(window: foundation.HWND) !void {
    const count_before = workspace_state.tabs.items.len;
    test_modifiers = .{ .ctrl = true, .shift = true };
    defer test_modifiers = null;

    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 'T', 1);
    _ = user32.SendMessageW(window, wm.WM_CHAR, 't', 1);
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 'T', (@as(isize, 1) << 30) | 1);
    _ = user32.SendMessageW(window, wm.WM_CHAR, 't', 1);
    _ = user32.SendMessageW(window, wm.WM_KEYUP, 'T', @as(isize, 1) << 31);
    if (workspace_state.tabs.items.len != count_before + 1)
        return error.ShortcutCreateRepeatWasNotSuppressed;
    if (shortcut_state.pending_characters != 0)
        return error.ShortcutCharacterWasNotSuppressed;

    const first_id = workspace_state.tabs.items[0].id;
    const created_id = workspace_state.active_tab_id orelse return error.ShortcutCreateDidNotActivateTab;
    test_modifiers = .{ .ctrl = true };
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 0x09, 1);
    if (workspace_state.active_tab_id != first_id)
        return error.ShortcutCycleDidNotAdvance;
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 0x09, (@as(isize, 1) << 30) | 1);
    if (workspace_state.active_tab_id != created_id)
        return error.ShortcutCycleDidNotRepeat;
    _ = user32.SendMessageW(window, wm.WM_KEYUP, 0x09, @as(isize, 1) << 31);

    test_modifiers = .{ .ctrl = true, .shift = true };
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 'W', 1);
    _ = user32.SendMessageW(window, wm.WM_CHAR, 'w', 1);
    _ = user32.SendMessageW(window, wm.WM_KEYUP, 'W', @as(isize, 1) << 31);
    if (workspace_state.tabs.items.len != count_before)
        return error.ShortcutCloseDidNotSynchronizeTabs;
}

fn verifyInlineRename(window: foundation.HWND) !void {
    const id = workspace_state.active_tab_id orelse return error.RenameMissingActiveTab;
    const control = tab_control orelse return error.TabControlUnavailable;
    var bounds: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, 0, @bitCast(@intFromPtr(&bounds))) == 0)
        return error.GetTabItemRectFailed;
    const x: u16 = @intCast(bounds.left + 4);
    const y: u16 = @intCast(bounds.top + 4);
    const point = @as(isize, x) | (@as(isize, y) << 16);
    _ = user32.SendMessageW(control, wm.WM_LBUTTONDBLCLK, 0, point);
    const editor = rename_editor orelse return error.RenameEditorWasNotCreated;
    const committed = std.unicode.utf8ToUtf16LeStringLiteral("  Build  ");
    _ = user32.SetWindowTextW(editor.window, committed);
    _ = user32.SendMessageW(editor.window, wm.WM_KEYDOWN, 0x0d, 1);
    if (rename_editor != null) return error.RenameEditorDidNotCommit;
    if (!std.mem.eql(u8, workspace_state.tab(id).?.title_override.?, "Build"))
        return error.RenameDidNotTrimAndCommit;

    try beginRenameTab(id);
    const cancelled = rename_editor orelse return error.RenameEditorWasNotRecreated;
    _ = user32.SetWindowTextW(cancelled.window, std.unicode.utf8ToUtf16LeStringLiteral("Discard"));
    _ = user32.SendMessageW(cancelled.window, wm.WM_KEYDOWN, 0x1b, 1);
    if (!std.mem.eql(u8, workspace_state.tab(id).?.title_override.?, "Build"))
        return error.RenameEscapeDidNotCancel;

    try beginRenameTab(id);
    const cleared = rename_editor orelse return error.RenameEditorWasNotRecreated;
    _ = user32.SetWindowTextW(cleared.window, std.unicode.utf8ToUtf16LeStringLiteral("   "));
    _ = user32.SetFocus(window);
    if (workspace_state.tab(id).?.title_override != null)
        return error.EmptyRenameDidNotClearOverride;

    try beginRenameTab(id);
    _ = user32.SendMessageW(window, wm.WM_SIZE, wm.SIZE_RESTORED, 0);
    if (rename_editor == null) return error.RenameEditorDidNotSurviveResize;
    cancelRename();

    try createTerminalTab(window);
    const created = workspace_state.active_tab_id orelse return error.RenameCreateDidNotActivate;
    try beginRenameTab(created);
    closeTerminalTab(window, created);
    if (rename_editor != null) return error.RenameEditorDidNotCancelForClose;
}

fn verifyTabInteractions(window: foundation.HWND) !void {
    const control = tab_control orelse return error.TabControlUnavailable;
    try createTerminalTab(window);
    const hit_id = workspace_state.active_tab_id orelse return error.InteractionMissingActiveTab;
    const hit_index = nativeIndexForTab(hit_id) orelse return error.InteractionMissingNativeTab;
    var bounds: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, hit_index, @bitCast(@intFromPtr(&bounds))) == 0)
        return error.GetTabItemRectFailed;
    var screen_point: foundation.POINT = .{ .x = bounds.left + 4, .y = bounds.top + 4 };
    if (user32.ClientToScreen(control, &screen_point) == 0) return error.ClientToScreenFailed;

    test_context_menu_command = context_menu_rename_tab;
    defer test_context_menu_command = null;
    _ = user32.SendMessageW(control, wm.WM_CONTEXTMENU, 0, packMessagePoint(screen_point));
    const editor = rename_editor orelse return error.ContextMenuRenameDidNotOpenEditor;
    if (editor.tab_id != hit_id) return error.ContextMenuDidNotSelectHitTab;
    cancelRename();

    const count_before_create = workspace_state.tabs.items.len;
    test_context_menu_command = context_menu_new_tab;
    _ = user32.SendMessageW(window, wm.WM_CONTEXTMENU, 0, -1);
    if (workspace_state.tabs.items.len != count_before_create + 1)
        return error.KeyboardContextMenuDidNotCreateTab;
    const created = workspace_state.active_tab_id orelse return error.ContextMenuCreateDidNotActivateTab;
    if (created == hit_id) return error.ContextMenuCreateDidNotSelectNewTab;

    test_context_menu_command = context_menu_close_tab;
    _ = user32.SendMessageW(window, wm.WM_CONTEXTMENU, 0, -1);
    if (workspace_state.tabs.items.len != count_before_create)
        return error.KeyboardContextMenuDidNotCloseTab;
    if (workspace_state.active_tab_id != hit_id)
        return error.ContextMenuCloseDidNotRestoreNearestTab;

    const count_before_middle_close = workspace_state.tabs.items.len;
    _ = user32.SendMessageW(control, wm.WM_MBUTTONDOWN, 0, packMessagePoint(.{
        .x = bounds.left + 4,
        .y = bounds.top + 4,
    }));
    if (workspace_state.tabs.items.len != count_before_middle_close - 1)
        return error.MiddleClickDidNotCloseTab;
    if (workspace_state.tab(hit_id) != null) return error.MiddleClickClosedWrongTab;
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
            if (isSmokeMode(active_mode)) {
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
        wm.WM_NOTIFY => {
            if (handleTabNotification(window, lparam)) return 0;
            return user32.DefWindowProcW(window, message, wparam, lparam);
        },
        wm.WM_COMMAND => {
            if (lparam == 0 and handleContextMenuCommand(window, wparam & 0xffff)) return 0;
            return user32.DefWindowProcW(window, message, wparam, lparam);
        },
        wm.WM_CONTEXTMENU => {
            // The keyboard context-menu gesture is delivered to the focused
            // terminal window, so anchor it to the active native tab.
            if (lparam == -1) {
                showActiveTabContextMenu() catch |err|
                    std.log.err("failed to show tab context menu: {}", .{err});
                return 0;
            }
            return user32.DefWindowProcW(window, message, wparam, lparam);
        },
        wm.WM_DPICHANGED => {
            terminal_metrics = active_renderer.metricsForDpi(@as(u16, @truncate(wparam)));
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
            handleConptyOutput(window, @enumFromInt(@as(u64, @intCast(wparam))));
            return 0;
        },
        conpty.child_exit_message => {
            if (workspace_state.session(@enumFromInt(@as(u64, @intCast(wparam))))) |session| {
                if (session.processAs(conpty.Session)) |process| {
                    _ = process.beginClosing();
                    if (process.childExitCode()) |code|
                        std.log.info("ConPTY child exited with code {d}", .{code});
                    if (session.noteChildExit())
                        closeTerminalTab(window, workspace_state.tabForSession(session.id).?.id);
                }
            }
            return 0;
        },
        conpty.input_failure_message => {
            if (workspace_state.session(@enumFromInt(@as(u64, @intCast(wparam))))) |session| {
                if (session.processAs(conpty.Session)) |process| if (process.inputFailureCode()) |code|
                    std.log.err(
                        "WriteFile for ConPTY input failed with Win32 error {d}",
                        .{code},
                    );
            }
            return 0;
        },
        wm.WM_KEYDOWN, wm.WM_SYSKEYDOWN, wm.WM_KEYUP, wm.WM_SYSKEYUP => {
            _ = handleKeyMessage(message, wparam, lparam);
            return 0;
        },
        wm.WM_CHAR, wm.WM_SYSCHAR => {
            if (!shortcut_state.consumeCharacter()) handleCharacterMessage(@truncate(wparam));
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
            if (model_initialized) {
                for (workspace_state.tabs.items) |*tab| tab.root.terminalSession().closeProcess();
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

const Shortcut = enum {
    suppress,
    new_tab,
    close_tab,
    cycle_forward,
    cycle_backward,
    select_tab,
    paste,
    copy,
};

const ShortcutState = struct {
    held: std.EnumSet(Shortcut) = .{},
    pending_characters: u8 = 0,

    fn handleKey(
        self: *ShortcutState,
        message: u32,
        virtual_key: usize,
        repeated: bool,
        mods: input.Mods,
    ) ?Shortcut {
        const is_down = message == wm.WM_KEYDOWN or message == wm.WM_SYSKEYDOWN;
        const is_up = message == wm.WM_KEYUP or message == wm.WM_SYSKEYUP;
        if (!is_down and !is_up) return null;

        if (is_up) {
            for (std.enums.values(Shortcut)) |shortcut| {
                if (self.held.contains(shortcut) and shortcutVirtualKey(shortcut, virtual_key)) {
                    self.held.remove(shortcut);
                    return shortcut;
                }
            }
            return null;
        }

        const shortcut = shortcutForKey(virtual_key, mods) orelse return null;
        self.held.insert(shortcut);
        // TranslateMessage can generate a WM_CHAR or WM_SYSCHAR even though
        // this command was handled by the application. Keep it out of ConPTY.
        if (shortcut != .cycle_forward and shortcut != .cycle_backward)
            self.pending_characters +|= 1;
        if (repeated and shortcut != .cycle_forward and shortcut != .cycle_backward)
            return .suppress;
        return shortcut;
    }

    fn consumeCharacter(self: *ShortcutState) bool {
        if (self.pending_characters == 0) return false;
        self.pending_characters -= 1;
        return true;
    }
};

fn shortcutForKey(virtual_key: usize, mods: input.Mods) ?Shortcut {
    if (mods.ctrl and mods.shift) return switch (virtual_key) {
        'T' => .new_tab,
        'W' => .close_tab,
        'V' => .paste,
        'C' => .copy,
        else => null,
    };
    if (mods.ctrl and virtual_key == 0x09)
        return if (mods.shift) .cycle_backward else .cycle_forward;
    if (mods.alt and virtual_key >= '1' and virtual_key <= '9') return .select_tab;
    return null;
}

fn shortcutVirtualKey(shortcut: Shortcut, virtual_key: usize) bool {
    return switch (shortcut) {
        .suppress => false,
        .new_tab => virtual_key == 'T',
        .close_tab => virtual_key == 'W',
        .cycle_forward, .cycle_backward => virtual_key == 0x09,
        .select_tab => virtual_key >= '1' and virtual_key <= '9',
        .paste => virtual_key == 'V',
        .copy => virtual_key == 'C',
    };
}

test "shortcut dispatch consumes press release and generated character" {
    var state: ShortcutState = .{};
    const mods: input.Mods = .{ .ctrl = true, .shift = true };
    try std.testing.expectEqual(
        Shortcut.new_tab,
        state.handleKey(wm.WM_KEYDOWN, 'T', false, mods).?,
    );
    try std.testing.expect(state.consumeCharacter());
    try std.testing.expect(!state.consumeCharacter());
    try std.testing.expectEqual(
        Shortcut.new_tab,
        state.handleKey(wm.WM_KEYUP, 'T', false, .{}).?,
    );
}

test "create and close shortcuts suppress repeats while tab cycling repeats" {
    var state: ShortcutState = .{};
    const tab_mods: input.Mods = .{ .ctrl = true, .shift = true };
    try std.testing.expectEqual(
        Shortcut.close_tab,
        state.handleKey(wm.WM_KEYDOWN, 'W', false, tab_mods).?,
    );
    try std.testing.expectEqual(
        Shortcut.suppress,
        state.handleKey(wm.WM_KEYDOWN, 'W', true, tab_mods).?,
    );
    try std.testing.expect(state.consumeCharacter());
    try std.testing.expect(state.consumeCharacter());

    const cycle_mods: input.Mods = .{ .ctrl = true };
    try std.testing.expectEqual(
        Shortcut.cycle_forward,
        state.handleKey(wm.WM_KEYDOWN, 0x09, false, cycle_mods).?,
    );
    try std.testing.expectEqual(
        Shortcut.cycle_forward,
        state.handleKey(wm.WM_KEYDOWN, 0x09, true, cycle_mods).?,
    );
}

fn handleKeyMessage(message: u32, wparam: usize, lparam: isize) bool {
    const is_down = message == wm.WM_KEYDOWN or message == wm.WM_SYSKEYDOWN;
    const bits: usize = @bitCast(lparam);
    const repeated = (bits & (@as(usize, 1) << 30)) != 0;
    const modifiers = currentModifiers();
    if (shortcut_state.handleKey(message, wparam, repeated, modifiers)) |shortcut| switch (shortcut) {
        .suppress => {},
        .new_tab => if (is_down) {
            const window = app_window orelse return true;
            createTerminalTab(window) catch |err| std.log.err("failed to create terminal tab: {}", .{err});
        },
        .close_tab => if (is_down) if (workspace_state.active_tab_id) |id| {
            closeTerminalTab(app_window orelse return true, id);
        },
        .cycle_forward, .cycle_backward => {
            if (!is_down) return true;
            const current = workspace_state.indexOfTab(workspace_state.active_tab_id orelse return true) orelse return true;
            const count = workspace_state.tabs.items.len;
            const next = if (shortcut == .cycle_backward) (current + count - 1) % count else (current + 1) % count;
            activateTab(app_window orelse return true, workspace_state.tabs.items[next].id) catch {};
        },
        .select_tab => {
            if (!is_down) return true;
            const index: usize = @intCast(wparam - '1');
            if (index < workspace_state.tabs.items.len) activateTab(app_window orelse return true, workspace_state.tabs.items[index].id) catch {};
        },
        .paste => if (is_down) pasteClipboard(null),
        .copy => if (is_down) copySelection(null),
    } else {
        if (isSmokeMode(active_mode) or activeProcess() == null) return false;
        const action: input.Action = if (!is_down)
            .release
        else if (repeated)
            .repeat
        else
            .press;
        const event = input_translator.keyEvent(
            @truncate(wparam),
            @truncate((bits >> 16) & 0xff),
            action,
            modifiers,
            (bits & (@as(usize, 1) << 24)) != 0,
            @truncate(bits & 0xffff),
        ) orelse return false;
        encodeAndQueueInput(event);
        return false;
    }
    return true;
}

const MouseButton = input.MouseButton;

fn queueFocus(event: input.FocusEvent) void {
    if (isSmokeMode(active_mode) or activeProcess() == null) return;
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
    const active_session = activeProcess() orelse {
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

fn packMessagePoint(point: foundation.POINT) isize {
    const x: u16 = @bitCast(@as(i16, @intCast(point.x)));
    const y: u16 = @bitCast(@as(i16, @intCast(point.y)));
    return @intCast(@as(u32, x) | (@as(u32, y) << 16));
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
    const damage = model.damage();
    switch (damage) {
        .none => return,
        else => active_renderer.requestFrame(),
    }
    switch (damage) {
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
    if (activeProcess() == null or user32.OpenClipboard(window) == 0) return;
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
    if (isSmokeMode(active_mode) or activeProcess() == null) return;
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
    const active_session = activeProcess() orelse return;
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

fn destroyConptyProcess(context: *anyopaque) void {
    const process: *conpty.Session = @ptrCast(@alignCast(context));
    process.destroy();
}

fn activeProcess() ?*conpty.Session {
    if (!model_initialized) return null;
    const active_session = workspace_state.activeSession() orelse return null;
    return active_session.processAs(conpty.Session);
}

fn currentModifiers() input.Mods {
    if (test_modifiers) |mods| return mods;
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
    const paint_start = frame_trace.timestamp();
    defer paint_trace.recordSince(paint_start);

    var paint_state: gdi.PAINTSTRUCT = undefined;
    const dc = user32.BeginPaint(window, &paint_state) orelse return false;
    defer _ = user32.EndPaint(window, &paint_state);

    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0) return false;

    const damage = model.damage();
    const cache_start = frame_trace.timestamp();
    render_cache.update(
        model,
        terminal_metrics,
        damage,
    ) catch return false;
    cache_trace.recordSince(cache_start);
    const rendered = active_renderer.paint(
        dc,
        paint_state.rcPaint,
        client,
        &render_cache,
        damage,
        terminal_metrics,
        user32.GetDpiForWindow(window),
    );
    model.acknowledgeDamage();
    return rendered;
}

fn resizeForClient(window: foundation.HWND) !void {
    if (!model_initialized) return;

    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0)
        return error.GetClientRectFailed;
    try layoutTabControl(window);
    repositionRenameEditor();
    if (active_renderer.resize(
        @intCast(@max(client.right - client.left, 0)),
        @intCast(@max(client.bottom - client.top, 0)),
        user32.GetDpiForWindow(window),
    )) model.markFullDamage();
    const dimensions = terminal_metrics.dimensions(
        client.right - client.left,
        client.bottom - client.top,
    ) orelse return;
    for (workspace_state.tabs.items) |*tab| {
        const session = tab.root.terminalSession();
        if (dimensions.rows == session.model.rows() and dimensions.columns == session.model.columns())
            continue;
        try session.model.resize(
            dimensions.rows,
            dimensions.columns,
            terminal_metrics.cell_width,
            terminal_metrics.cell_height,
        );
        if (session.processAs(conpty.Session)) |process|
            _ = process.resize(dimensions) catch |err| switch (err) {
                error.SessionClosing => {},
                else => return err,
            };
    }
    invalidateRenderDamage(window);
}

fn handleConptyOutput(window: foundation.HWND, session_id: workspace.SessionId) void {
    const session = workspace_state.session(session_id) orelse return;
    const process = session.processAs(conpty.Session) orelse return;
    var batch = process.drainOutput();
    defer batch.deinit();

    const changed = batch.chunks.items.len != 0;
    if (changed) {
        applyOutputBatchForSession(window, session, batch.chunks.items) catch {
            std.log.err("failed to apply ConPTY output to the terminal model", .{});
            if (isIntegrationMode(active_mode)) _ = user32.DestroyWindow(window);
            return;
        };
    } else {
        applyTerminalEffectsForSession(window, session);
    }

    if (workspace_state.activeSession() == session and active_mode == .integration_resize and
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
        if (session.noteOutputFinished())
            closeTerminalTab(window, workspace_state.tabForSession(session.id).?.id);
    }
}

fn logDebugCounters() void {
    if (builtin.mode != .Debug or active_mode != .normal or
        !model_initialized or !render_cache_initialized)
        return;
    const terminal_counts = model.diagnostics();
    const cache_counts = render_cache.diagnostics();
    const renderer_counts = active_renderer.diagnostics();
    std.log.info(
        "performance counters: batches={d} chunks={d} refreshes={d} " ++
            "dirty_rows={d} rebuilt_rows={d} layout_rebuilds={d} " ++
            "rectangle_requests={d} rectangle_commands={d} " ++
            "frames_requested={d} frames_presented={d} " ++
            "gpu_presents={d} device_recreations={d}",
        .{
            terminal_counts.output_batches,
            terminal_counts.chunks_parsed,
            terminal_counts.render_refreshes,
            cache_counts.dirty_rows,
            cache_counts.rebuilt_rows,
            renderer_counts.layout_build_count,
            cache_counts.rectangle_requests,
            cache_counts.rectangle_commands,
            renderer_counts.frames_requested,
            renderer_counts.frames_presented,
            renderer_counts.gpu_present_count,
            renderer_counts.gpu_recreation_count,
        },
    );
    const trace_file = kernel32.CreateFileW(
        trace_file_name,
        file_system.FILE_GENERIC_WRITE,
        .{},
        null,
        file_system.CREATE_ALWAYS,
        file_system.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (trace_file != foundation.INVALID_HANDLE_VALUE) {
        defer _ = kernel32.CloseHandle(trace_file);
        writeTraceLine(
            trace_file,
            "performance counters: batches={d} chunks={d} refreshes={d} " ++
                "dirty_rows={d} rebuilt_rows={d} layout_rebuilds={d} " ++
                "rectangle_requests={d} rectangle_commands={d} " ++
                "frames_requested={d} frames_presented={d} " ++
                "gpu_presents={d} device_recreations={d}",
            .{
                terminal_counts.output_batches,
                terminal_counts.chunks_parsed,
                terminal_counts.render_refreshes,
                cache_counts.dirty_rows,
                cache_counts.rebuilt_rows,
                renderer_counts.layout_build_count,
                cache_counts.rectangle_requests,
                cache_counts.rectangle_commands,
                renderer_counts.frames_requested,
                renderer_counts.frames_presented,
                renderer_counts.gpu_present_count,
                renderer_counts.gpu_recreation_count,
            },
        );
        writeFrameTrace(trace_file, "output", output_trace.snapshot());
        writeFrameTrace(trace_file, "parse", terminal_counts.parse_trace);
        writeFrameTrace(
            trace_file,
            "render_state",
            terminal_counts.render_state_trace,
        );
        writeFrameTrace(trace_file, "damage", terminal_counts.damage_trace);
        writeFrameTrace(trace_file, "paint", paint_trace.snapshot());
        writeFrameTrace(trace_file, "cache", cache_trace.snapshot());
        writeFrameTrace(trace_file, "gpu", renderer_counts.gpu_paint_trace);
        writeFrameTrace(trace_file, "scene", renderer_counts.scene_trace);
        writeFrameTrace(trace_file, "layout", renderer_counts.layout_trace);
        writeFrameTrace(trace_file, "copy", renderer_counts.copy_trace);
        writeFrameTrace(trace_file, "present", renderer_counts.present_trace);
    }
    logFrameTrace("output", output_trace.snapshot());
    logFrameTrace("parse", terminal_counts.parse_trace);
    logFrameTrace("render_state", terminal_counts.render_state_trace);
    logFrameTrace("damage", terminal_counts.damage_trace);
    logFrameTrace("paint", paint_trace.snapshot());
    logFrameTrace("cache", cache_trace.snapshot());
    logFrameTrace("gpu", renderer_counts.gpu_paint_trace);
    logFrameTrace("scene", renderer_counts.scene_trace);
    logFrameTrace("layout", renderer_counts.layout_trace);
    logFrameTrace("copy", renderer_counts.copy_trace);
    logFrameTrace("present", renderer_counts.present_trace);
}

fn logFrameTrace(name: []const u8, stats: frame_trace.Stats) void {
    std.log.info(
        "frame trace {s}: samples={d} total_us={d} avg_us={d} max_us={d}",
        .{
            name,
            stats.samples,
            frame_trace.ticksToMicroseconds(stats.total_ticks),
            frame_trace.ticksToMicroseconds(stats.averageTicks()),
            frame_trace.ticksToMicroseconds(stats.max_ticks),
        },
    );
}

fn writeFrameTrace(
    file: foundation.HANDLE,
    name: []const u8,
    stats: frame_trace.Stats,
) void {
    writeTraceLine(
        file,
        "frame trace {s}: samples={d} total_us={d} avg_us={d} max_us={d}",
        .{
            name,
            stats.samples,
            frame_trace.ticksToMicroseconds(stats.total_ticks),
            frame_trace.ticksToMicroseconds(stats.averageTicks()),
            frame_trace.ticksToMicroseconds(stats.max_ticks),
        },
    );
}

fn writeTraceLine(
    file: foundation.HANDLE,
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\r\n", args) catch return;
    var written: u32 = 0;
    _ = kernel32.WriteFile(
        file,
        line.ptr,
        @intCast(line.len),
        &written,
        null,
    );
}

fn applyOutputBatch(window: foundation.HWND, chunks: []const []const u8) !void {
    try applyOutputBatchForSession(window, workspace_state.activeSession() orelse return, chunks);
}

fn applyOutputBatchForSession(
    window: foundation.HWND,
    session: *workspace.TerminalSession,
    chunks: []const []const u8,
) !void {
    const trace_start = frame_trace.timestamp();
    defer output_trace.recordSince(trace_start);
    try session.model.writeBatch(chunks);
    session.model.resetCursorBlink();
    applyTerminalEffectsForSession(window, session);
    if (workspace_state.activeSession() == session) invalidateRenderDamage(window);
}

fn applyTerminalEffectsForSession(window: foundation.HWND, session: *workspace.TerminalSession) void {
    if (session.model.takeTitleChanged()) {
        const tab = workspace_state.tabForSession(session.id) orelse return;
        updateNativeTabLabel(tab.id) catch {};
        if (workspace_state.activeSession() != session) return;
        const title = tab.effectiveLabel();
        const wide = std.unicode.utf8ToUtf16LeAllocZ(
            std.heap.smp_allocator,
            title,
        ) catch null;
        if (wide) |value| {
            defer std.heap.smp_allocator.free(value);
            _ = user32.SetWindowTextW(window, value);
        }
    }

    if (session.model.takeBellCount() > 0) _ = user32.MessageBeep(.{});
}

fn runPhase5Smoke(window: foundation.HWND) !void {
    if (!active_renderer.invalidateGpuSceneForTesting())
        return error.GpuRendererUnavailable;

    const before_initial = active_renderer.diagnostics();
    try paintForTesting(window);
    const initial = active_renderer.diagnostics();
    if (initial.frames_requested != before_initial.frames_requested + 1 or
        initial.frames_presented != before_initial.frames_presented + 1 or
        initial.gpu_present_count != before_initial.gpu_present_count + 1 or
        initial.layout_build_count == 0)
        return error.InitialGpuPaintDiagnosticsMismatch;

    try paintForTesting(window);
    const clean = active_renderer.diagnostics();
    if (clean.gpu_present_count != initial.gpu_present_count + 1 or
        clean.layout_build_count != initial.layout_build_count)
        return error.CleanPaintRebuiltLayouts;

    const clean_row_generation = active_renderer.layoutGenerationForTesting(2) orelse
        return error.RowLayoutGenerationUnavailable;
    const chunks = [_][]const u8{
        "\x1b[2;1Hphase-",
        "six-batch",
    };
    try applyOutputBatch(window, &chunks);
    const before_batch = active_renderer.diagnostics();
    try paintForTesting(window);
    const after_batch = active_renderer.diagnostics();
    if (after_batch.gpu_present_count != before_batch.gpu_present_count + 1)
        return error.OutputBatchPresentedMoreThanOnce;
    if (after_batch.layout_build_count != before_batch.layout_build_count + 2)
        return error.DirtyRowLayoutRebuildWasNotProportional;
    if (active_renderer.layoutGenerationForTesting(2) != clean_row_generation)
        return error.CleanRowLayoutGenerationChanged;

    for (0..3) |iteration| {
        _ = user32.SendMessageW(window, wm.WM_SIZE, wm.SIZE_MINIMIZED, 0);
        var outer: foundation.RECT = undefined;
        if (user32.GetWindowRect(window, &outer) == 0)
            return error.GetWindowRectFailed;
        if (user32.SetWindowPos(
            window,
            null,
            0,
            0,
            outer.right - outer.left + @as(i32, @intCast(8 + iteration)),
            outer.bottom - outer.top + @as(i32, @intCast(5 + iteration)),
            .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
        ) == 0) return error.ResizeLifecycleFailed;
        _ = user32.SendMessageW(window, wm.WM_SIZE, wm.SIZE_RESTORED, 0);
        try paintForTesting(window);
    }

    const before_invalidation = active_renderer.diagnostics();
    if (!active_renderer.invalidateGpuSceneForTesting())
        return error.GpuRendererUnavailable;
    try paintForTesting(window);
    const after_invalidation = active_renderer.diagnostics();
    if (after_invalidation.gpu_present_count !=
        before_invalidation.gpu_present_count + 1 or
        after_invalidation.layout_build_count !=
            before_invalidation.layout_build_count)
        return error.FullInvalidationDiagnosticsMismatch;

    var suggested: foundation.RECT = undefined;
    if (user32.GetWindowRect(window, &suggested) == 0)
        return error.GetWindowRectFailed;
    const test_dpi: u32 = geometry.base_dpi + 24;
    const dpi_wparam = @as(usize, test_dpi) |
        (@as(usize, test_dpi) << 16);
    _ = user32.SendMessageW(
        window,
        wm.WM_DPICHANGED,
        dpi_wparam,
        @bitCast(@intFromPtr(&suggested)),
    );
    const before_dpi_paint = active_renderer.diagnostics();
    try paintForTesting(window);
    const after_dpi_paint = active_renderer.diagnostics();
    if (after_dpi_paint.layout_build_count <=
        before_dpi_paint.layout_build_count)
        return error.DpiChangeDidNotRebuildLayouts;

    var frequency: foundation.LARGE_INTEGER = undefined;
    var scroll_start: foundation.LARGE_INTEGER = undefined;
    var scroll_end: foundation.LARGE_INTEGER = undefined;
    if (kernel32.QueryPerformanceFrequency(&frequency) == 0 or
        kernel32.QueryPerformanceCounter(&scroll_start) == 0)
        return error.PerformanceCounterUnavailable;
    const scroll_iterations = 180;
    const before_scroll = active_renderer.diagnostics();
    const scroll_chunk = [_][]const u8{"\r\nphase-five-debug-scroll"};
    for (0..scroll_iterations) |_| {
        try applyOutputBatch(window, &scroll_chunk);
        try paintForTesting(window);
    }
    if (kernel32.QueryPerformanceCounter(&scroll_end) == 0)
        return error.PerformanceCounterUnavailable;
    const after_scroll = active_renderer.diagnostics();
    if (after_scroll.gpu_present_count !=
        before_scroll.gpu_present_count + scroll_iterations)
        return error.ScrollingPresentationCountMismatch;
    const scroll_milliseconds = @divTrunc(
        (scroll_end.QuadPart - scroll_start.QuadPart) * 1000,
        frequency.QuadPart,
    );
    if (scroll_milliseconds > 12_000)
        return error.DebugScrollingNotResponsive;

    const before_loss = active_renderer.diagnostics();
    if (!active_renderer.simulateDeviceLossForTesting())
        return error.GpuRendererUnavailable;
    try paintForTesting(window);
    const after_loss = active_renderer.diagnostics();
    if (after_loss.gpu_recreation_count != before_loss.gpu_recreation_count + 1 or
        after_loss.gpu_present_count != before_loss.gpu_present_count + 1)
        return error.DeviceLossRecoveryDiagnosticsMismatch;
}

fn paintForTesting(window: foundation.HWND) !void {
    paint_completed = false;
    active_renderer.requestFrame();
    _ = user32.InvalidateRect(window, null, 0);
    _ = user32.SendMessageW(window, wm.WM_PAINT, 0, 0);
    if (!paint_completed) return error.TestPaintFailed;
}

fn isSmokeMode(mode: Mode) bool {
    return mode == .smoke or
        mode == .smoke_gdi or
        mode == .smoke_phase5 or
        mode == .smoke_tabs or
        mode == .smoke_shortcuts or
        mode == .smoke_rename or
        mode == .smoke_tab_interactions;
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
