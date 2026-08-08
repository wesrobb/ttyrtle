const std = @import("std");
const win32 = @import("win32");
const conpty = @import("conpty.zig");
const frame_trace = @import("frame_trace.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const render_commands = @import("render_commands.zig");
const renderer = @import("renderer.zig");
const retirement = @import("retirement.zig");
const terminal = @import("terminal.zig");
const tab_drag_geometry = @import("tab_drag.zig");
const workspace = @import("workspace.zig");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const memory = win32.system.memory;
const ole = win32.system.ole;
const file_system = win32.storage.file_system;
const controls = win32.ui.controls;
const hi_dpi = win32.ui.hi_dpi;
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
const context_menu_new_window = 4;
const context_menu_move_tab_to_new_window = 5;
const context_menu_move_tab_to_window_first = 0x100;
const context_menu_new_tab_label = std.unicode.utf8ToUtf16LeStringLiteral("New Tab");
const context_menu_rename_tab_label = std.unicode.utf8ToUtf16LeStringLiteral("Rename");
const context_menu_close_tab_label = std.unicode.utf8ToUtf16LeStringLiteral("Close");
const context_menu_new_window_label = std.unicode.utf8ToUtf16LeStringLiteral("New Window");
const context_menu_move_tab_to_new_window_label = std.unicode.utf8ToUtf16LeStringLiteral("Move Tab to New Window");
const context_menu_move_tab_to_window_label = std.unicode.utf8ToUtf16LeStringLiteral("Move Tab to Window");

pub const Mode = enum {
    normal,
    smoke,
    smoke_phase5,
    smoke_tabs,
    smoke_shortcuts,
    smoke_rename,
    smoke_tab_interactions,
    smoke_tab_drag,
    smoke_cross_window_drag,
    smoke_multi_window,
    smoke_transfer_hardening,
    integration,
    integration_input,
    integration_resize,
    integration_multi_session,
    integration_multi_resize,
    integration_host_close,
    integration_final_retirement,
};

var dpi_awareness_configured = false;
// TODO(multi-window): the callback conversion below is in progress. These
// compatibility aliases keep the existing single-window verification modes
// working while the native WindowState entry point is being wired through the
// remaining helpers.
var workspace_ids: workspace.IdSource = .{};
var workspace_state: *workspace.Workspace = undefined;
var model: *terminal.TerminalModel = undefined;
var model_initialized = false;
var tab_control: ?foundation.HWND = null;
var app_window: ?foundation.HWND = null;
var notification_window: ?foundation.HWND = null;
var active_mode: Mode = .normal;
var paint_completed = false;
var integration_succeeded = false;
var integration_resize_requested = false;
var integration_resize_target: geometry.Dimensions = .{ .columns = 1, .rows = 1 };
var integration_multi_session: MultiSessionIntegration = .{};
var input_translator: *input.Translator = undefined;
var shortcut_state: *ShortcutState = undefined;
var test_modifiers: ?input.Mods = null;
var test_context_menu_command: ?usize = null;
var rename_editor: ?RenameEditor = null;
var terminal_metrics: *geometry.Metrics = undefined;
var selection_dragging = false;
var selection_anchor: ?terminal.Cursor = null;
var selection_head: ?terminal.Cursor = null;
var pressed_mouse_button: ?input.MouseButton = null;
var active_renderer: *renderer.Renderer = undefined;
var render_cache: *render_commands.RenderCache = undefined;
var render_cache_initialized = false;
var output_trace: frame_trace.Counter = .{};
var paint_trace: frame_trace.Counter = .{};
var cache_trace: frame_trace.Counter = .{};
var frame_message_pending = false;
var renderer_failure_queued = false;
var renderer_failure: ?anyerror = null;
var resize_message_count: u64 = 0;
/// The process-global pointer is only the entry point used by the message-only
/// dispatcher. Every HWND-bound value lives below in `WindowState` and is
/// recovered from GWLP_USERDATA for every top-level callback.
var active_application: ?*Application = null;

const cursor_timer_id = 1;
const frame_message = wm.WM_APP + 10;
const renderer_failure_message = wm.WM_APP + 11;
const tab_drop_message = wm.WM_APP + 12;

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
const integration_multi_first_marker = "CONPTY_MULTI_FIRST";
const integration_multi_first_title = "BACKGROUND_OSC_TITLE";
const integration_multi_first_command =
    "cmd.exe /d /q /s /c \"ping -n 2 127.0.0.1 >nul & echo \x1b]0;" ++
    integration_multi_first_title ++ "\x07" ++ integration_multi_first_marker ++ " > CON\"";
const integration_multi_second_marker = "CONPTY_MULTI_SECOND";
const integration_multi_second_command =
    "cmd.exe /d /q /s /c \"ping -n 3 127.0.0.1 >nul & echo " ++
    integration_multi_second_marker ++ " > CON\"";

const MultiSessionIntegration = struct {
    first: ?workspace.SessionId = null,
    second: ?workspace.SessionId = null,
    failed: bool = false,
};

const PerformanceSnapshot = struct {
    terminal: terminal.TerminalModel.Diagnostics,
    cache: render_commands.RenderCache.Diagnostics,
    renderer: renderer.Renderer.Diagnostics,
    output_trace: frame_trace.Stats,
    paint_trace: frame_trace.Stats,
    cache_trace: frame_trace.Stats,
    queue_delay_trace: frame_trace.Stats,
    frame_delay_trace: frame_trace.Stats,
    output_to_present_trace: frame_trace.Stats,
    resize_messages: u64,
    bytes_read: u64,
    bytes_parsed: u64,
    maximum_backlog: u64,
    continuation_count: u64,
    maximum_ui_batch: u64,
};

const Application = struct {
    allocator: std.mem.Allocator,
    model: workspace.Application,
    /// This message-only HWND outlives every terminal session. ConPTY workers
    /// post stable SessionId tokens here; it resolves their current WindowId.
    notification_window: ?foundation.HWND = null,
    retirement_event: ?foundation.HANDLE = null,
    retirement_manager: ?*retirement.Manager = null,
    windows: std.ArrayListUnmanaged(*WindowState) = .empty,
    mode: Mode,
    paint_completed: bool = false,
    integration_succeeded: bool = false,
    integration_resize_requested: bool = false,
    integration_resize_target: geometry.Dimensions = .{ .columns = 1, .rows = 1 },
    integration_multi_session: MultiSessionIntegration = .{},
    final_window_destroyed_while_retiring: bool = false,
    tab_drag: TabDragCoordinator = .idle,
    tab_drag_diagnostics: TabDragDiagnostics = .{},
    suppress_drag_escape_character: bool = false,

    fn init(allocator: std.mem.Allocator, mode: Mode) Application {
        return .{ .allocator = allocator, .model = .init(allocator), .mode = mode };
    }

    fn deinit(self: *Application) void {
        if (self.retirement_manager) |manager| {
            manager.deinit();
            self.allocator.destroy(manager);
        }
        if (self.retirement_event) |event| _ = kernel32.CloseHandle(event);
        for (self.windows.items) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
        self.windows.deinit(self.allocator);
        self.model.deinit();
        self.* = undefined;
    }

    fn startRetirement(self: *Application) !void {
        const event = kernel32.CreateEventW(null, 1, 0, null) orelse
            return error.CreateRetirementCompletionEventFailed;
        errdefer _ = kernel32.CloseHandle(event);
        const manager = try self.allocator.create(retirement.Manager);
        errdefer self.allocator.destroy(manager);
        try manager.init(self.allocator, event);
        self.retirement_manager = manager;
        self.retirement_event = event;
    }

    fn retirementPending(self: *Application) usize {
        return if (self.retirement_manager) |manager| manager.pendingCount() else 0;
    }

    fn stateForWindow(self: *Application, hwnd: foundation.HWND) ?*WindowState {
        for (self.windows.items) |state| if (state.hwnd == hwnd) return state;
        return null;
    }

    fn stateForId(self: *Application, id: workspace.WindowId) ?*WindowState {
        for (self.windows.items) |state| if (state.model_window.id == id) return state;
        return null;
    }

    fn stateForSession(self: *Application, id: workspace.SessionId) ?*WindowState {
        const owner = self.model.sessionOwner(id) orelse return null;
        const window_id = switch (owner) {
            .attached, .transferring => |value| value,
            .retiring => return null,
        };
        for (self.windows.items) |state| {
            if (state.model_window.id == window_id and state.model_window.lifecycle == .live)
                return state;
        }
        return null;
    }

    fn liveWindowCount(self: *const Application) usize {
        var count: usize = 0;
        for (self.windows.items) |state| {
            if (state.model_window.lifecycle == .live) count += 1;
        }
        return count;
    }
};

const WindowState = struct {
    application: *Application,
    model_window: *workspace.Window,
    hwnd: ?foundation.HWND = null,
    tab_control: ?foundation.HWND = null,
    active_model: ?*terminal.TerminalModel = null,
    input_translator: input.Translator = .{},
    shortcut_state: ShortcutState = .{},
    test_modifiers: ?input.Mods = null,
    test_context_menu_command: ?usize = null,
    rename_editor: ?RenameEditor = null,
    terminal_metrics: geometry.Metrics = .forDpi(geometry.base_dpi),
    dpi: u32 = geometry.base_dpi,
    selection_dragging: bool = false,
    selection_anchor: ?terminal.Cursor = null,
    selection_head: ?terminal.Cursor = null,
    pressed_mouse_button: ?input.MouseButton = null,
    wheel_scroll_accumulator: WheelScrollAccumulator = .{},
    held_viewport_shortcuts: std.EnumSet(ViewportShortcut) = .initEmpty(),
    renderer: renderer.Renderer = .{},
    render_cache: render_commands.RenderCache,
    output_trace: frame_trace.Counter = .{},
    paint_trace: frame_trace.Counter = .{},
    cache_trace: frame_trace.Counter = .{},
    frame_message_pending: bool = false,
    renderer_failure_queued: bool = false,
    renderer_failure: ?anyerror = null,
    resize_message_count: u64 = 0,
    queue_delay_trace: frame_trace.Counter = .{},
    frame_delay_trace: frame_trace.Counter = .{},
    output_to_present_trace: frame_trace.Counter = .{},
    frame_request_timestamp: i64 = 0,
    oldest_pending_output_timestamp: i64 = 0,
    bytes_read: u64 = 0,
    bytes_parsed: u64 = 0,
    maximum_backlog: u64 = 0,
    continuation_count: u64 = 0,
    maximum_ui_batch: u64 = 0,
    performance_snapshot: ?PerformanceSnapshot = null,
    auto_close_on_paint: bool = true,

    fn init(application: *Application, model_window: *workspace.Window) WindowState {
        return .{
            .application = application,
            .model_window = model_window,
            .render_cache = .init(application.allocator),
        };
    }

    fn deinit(self: *WindowState) void {
        self.renderer.deinit();
        self.render_cache.deinit();
    }

    fn ownedWorkspace(self: *WindowState) *workspace.Workspace {
        return &self.model_window.workspace;
    }

    fn model(self: *WindowState) ?*terminal.TerminalModel {
        return self.active_model;
    }
};

/// Compatibility helpers still use these views while the callback conversion
/// is completed.  Bind them at every HWND boundary, rather than letting one
/// top-level window's presentation state leak into another.
fn bindWindowState(state: *WindowState) void {
    workspace_state = state.ownedWorkspace();
    model = state.active_model orelse if (workspace_state.activeSession()) |session| &session.model else undefined;
    model_initialized = state.active_model != null;
    tab_control = state.tab_control;
    app_window = state.hwnd;
    input_translator = &state.input_translator;
    shortcut_state = &state.shortcut_state;
    test_modifiers = state.test_modifiers;
    test_context_menu_command = state.test_context_menu_command;
    rename_editor = state.rename_editor;
    terminal_metrics = &state.terminal_metrics;
    selection_dragging = state.selection_dragging;
    selection_anchor = state.selection_anchor;
    selection_head = state.selection_head;
    pressed_mouse_button = state.pressed_mouse_button;
    wheel_scroll_accumulator = state.wheel_scroll_accumulator;
    held_viewport_shortcuts = state.held_viewport_shortcuts;
    active_renderer = &state.renderer;
    render_cache = &state.render_cache;
    render_cache_initialized = true;
    output_trace = state.output_trace;
    paint_trace = state.paint_trace;
    cache_trace = state.cache_trace;
    frame_message_pending = state.frame_message_pending;
    renderer_failure_queued = state.renderer_failure_queued;
    renderer_failure = state.renderer_failure;
    resize_message_count = state.resize_message_count;
}

fn storeWindowState(state: *WindowState) void {
    state.active_model = if (model_initialized) model else null;
    state.tab_control = tab_control;
    state.hwnd = app_window;
    state.test_modifiers = test_modifiers;
    state.test_context_menu_command = test_context_menu_command;
    state.rename_editor = rename_editor;
    state.selection_dragging = selection_dragging;
    state.selection_anchor = selection_anchor;
    state.selection_head = selection_head;
    state.pressed_mouse_button = pressed_mouse_button;
    state.wheel_scroll_accumulator = wheel_scroll_accumulator;
    state.held_viewport_shortcuts = held_viewport_shortcuts;
    state.output_trace = output_trace;
    state.paint_trace = paint_trace;
    state.cache_trace = cache_trace;
    state.frame_message_pending = frame_message_pending;
    state.renderer_failure_queued = renderer_failure_queued;
    state.renderer_failure = renderer_failure;
    state.resize_message_count = resize_message_count;
}

pub fn run(mode: Mode) !void {
    const allocator = std.heap.smp_allocator;
    var application = Application.init(allocator, mode);
    try application.startRetirement();
    active_application = &application;
    defer {
        active_application = null;
        application.deinit();
    }
    const model_window = try application.model.createWindow();
    const state = try allocator.create(WindowState);
    state.* = .init(&application, model_window);
    try application.windows.append(allocator, state);
    const initial_tab = try state.ownedWorkspace().createTab(24, 80);
    try application.model.routeTab(model_window.id, state.ownedWorkspace().tab(initial_tab).?);
    if (mode == .smoke_tabs) {
        const second_tab = try state.ownedWorkspace().createTab(24, 80);
        try application.model.routeTab(model_window.id, state.ownedWorkspace().tab(second_tab).?);
    }
    state.active_model = &state.ownedWorkspace().activeSession().?.model;
    workspace_state = state.ownedWorkspace();
    model = state.active_model.?;
    model_initialized = true;
    active_mode = mode;
    paint_completed = false;
    integration_succeeded = false;
    integration_resize_requested = false;
    integration_resize_target = .{ .columns = 1, .rows = 1 };
    integration_multi_session = .{};
    notification_window = null;
    tab_control = null;
    app_window = null;
    input_translator = &state.input_translator;
    shortcut_state = &state.shortcut_state;
    test_modifiers = null;
    test_context_menu_command = null;
    rename_editor = null;
    terminal_metrics = &state.terminal_metrics;
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    pressed_mouse_button = null;
    active_renderer = &state.renderer;
    render_cache = &state.render_cache;
    render_cache_initialized = true;
    output_trace = .{};
    paint_trace = .{};
    cache_trace = .{};
    frame_message_pending = false;
    renderer_failure_queued = false;
    renderer_failure = null;
    resize_message_count = 0;
    defer {
        render_cache_initialized = false;
        model_initialized = false;
    }
    defer logDebugCounters();
    if (isSmokeMode(mode))
        try state.model().?.write("\x1b[38;2;126;231;135mHello from libghostty.\x1b[0m");

    const instance = kernel32.GetModuleHandleW(null) orelse
        return error.GetModuleHandleFailed;
    const common_controls: controls.INITCOMMONCONTROLSEX = .{
        .dwSize = @sizeOf(controls.INITCOMMONCONTROLSEX),
        .dwICC = controls.ICC_TAB_CLASSES,
    };
    if (comctl32.InitCommonControlsEx(&common_controls) == 0)
        return error.InitCommonControlsFailed;

    if (!dpi_awareness_configured) {
        if (user32.SetProcessDpiAwarenessContext(
            hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        ) == 0) return error.SetProcessDpiAwarenessContextFailed;
        dpi_awareness_configured = true;
    }

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

    const receiver = user32.CreateWindowExW(
        .{},
        class_name,
        null,
        .{},
        0,
        0,
        0,
        0,
        wm.HWND_MESSAGE,
        null,
        instance,
        null,
    ) orelse return error.CreateNotificationWindowFailed;
    application.notification_window = receiver;
    notification_window = receiver;
    defer {
        application.notification_window = null;
        if (user32.IsWindow(receiver) != 0) _ = user32.DestroyWindow(receiver);
    }

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
        state,
    ) orelse return error.CreateWindowFailed;
    defer if (user32.IsWindow(window) != 0) {
        _ = user32.DestroyWindow(window);
    };
    state.hwnd = window;
    state.tab_control = try createTabControl(instance, window);
    app_window = window;
    tab_control = state.tab_control;
    if (comctl32.SetWindowSubclass(state.tab_control, tabControlProc, 1, @intFromPtr(state)) == 0)
        return error.SubclassTabControlFailed;
    try syncNativeTabs();
    try initializeRenderer(window, active_renderer);
    const cursor_timer = user32.SetTimer(window, cursor_timer_id, 500, null);
    defer {
        if (cursor_timer != 0) _ = user32.KillTimer(window, cursor_timer);
    }

    terminal_metrics.* = active_renderer.metricsForDpi(user32.GetDpiForWindow(window));
    state.dpi = user32.GetDpiForWindow(window);
    try resizeForClient(window);
    if (!application.model.markLive(model_window.id)) return error.WindowDidNotBecomeLive;
    if (mode == .smoke_multi_window) {
        try verifyIndependentNativeWindows(state, window);
    }
    if (mode == .smoke_transfer_hardening) try verifyTransferHardening(state, instance);
    if (mode == .smoke_tabs) try verifyNativeTabControl(window);
    if (mode == .smoke_shortcuts) try verifyShortcutDispatch(window);
    if (mode == .smoke_rename) try verifyInlineRename(window);
    if (mode == .smoke_tab_interactions) try verifyTabInteractions(window);
    if (mode == .smoke_tab_drag) try verifyTabDragReordering(window);
    if (mode == .smoke_cross_window_drag) try verifyCrossWindowTabDrag(state, instance);

    var integration_resize_command: ?[]u8 = null;
    defer if (integration_resize_command) |command| allocator.free(command);
    if (mode == .integration_resize) {
        application.integration_resize_target = .{
            .columns = state.model().?.columns() +| 7,
            .rows = state.model().?.rows() +| 3,
        };
        integration_resize_target = application.integration_resize_target;
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
                application.integration_resize_target.columns,
                application.integration_resize_target.rows,
            },
        );
        defer allocator.free(script);
        integration_resize_command = try encodedPowerShellCommand(allocator, script);
    }

    if (!isSmokeMode(mode)) {
        const process = try conpty.Session.create(
            allocator,
            receiver,
            @intFromEnum(state.ownedWorkspace().activeSession().?.id),
            .{ .columns = state.model().?.columns(), .rows = state.model().?.rows() },
            switch (mode) {
                .integration => integration_command,
                .integration_input => integration_input_command,
                .integration_resize => integration_resize_command.?,
                .integration_multi_session, .integration_multi_resize => integration_multi_first_command,
                .integration_host_close, .integration_final_retirement => integration_host_close_command,
                else => null,
            },
        );
        state.ownedWorkspace().activeSession().?.attachProcess(.{
            .context = process,
            .destroy = destroyConptyProcess,
        }) catch |err| {
            process.destroy();
            return err;
        };
        state.model().?.setReplySink(.{
            .context = process,
            .write = queueTerminalReply,
        });
        if (mode == .integration_input) try queueIntegrationInput();
        if (isMultiSessionIntegrationMode(mode)) {
            application.integration_multi_session.first = state.ownedWorkspace().activeSession().?.id;
            integration_multi_session.first = application.integration_multi_session.first;
            try createIntegrationTerminalTab(window, integration_multi_second_command);
            application.integration_multi_session.second = state.ownedWorkspace().activeSession().?.id;
            integration_multi_session.second = application.integration_multi_session.second;
            if (mode == .integration_multi_resize)
                try verifyMultiSessionResizeAndDpi(window);
        }
        if (mode == .integration_host_close)
            try exerciseStaleSessionNotifications(window);
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
    if (mode == .integration_host_close or mode == .integration_final_retirement)
        _ = user32.PostMessageW(window, wm.WM_CLOSE, 0, 0);
    if (mode == .integration_final_retirement)
        user32.PostQuitMessage(0);

    var message: wm.MSG = undefined;
    var quit_requested = false;
    while (true) {
        if (application.liveWindowCount() == 0 and application.retirementPending() == 0)
            break;
        const event = application.retirement_event orelse return error.RetirementEventUnavailable;
        const handles = [_]?foundation.HANDLE{event};
        const result = user32.MsgWaitForMultipleObjectsEx(
            handles.len,
            &handles,
            std.math.maxInt(u32),
            wm.QS_ALLINPUT,
            wm.MWMO_INPUTAVAILABLE,
        );
        if (result == @intFromEnum(foundation.WAIT_OBJECT_0)) {
            _ = kernel32.ResetEvent(event);
            continue;
        }
        if (result != @intFromEnum(foundation.WAIT_OBJECT_0) + handles.len)
            return error.MessageWaitFailed;
        while (user32.PeekMessageW(&message, null, 0, 0, wm.PM_REMOVE) != 0) {
            if (message.message == wm.WM_QUIT) {
                // A WM_QUIT can be posted by external code while sessions
                // still own notification-posting workers. Preserve the
                // dispatcher until the explicit retirement gate is satisfied.
                quit_requested = true;
                break;
            }
            _ = user32.TranslateMessage(&message);
            _ = user32.DispatchMessageW(&message);
        }
        if (quit_requested) continue;
    }

    if (isSmokeMode(mode) and !paint_completed) return error.SmokePaintFailed;
    if (isIntegrationMode(mode) and !integration_succeeded)
        return error.ConptyIntegrationFailed;
    if (mode == .integration_final_retirement and
        !application.final_window_destroyed_while_retiring)
        return error.FinalWindowWasNotDestroyedBeforeRetirementCompleted;
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

fn createVisibleWindow(application: *Application, instance: foundation.HINSTANCE) !*WindowState {
    // A new native window synchronously receives creation, sizing, and focus
    // callbacks. Those callbacks bind the compatibility view to the new
    // WindowState. When this is invoked from a command handled by an existing
    // window, restore that caller before returning: its outer callback will
    // persist the compatibility view after the command completes.
    const caller = if (app_window) |window| windowStateFromHwnd(window) else null;
    defer if (caller) |state| bindWindowState(state);

    const model_window = try application.model.createWindow();
    const state = try application.allocator.create(WindowState);
    errdefer application.allocator.destroy(state);
    state.* = .init(application, model_window);
    state.auto_close_on_paint = false;
    try application.windows.append(application.allocator, state);

    var style = wm.WS_OVERLAPPEDWINDOW;
    style.CLIPCHILDREN = 1;
    const window = user32.CreateWindowExW(
        .{},
        class_name,
        window_title,
        style,
        wm.CW_USEDEFAULT,
        wm.CW_USEDEFAULT,
        900,
        560,
        null,
        null,
        instance,
        state,
    ) orelse return error.CreateWindowFailed;
    errdefer {
        if (user32.IsWindow(window) != 0) _ = user32.DestroyWindow(window);
    }

    state.hwnd = window;
    state.tab_control = try createTabControl(instance, window);
    if (comctl32.SetWindowSubclass(state.tab_control, tabControlProc, 1, @intFromPtr(state)) == 0)
        return error.SubclassTabControlFailed;
    bindWindowState(state);
    try initializeRenderer(window, &state.renderer);
    state.terminal_metrics = state.renderer.metricsForDpi(user32.GetDpiForWindow(window));
    state.dpi = user32.GetDpiForWindow(window);
    _ = user32.SetTimer(window, cursor_timer_id, 500, null);
    try createTerminalTab(window);
    state.active_model = &state.ownedWorkspace().activeSession().?.model;
    // Native tab creation can synchronously reenter the callback before the
    // active model exists. Rebind after assigning it so the persisted view is
    // never overwritten with that transient empty state.
    bindWindowState(state);
    try resizeForClient(window);
    if (!application.model.markLive(model_window.id)) return error.WindowDidNotBecomeLive;
    storeWindowState(state);
    _ = user32.ShowWindow(window, if (active_mode == .normal) wm.SW_SHOWDEFAULT else wm.SW_HIDE);
    _ = user32.UpdateWindow(window);
    return state;
}

/// Exercise Ctrl+Shift+N through the parent window procedure. Creating the
/// second HWND sends nested messages, so this specifically guards the point at
/// which an outer callback would otherwise store the child's compatibility
/// view into the source WindowState.
fn verifyIndependentNativeWindows(source: *WindowState, source_window: foundation.HWND) !void {
    bindWindowState(source);
    try createTerminalTab(source_window);
    try createTerminalTab(source_window);
    const source_active = source.active_model orelse return error.SourceWindowMissingActiveModel;
    const source_tabs = source.ownedWorkspace().tabs.items.len;
    if (source_tabs != 3) return error.SourceWindowTabSetupFailed;

    setTestModifiers(source_window, .{ .ctrl = true, .shift = true });
    defer setTestModifiers(source_window, null);
    _ = user32.SendMessageW(source_window, wm.WM_KEYDOWN, 'N', 1);
    _ = user32.SendMessageW(source_window, wm.WM_CHAR, 'n', 1);
    _ = user32.SendMessageW(source_window, wm.WM_KEYUP, 'N', @as(isize, 1) << 31);

    if (source.application.liveWindowCount() != 2)
        return error.NewWindowShortcutDidNotCreateSibling;
    const destination = source.application.windows.items[source.application.windows.items.len - 1];
    const destination_window = destination.hwnd orelse return error.SecondWindowMissingHandle;
    if (destination == source or destination.model_window == source.model_window)
        return error.NewWindowSharedWindowState;
    if (source.ownedWorkspace().tabs.items.len != source_tabs or
        source.active_model != source_active or
        source.model() != source_active)
        return error.NewWindowOverwroteSourcePresentation;
    if (destination.ownedWorkspace().tabs.items.len != 1 or
        destination.active_model != &destination.ownedWorkspace().activeSession().?.model)
        return error.NewWindowDidNotInitializeOwnPresentation;

    try verifyNativeTabPresentation(source);
    try verifyNativeTabPresentation(destination);
    try paintForTesting(source_window);
    try paintForTesting(destination_window);

    bindWindowState(destination);
    beginWindowClose(destination_window);
    if (source.model_window.lifecycle != .live or user32.IsWindow(source_window) == 0)
        return error.ClosingSecondWindowClosedFirst;
    bindWindowState(source);
    if (source.ownedWorkspace().tabs.items.len != source_tabs or source.active_model != source_active)
        return error.ClosingSiblingChangedSourcePresentation;
    try verifyNativeTabPresentation(source);
}

const RenameEditor = struct {
    window: foundation.HWND,
    tab_id: workspace.TabId,
};

const TabDragCandidate = struct {
    source_window_id: workspace.WindowId,
    tab_id: workspace.TabId,
    original_index: usize,
    anchor_screen: foundation.POINT,
    grab_offset_dip: foundation.POINT,
    source_client_width_dip: i32,
    source_client_height_dip: i32,
};

const TabHoverTarget = union(enum) {
    none,
    source: usize,
    window: struct { window_id: workspace.WindowId, insertion_index: usize },
    tear_out,
};

const TabDragActive = struct {
    candidate: TabDragCandidate,
    capture_hwnd: foundation.HWND,
    hover: TabHoverTarget = .none,
    local_order_changed: bool = false,
};

const TabDropRequest = union(enum) {
    reorder: struct { source_window_id: workspace.WindowId, tab_id: workspace.TabId, index: usize },
    transfer: struct {
        source_window_id: workspace.WindowId,
        tab_id: workspace.TabId,
        destination_window_id: workspace.WindowId,
        insertion_index: usize,
        original_index: usize,
    },
    tear_out: struct {
        source_window_id: workspace.WindowId,
        tab_id: workspace.TabId,
        original_index: usize,
        point: foundation.POINT,
        grab_offset_dip: foundation.POINT,
        source_client_width_dip: i32,
        source_client_height_dip: i32,
    },
};

const TabDragCoordinator = union(enum) {
    idle,
    candidate: TabDragCandidate,
    active: TabDragActive,
    finishing: struct {
        request: ?TabDropRequest,
        capture_hwnd: ?foundation.HWND = null,
    },
};

const TabDragDiagnostics = struct {
    candidates: u64 = 0,
    started: u64 = 0,
    canceled: u64 = 0,
    completed: u64 = 0,
    target_changes: u64 = 0,
    indexed_transfers: u64 = 0,
    tear_outs: u64 = 0,
    rollback_attempts: u64 = 0,
    rollback_failures: u64 = 0,
    stale_requests: u64 = 0,
};

fn beginRenameTab(id: workspace.TabId) !void {
    cancelTabDrag();
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
    // Creating and focusing the edit child can synchronously re-enter the tab
    // subclass. Persist this compatibility view before either operation so a
    // nested callback does not restore the previous null editor state.
    if (app_window) |window| {
        if (windowStateFromHwnd(window)) |state| state.rename_editor = rename_editor;
    }
    if (comctl32.SetWindowSubclass(editor, renameEditorProc, 1, 0) == 0) {
        rename_editor = null;
        if (app_window) |window| {
            if (windowStateFromHwnd(window)) |state| state.rename_editor = null;
        }
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
    // DestroyWindow and focus restoration can re-enter the tab callback. Keep
    // the owning WindowState in sync before that reentrancy observes it.
    if (app_window) |window| {
        if (windowStateFromHwnd(window)) |state| state.rename_editor = null;
    }
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
    reference_data: usize,
) callconv(.winapi) isize {
    if (reference_data != 0) {
        const state: *WindowState = @ptrFromInt(reference_data);
        bindWindowState(state);
        defer storeWindowState(state);
        if (state.model_window.lifecycle == .closing or state.model_window.lifecycle == .destroyed)
            return comctl32.DefSubclassProc(control, message, wparam, lparam);
    }
    if (message == wm.WM_LBUTTONDOWN) {
        const hwnd = control orelse return 0;
        const result = comctl32.DefSubclassProc(control, message, wparam, lparam);
        var hit: controls.TCHITTESTINFO = .{
            .pt = messagePoint(lparam),
            .flags = controls.TCHT_NOWHERE,
        };
        const index = user32.SendMessageW(hwnd, controls.TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
        if (index >= 0 and reference_data != 0) {
            const state: *WindowState = @ptrFromInt(reference_data);
            if (nativeTabIdAt(@intCast(index))) |id|
                beginTabDragCandidate(state, hwnd, id, @intCast(index), hit.pt)
            else
                cancelCandidateOrActiveDrag(state.application);
        } else if (reference_data != 0) {
            const state: *WindowState = @ptrFromInt(reference_data);
            cancelCandidateOrActiveDrag(state.application);
        }
        return result;
    }
    if (message == wm.WM_MOUSEMOVE) {
        if (reference_data != 0) {
            const state: *WindowState = @ptrFromInt(reference_data);
            updateApplicationTabDrag(state.application, state, messagePoint(lparam), wparam);
        }
        return comctl32.DefSubclassProc(control, message, wparam, lparam);
    }
    if (message == wm.WM_PAINT) {
        const result = comctl32.DefSubclassProc(control, message, wparam, lparam);
        if (reference_data != 0) {
            const state: *WindowState = @ptrFromInt(reference_data);
            drawTabInsertionMarker(state.application, state);
        }
        return result;
    }
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
        if (reference_data != 0) {
            const state: *WindowState = @ptrFromInt(reference_data);
            finishApplicationTabDrag(state.application, state, messagePoint(lparam));
        }
        const result = comctl32.DefSubclassProc(control, message, wparam, lparam);
        releaseFinishedTabCapture();
        if (app_window) |window| _ = user32.SetFocus(window);
        return result;
    }
    if (message == wm.WM_KEYDOWN and wparam == 0x1b and reference_data != 0) {
        const state: *WindowState = @ptrFromInt(reference_data);
        cancelApplicationTabDrag(state.application, true);
        return 0;
    }
    if (message == wm.WM_CANCELMODE and reference_data != 0) {
        const state: *WindowState = @ptrFromInt(reference_data);
        cancelApplicationTabDrag(state.application, true);
        return comctl32.DefSubclassProc(control, message, wparam, lparam);
    }
    if (message == wm.WM_CAPTURECHANGED and reference_data != 0) {
        const state: *WindowState = @ptrFromInt(reference_data);
        switch (state.application.tab_drag) {
            .active => cancelApplicationTabDrag(state.application, false),
            else => {},
        }
        return comctl32.DefSubclassProc(control, message, wparam, lparam);
    }
    if (message == wm.WM_NCDESTROY and reference_data != 0) {
        const state: *WindowState = @ptrFromInt(reference_data);
        cancelDragIfSource(state.application, state.model_window.id);
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
    if (user32.AppendMenuW(menu, wm.MF_STRING, context_menu_new_window, context_menu_new_window_label) == 0)
        return error.AppendContextMenuItemFailed;
    if (user32.AppendMenuW(menu, wm.MF_STRING, context_menu_rename_tab, context_menu_rename_tab_label) == 0)
        return error.AppendContextMenuItemFailed;
    if (user32.AppendMenuW(
        menu,
        wm.MF_STRING,
        context_menu_move_tab_to_new_window,
        context_menu_move_tab_to_new_window_label,
    ) == 0) return error.AppendContextMenuItemFailed;

    var destinations: std.ArrayListUnmanaged(workspace.WindowId) = .empty;
    defer destinations.deinit(std.heap.smp_allocator);
    try appendMoveDestinations(&destinations, windowStateFromHwnd(window) orelse return error.WindowStateUnavailable);
    if (destinations.items.len != 0) {
        const move_menu = user32.CreatePopupMenu() orelse return error.CreateContextMenuFailed;
        for (destinations.items, 0..) |destination_id, index| {
            var label_buffer: [512]u8 = undefined;
            const label = try destinationMenuLabel(
                (windowStateFromHwnd(window) orelse return error.WindowStateUnavailable).application,
                destination_id,
                &label_buffer,
            );
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, label);
            defer std.heap.smp_allocator.free(wide);
            if (user32.AppendMenuW(
                move_menu,
                wm.MF_STRING,
                context_menu_move_tab_to_window_first + index,
                wide.ptr,
            ) == 0) return error.AppendContextMenuItemFailed;
        }
        if (user32.AppendMenuW(
            menu,
            wm.MF_POPUP,
            @intFromPtr(move_menu),
            context_menu_move_tab_to_window_label,
        ) == 0) return error.AppendContextMenuItemFailed;

        // The submenu is now owned by the parent menu and is released with it.
    }
    if (user32.AppendMenuW(menu, wm.MF_SEPARATOR, 0, null) == 0)
        return error.AppendContextMenuItemFailed;
    if (user32.AppendMenuW(menu, wm.MF_STRING, context_menu_close_tab, context_menu_close_tab_label) == 0)
        return error.AppendContextMenuItemFailed;
    if (test_context_menu_command) |command| {
        if (command >= context_menu_move_tab_to_window_first) {
            const index = command - context_menu_move_tab_to_window_first;
            if (index < destinations.items.len)
                try moveTabToWindow(
                    windowStateFromHwnd(window) orelse return error.WindowStateUnavailable,
                    id,
                    destinations.items[index],
                );
        } else {
            _ = user32.SendMessageW(window, wm.WM_COMMAND, command, 0);
        }
        return;
    }
    _ = user32.SetForegroundWindow(window);
    var flags = wm.TPM_RIGHTBUTTON;
    flags.RETURNCMD = 1;
    const command: usize = @intCast(user32.TrackPopupMenuEx(menu, @bitCast(flags), point.x, point.y, window, null));
    if (command >= context_menu_move_tab_to_window_first) {
        const index = command - context_menu_move_tab_to_window_first;
        if (index < destinations.items.len)
            moveTabToWindow(windowStateFromHwnd(window) orelse return, id, destinations.items[index]) catch |err|
                std.log.err("failed to move terminal tab to selected window: {}", .{err});
    } else if (command != 0) {
        _ = handleContextMenuCommand(window, command);
    }
}

/// Capture stable application identities before entering the native menu loop.
/// HWNDs may disappear or be reused while TrackPopupMenuEx dispatches messages.
fn appendMoveDestinations(
    destinations: *std.ArrayListUnmanaged(workspace.WindowId),
    source: *WindowState,
) !void {
    const application = source.application;
    for (application.windows.items) |candidate| {
        if (candidate == source or candidate.model_window.lifecycle != .live) continue;
        try destinations.append(std.heap.smp_allocator, candidate.model_window.id);
    }
}

/// Captions make the list recognizable while the ordinal makes duplicates
/// deterministic. The ID behind the command remains the sole identity.
fn destinationMenuLabel(
    application: *Application,
    destination_id: workspace.WindowId,
    buffer: []u8,
) ![]const u8 {
    const destination = application.model.window(destination_id) orelse return error.UnknownDestinationWindow;
    const label = if (destination.workspace.activeTab()) |tab| tab.effectiveLabel() else "Terminal";
    var ordinal: usize = 0;
    for (application.windows.items) |candidate| {
        if (candidate.model_window.lifecycle != .live) continue;
        const candidate_label = if (candidate.ownedWorkspace().activeTab()) |tab| tab.effectiveLabel() else "Terminal";
        if (!std.mem.eql(u8, candidate_label, label)) continue;
        ordinal += 1;
        if (candidate.model_window.id == destination_id) break;
    }
    return std.fmt.bufPrint(buffer, "{s} ({d})", .{ label, ordinal });
}

fn handleContextMenuCommand(window: foundation.HWND, command: usize) bool {
    switch (command) {
        context_menu_new_tab => createTerminalTab(window) catch |err|
            std.log.err("failed to create terminal tab from context menu: {}", .{err}),
        context_menu_new_window => createNewWindow() catch |err|
            std.log.err("failed to create terminal window from context menu: {}", .{err}),
        context_menu_move_tab_to_new_window => if (workspace_state.active_tab_id) |id|
            moveTabToNewWindow(windowStateFromHwnd(window) orelse return false, id) catch |err|
                std.log.err("failed to move terminal tab to a new window: {}", .{err}),
        context_menu_rename_tab => if (workspace_state.active_tab_id) |id|
            beginRenameTab(id) catch |err|
                std.log.err("failed to rename terminal tab from context menu: {}", .{err}),
        context_menu_close_tab => if (workspace_state.active_tab_id) |id|
            closeTerminalTab(window, id),
        else => return false,
    }
    return true;
}

fn createNewWindow() !void {
    const application = active_application orelse return error.ApplicationUnavailable;
    const instance = kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    _ = try createVisibleWindow(application, instance);
}

/// Creates the complete native receiver required by a transfer, but leaves it
/// hidden and empty until the allocation-free model commit succeeds.
const TearOutPlacement = struct {
    point: foundation.POINT,
    grab_offset_dip: foundation.POINT,
    client_width_dip: i32,
    client_height_dip: i32,
};

fn createTransferDestination(
    application: *Application,
    instance: foundation.HINSTANCE,
    placement: ?TearOutPlacement,
) !*WindowState {
    const model_window = try application.model.createWindow();
    errdefer _ = application.model.discardConstructingWindow(model_window.id);
    const state = try application.allocator.create(WindowState);
    errdefer application.allocator.destroy(state);
    state.* = .init(application, model_window);
    state.auto_close_on_paint = false;
    try application.windows.append(application.allocator, state);
    errdefer {
        for (application.windows.items, 0..) |candidate, index| {
            if (candidate == state) {
                _ = application.windows.orderedRemove(index);
                break;
            }
        }
        state.deinit();
    }

    var style = wm.WS_OVERLAPPEDWINDOW;
    style.CLIPCHILDREN = 1;
    const window = user32.CreateWindowExW(
        .{},
        class_name,
        window_title,
        style,
        if (placement) |value| value.point.x else wm.CW_USEDEFAULT,
        if (placement) |value| value.point.y else wm.CW_USEDEFAULT,
        900,
        560,
        null,
        null,
        instance,
        state,
    ) orelse return error.CreateWindowFailed;
    errdefer {
        if (user32.IsWindow(window) != 0) _ = user32.DestroyWindow(window);
    }

    state.hwnd = window;
    state.tab_control = try createTabControl(instance, window);
    if (comctl32.SetWindowSubclass(state.tab_control, tabControlProc, 1, @intFromPtr(state)) == 0)
        return error.SubclassTabControlFailed;
    bindWindowState(state);
    try initializeRenderer(window, &state.renderer);
    state.terminal_metrics = state.renderer.metricsForDpi(user32.GetDpiForWindow(window));
    state.dpi = user32.GetDpiForWindow(window);
    if (placement) |value| try positionTearOutWindow(window, style, value);
    _ = user32.SetTimer(window, cursor_timer_id, 500, null);
    if (!application.model.markLive(model_window.id)) return error.WindowDidNotBecomeLive;
    storeWindowState(state);
    return state;
}

fn positionTearOutWindow(
    window: foundation.HWND,
    style: wm.WINDOW_STYLE,
    placement: TearOutPlacement,
) !void {
    const dpi = @max(user32.GetDpiForWindow(window), geometry.base_dpi);
    var outer: foundation.RECT = .{
        .left = 0,
        .top = 0,
        .right = @max(tab_drag_geometry.scale(placement.client_width_dip, geometry.base_dpi, dpi), 1),
        .bottom = @max(tab_drag_geometry.scale(placement.client_height_dip, geometry.base_dpi, dpi), 1),
    };
    if (user32.AdjustWindowRectExForDpi(&outer, style, 0, .{}, dpi) == 0)
        return error.AdjustTearOutWindowRectFailed;
    const width = outer.right - outer.left;
    const height = outer.bottom - outer.top;
    const grab_x = tab_drag_geometry.scale(placement.grab_offset_dip.x, geometry.base_dpi, dpi);
    const desired: tab_drag_geometry.Rect = .{
        .left = placement.point.x - grab_x,
        .top = placement.point.y - @max(tab_drag_geometry.scale(16, geometry.base_dpi, dpi), 1),
        .right = placement.point.x - grab_x + width,
        .bottom = placement.point.y - @max(tab_drag_geometry.scale(16, geometry.base_dpi, dpi), 1) + height,
    };
    const monitor = user32.MonitorFromPoint(placement.point, gdi.MONITOR_DEFAULTTONEAREST) orelse
        return error.MonitorForTearOutUnavailable;
    var info: gdi.MONITORINFO = .{
        .cbSize = @sizeOf(gdi.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (user32.GetMonitorInfoW(monitor, &info) == 0) return error.GetTearOutMonitorInfoFailed;
    const bounded = tab_drag_geometry.clampToWorkArea(
        desired,
        dragRect(info.rcWork),
        tab_drag_geometry.scale(120, geometry.base_dpi, dpi),
        tab_drag_geometry.scale(48, geometry.base_dpi, dpi),
    );
    if (user32.SetWindowPos(
        window,
        null,
        bounded.left,
        bounded.top,
        bounded.right - bounded.left,
        bounded.bottom - bounded.top,
        .{ .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) return error.PositionTearOutWindowFailed;
}

fn moveTabToNewWindow(source: *WindowState, id: workspace.TabId) !void {
    const instance = kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    const destination = try createTransferDestination(source.application, instance, null);
    moveTabToState(source, id, destination, 0, true) catch |err| {
        if (destination.hwnd) |window| beginWindowClose(window);
        return err;
    };
}

/// Resolve the destination by its stable ID immediately before transfer. A
/// destination which was closed while its menu was open is a harmless no-op.
fn moveTabToWindow(source: *WindowState, id: workspace.TabId, destination_id: workspace.WindowId) !void {
    const destination = source.application.model.window(destination_id) orelse return;
    if (destination.lifecycle != .live) return;
    const destination_state = blk: {
        for (source.application.windows.items) |candidate|
            if (candidate.model_window == destination) break :blk candidate;
        return;
    };
    try moveTabToState(source, id, destination_state, destination_state.ownedWorkspace().tabs.items.len, true);
}

fn moveTabToState(
    source: *WindowState,
    id: workspace.TabId,
    destination: *WindowState,
    destination_index: usize,
    activate: bool,
) !void {
    if (source == destination) return;
    const source_window = source.hwnd orelse return error.SourceWindowUnavailable;
    const destination_window = destination.hwnd orelse return error.DestinationWindowUnavailable;
    var transaction = try source.application.model.prepareTransfer(
        source.model_window.id,
        destination.model_window.id,
        id,
        destination_index,
    );
    defer transaction.deinit();

    // No native call occurs between commit's lifecycle guards and restored
    // ownership. Presentation is rebuilt only after the stable identities are
    // routed to their new window.
    _ = transaction.commit();
    refreshTransferredPresentation(destination, destination_window) catch |err|
        std.log.err("failed to refresh destination after committed tab transfer: {}", .{err});
    if (source.ownedWorkspace().activeTab() != null) {
        refreshTransferredPresentation(source, source_window) catch |err|
            std.log.err("failed to refresh source after committed tab transfer: {}", .{err});
    } else {
        bindWindowState(source);
        beginWindowClose(source_window);
    }

    if (activate) {
        if (user32.IsIconic(destination_window) != 0)
            _ = user32.ShowWindow(destination_window, wm.SW_RESTORE)
        else
            _ = user32.ShowWindow(destination_window, wm.SW_SHOW);
        _ = user32.SetForegroundWindow(destination_window);
        _ = user32.SetFocus(destination_window);
    }
}

fn processPendingTabDrop(application: *Application) void {
    const request = switch (application.tab_drag) {
        .finishing => |*finishing| blk: {
            const value = finishing.request orelse {
                application.tab_drag = .idle;
                return;
            };
            finishing.request = null;
            break :blk value;
        },
        else => {
            application.tab_drag_diagnostics.stale_requests +|= 1;
            return;
        },
    };
    application.tab_drag = .idle;

    switch (request) {
        .reorder => |value| {
            const source = application.stateForId(value.source_window_id) orelse return staleTabDrop(application);
            if (source.model_window.lifecycle != .live or
                source.ownedWorkspace().indexOfTab(value.tab_id) != value.index)
                return staleTabDrop(application);
            if (source.hwnd) |window| _ = user32.SetFocus(window);
            application.tab_drag_diagnostics.completed +|= 1;
        },
        .transfer => |value| {
            const source = application.stateForId(value.source_window_id) orelse return staleTabDrop(application);
            const destination = application.stateForId(value.destination_window_id) orelse {
                rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index);
                return staleTabDrop(application);
            };
            if (source.model_window.lifecycle != .live or destination.model_window.lifecycle != .live or
                source.ownedWorkspace().tab(value.tab_id) == null or
                value.insertion_index > destination.ownedWorkspace().tabs.items.len)
            {
                rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index);
                return staleTabDrop(application);
            }
            moveTabToState(source, value.tab_id, destination, value.insertion_index, true) catch |err| {
                std.log.err("cross-window tab drop failed before commit: {}", .{err});
                rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index);
                return;
            };
            application.tab_drag_diagnostics.indexed_transfers +|= 1;
            application.tab_drag_diagnostics.completed +|= 1;
        },
        .tear_out => |value| {
            const source = application.stateForId(value.source_window_id) orelse return staleTabDrop(application);
            if (source.model_window.lifecycle != .live or source.ownedWorkspace().tab(value.tab_id) == null)
                return staleTabDrop(application);
            const instance = kernel32.GetModuleHandleW(null) orelse {
                rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index);
                return;
            };
            const destination = createTransferDestination(application, instance, .{
                .point = value.point,
                .grab_offset_dip = value.grab_offset_dip,
                .client_width_dip = value.source_client_width_dip,
                .client_height_dip = value.source_client_height_dip,
            }) catch |err| {
                std.log.err("failed to construct tear-out window: {}", .{err});
                rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index);
                return;
            };
            moveTabToState(source, value.tab_id, destination, 0, true) catch |err| {
                std.log.err("tear-out transfer failed before commit: {}", .{err});
                if (destination.hwnd) |window| beginWindowClose(window);
                rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index);
                return;
            };
            application.tab_drag_diagnostics.tear_outs +|= 1;
            application.tab_drag_diagnostics.completed +|= 1;
        },
    }
}

fn staleTabDrop(application: *Application) void {
    application.tab_drag_diagnostics.stale_requests +|= 1;
}

fn refreshTransferredPresentation(state: *WindowState, window: foundation.HWND) !void {
    bindWindowState(state);
    const active = state.ownedWorkspace().activeSession() orelse return;
    model = &active.model;
    model_initialized = true;
    // Rebuilding native items synchronously re-enters the tab subclass. Keep
    // its durable view current before that callback binds and stores it.
    state.active_model = model;
    input_translator.* = .{};
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    pressed_mouse_button = null;
    try syncNativeTabs();
    model.markFullDamage();
    render_cache.deinit();
    render_cache.* = .init(std.heap.smp_allocator);
    active_renderer.invalidateTerminalContent();
    try resizeForClient(window);
    updateWindowCaption(window);
    invalidateRenderDamage(window);
    storeWindowState(state);
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
    notification_window: foundation.HWND,
    dimensions: geometry.Dimensions,
    command: ?[]const u8 = null,
};

fn startConptyTab(session: *workspace.TerminalSession, setup: *const ConptyTabSetup) !void {
    const process = try conpty.Session.create(
        std.heap.smp_allocator,
        setup.notification_window,
        @intFromEnum(session.id),
        setup.dimensions,
        setup.command,
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
    var setup: ConptyTabSetup = .{
        .notification_window = notification_window orelse return error.NotificationWindowUnavailable,
        .dimensions = dimensions,
    };
    const id = if (isSmokeMode(active_mode))
        try workspace_state.createTab(dimensions.rows, dimensions.columns)
    else
        try workspace_state.createTabWithSetup(
            dimensions.rows,
            dimensions.columns,
            &setup,
            startConptyTab,
        );
    if (windowStateFromHwnd(window)) |state|
        try state.application.model.routeTab(state.model_window.id, workspace_state.tab(id).?);
    try syncNativeTabs();
    try activateTab(window, id);
    updateWindowCaption(window);
    _ = user32.SetFocus(window);
}

fn createIntegrationTerminalTab(window: foundation.HWND, command: []const u8) !void {
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0) return error.GetClientRectFailed;
    const dimensions: geometry.Dimensions = terminal_metrics.dimensions(client.right - client.left, client.bottom - client.top) orelse
        .{ .columns = 80, .rows = 24 };
    var setup: ConptyTabSetup = .{
        .notification_window = notification_window orelse return error.NotificationWindowUnavailable,
        .dimensions = dimensions,
        .command = command,
    };
    const id = try workspace_state.createTabWithSetup(
        dimensions.rows,
        dimensions.columns,
        &setup,
        startConptyTab,
    );
    if (windowStateFromHwnd(window)) |state|
        try state.application.model.routeTab(state.model_window.id, workspace_state.tab(id).?);
    try syncNativeTabs();
    try activateTab(window, id);
}

fn closeTerminalTab(window: foundation.HWND, id: workspace.TabId) void {
    if (windowStateFromHwnd(window)) |state| {
        cancelDragIfSource(state.application, state.model_window.id);
        clearDragDestination(state.application, state.model_window.id);
    }
    if (rename_editor) |editor| if (editor.tab_id == id) cancelRename();
    const tab = workspace_state.tab(id) orelse return;
    retireTab(tab);
    _ = workspace_state.detachTab(id);
    if (workspace_state.activeTab()) |next| {
        model = &next.root.terminalSession().model;
        // Closing an active tab can also re-enter through resize/focus work
        // below. Do not allow that nested callback to restore the retired
        // tab's model from WindowState.
        if (windowStateFromHwnd(window)) |state| state.active_model = model;
        input_translator.* = .{};
        selection_dragging = false;
        syncNativeTabs() catch {};
        updateWindowCaption(window);
        model.markFullDamage();
        invalidateRenderDamage(window);
    } else {
        beginWindowClose(window);
    }
}

fn cancelTabDrag() void {
    const application = active_application orelse return;
    cancelApplicationTabDrag(application, true);
}

fn tabDragExceededThreshold(anchor: foundation.POINT, point: foundation.POINT) bool {
    return tab_drag_geometry.exceededThreshold(
        dragPoint(anchor),
        dragPoint(point),
        @max(user32.GetSystemMetrics(wm.SM_CXDRAG), 1),
        @max(user32.GetSystemMetrics(wm.SM_CYDRAG), 1),
    );
}

fn tabDragTargetSlot(control: foundation.HWND, point: foundation.POINT) ?usize {
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(control, &client) == 0) return null;
    if (!tab_drag_geometry.contains(dragRect(client), dragPoint(point))) return null;
    const count = user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0);
    if (count < 0) return null;
    if (count == 0) return 0;
    for (0..@as(usize, @intCast(count))) |index| {
        var bounds: foundation.RECT = undefined;
        if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, index, @bitCast(@intFromPtr(&bounds))) == 0)
            return null;
        const left = @max(bounds.left, client.left);
        const right = @min(bounds.right, client.right);
        if (right > left and point.x < left + @divTrunc(right - left, 2)) return index;
    }
    return @intCast(count);
}

fn dragPoint(point: foundation.POINT) tab_drag_geometry.Point {
    return .{ .x = point.x, .y = point.y };
}

fn dragRect(rect: foundation.RECT) tab_drag_geometry.Rect {
    return .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
}

fn screenRect(hwnd: foundation.HWND) ?foundation.RECT {
    var rect: foundation.RECT = undefined;
    if (user32.GetWindowRect(hwnd, &rect) == 0) return null;
    return rect;
}

fn dragThresholdFor(control: foundation.HWND) foundation.POINT {
    const dpi = @max(user32.GetDpiForWindow(control), geometry.base_dpi);
    return .{
        .x = @max(user32.GetSystemMetricsForDpi(wm.SM_CXDRAG, dpi), 1),
        .y = @max(user32.GetSystemMetricsForDpi(wm.SM_CYDRAG, dpi), 1),
    };
}

fn beginTabDragCandidate(
    state: *WindowState,
    control: foundation.HWND,
    id: workspace.TabId,
    index: usize,
    client_point: foundation.POINT,
) void {
    const application = state.application;
    switch (application.tab_drag) {
        .idle => {},
        else => return,
    }
    if (state.model_window.lifecycle != .live or state.rename_editor != null or
        state.ownedWorkspace().tab(id) == null)
        return;
    var anchor_screen = client_point;
    if (user32.ClientToScreen(control, &anchor_screen) == 0) return;
    var item: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, index, @bitCast(@intFromPtr(&item))) == 0) return;
    var client: foundation.RECT = undefined;
    const source_dpi = @max(user32.GetDpiForWindow(state.hwnd), geometry.base_dpi);
    if (user32.GetClientRect(state.hwnd, &client) == 0) return;
    application.tab_drag = .{ .candidate = .{
        .source_window_id = state.model_window.id,
        .tab_id = id,
        .original_index = index,
        .anchor_screen = anchor_screen,
        .grab_offset_dip = .{
            .x = tab_drag_geometry.scale(client_point.x - item.left, source_dpi, geometry.base_dpi),
            .y = tab_drag_geometry.scale(client_point.y - item.top, source_dpi, geometry.base_dpi),
        },
        .source_client_width_dip = tab_drag_geometry.scale(client.right - client.left, source_dpi, geometry.base_dpi),
        .source_client_height_dip = tab_drag_geometry.scale(client.bottom - client.top, source_dpi, geometry.base_dpi),
    } };
    application.tab_drag_diagnostics.candidates +|= 1;
}

fn updateApplicationTabDrag(
    application: *Application,
    callback_state: *WindowState,
    client_point: foundation.POINT,
    mouse_keys: usize,
) void {
    var screen_point = client_point;
    const callback_control = callback_state.tab_control orelse return;
    if (user32.ClientToScreen(callback_control, &screen_point) == 0) return;

    switch (application.tab_drag) {
        .idle, .finishing => return,
        .candidate => |candidate| {
            if (candidate.source_window_id != callback_state.model_window.id) return;
            const threshold = dragThresholdFor(callback_control);
            if (!tab_drag_geometry.exceededThreshold(
                dragPoint(candidate.anchor_screen),
                dragPoint(screen_point),
                threshold.x,
                threshold.y,
            )) return;
            if (callback_state.model_window.lifecycle != .live or
                callback_state.ownedWorkspace().tab(candidate.tab_id) == null)
                return cancelApplicationTabDrag(application, false);
            if ((mouse_keys & 1) == 0)
                return cancelApplicationTabDrag(application, false);
            if (callback_state.rename_editor != null) {
                bindWindowState(callback_state);
                cancelRename();
            }
            _ = user32.SetCapture(callback_control);
            if (user32.GetCapture() != callback_control)
                return cancelApplicationTabDrag(application, false);
            application.tab_drag = .{ .active = .{
                .candidate = candidate,
                .capture_hwnd = callback_control,
            } };
            application.tab_drag_diagnostics.started +|= 1;
        },
        .active => {},
    }

    var active = switch (application.tab_drag) {
        .active => |value| value,
        else => return,
    };
    if (active.capture_hwnd != callback_control or
        active.candidate.source_window_id != callback_state.model_window.id)
        return cancelApplicationTabDrag(application, true);
    if ((mouse_keys & 1) == 0)
        return cancelApplicationTabDrag(application, true);

    const next_hover = discoverTabHover(application, &active, screen_point);
    if (!hoverTargetEqual(active.hover, next_hover)) {
        invalidateHover(application, active.hover);
        active.hover = next_hover;
        invalidateHover(application, active.hover);
        application.tab_drag_diagnostics.target_changes +|= 1;
    }

    if (switch (active.hover) {
        .source => true,
        else => false,
    }) {
        const slot = switch (active.hover) {
            .source => |value| value,
            else => unreachable,
        };
        const current = callback_state.ownedWorkspace().indexOfTab(active.candidate.tab_id) orelse
            return cancelApplicationTabDrag(application, true);
        const target = tab_drag_geometry.localIndexForSlot(current, slot, callback_state.ownedWorkspace().tabs.items.len);
        if (current != target) {
            bindWindowState(callback_state);
            if (!callback_state.ownedWorkspace().reorderTab(active.candidate.tab_id, target))
                return cancelApplicationTabDrag(application, true);
            active.local_order_changed = true;
            syncNativeTabs() catch |err| {
                std.log.err("failed to synchronize reordered tabs: {}", .{err});
                return cancelApplicationTabDrag(application, true);
            };
        }
    }
    application.tab_drag = .{ .active = active };
    updateDragCursor(application, screen_point, active.hover);
}

fn discoverTabHover(
    application: *Application,
    active: *const TabDragActive,
    screen_point: foundation.POINT,
) TabHoverTarget {
    const source = application.stateForId(active.candidate.source_window_id) orelse return .none;
    const source_control = source.tab_control orelse return .none;
    const threshold = dragThresholdFor(source_control);
    const source_bounds = screenRect(source_control) orelse return .none;

    const top = user32.WindowFromPoint(screen_point);
    if (top) |top_window| {
        const root = user32.GetAncestor(top_window, wm.GA_ROOT);
        if (root) |root_window| if (application.stateForWindow(root_window)) |candidate| {
            if (candidate.model_window.lifecycle == .live and
                candidate.hwnd != null and candidate.tab_control != null and
                user32.IsWindow(candidate.tab_control) != 0 and
                user32.IsWindowVisible(candidate.tab_control) != 0 and
                user32.IsWindowEnabled(candidate.tab_control) != 0)
            {
                const control = candidate.tab_control.?;
                // A rename editor or native overflow child is deliberately a
                // no-drop surface. Ordinary tab hits resolve to the control.
                if (top_window == control) {
                    var local = screen_point;
                    if (user32.ScreenToClient(control, &local) != 0) {
                        if (tabDragTargetSlot(control, local)) |slot| {
                            if (candidate == source) return .{ .source = slot };
                            return .{ .window = .{
                                .window_id = candidate.model_window.id,
                                .insertion_index = slot,
                            } };
                        }
                    }
                }
            }
        };
    }

    // Hidden-window smoke tests have no z-order hit. Keep local reorder
    // testable while production-visible windows still use WindowFromPoint.
    if (user32.IsWindowVisible(source_control) == 0 and
        tab_drag_geometry.contains(dragRect(source_bounds), dragPoint(screen_point)))
    {
        var local = screen_point;
        if (user32.ScreenToClient(source_control, &local) != 0)
            if (tabDragTargetSlot(source_control, local)) |slot| return .{ .source = slot };
    }

    return if (tab_drag_geometry.tearOutArmed(
        dragRect(source_bounds),
        dragPoint(screen_point),
        threshold.x,
        threshold.y,
    )) .tear_out else .none;
}

fn hoverTargetEqual(a: TabHoverTarget, b: TabHoverTarget) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none, .tear_out => true,
        .source => |slot| slot == b.source,
        .window => |target| target.window_id == b.window.window_id and
            target.insertion_index == b.window.insertion_index,
    };
}

fn hoverState(application: *Application, hover: TabHoverTarget) ?*WindowState {
    return switch (hover) {
        .source => switch (application.tab_drag) {
            .active => |active| application.stateForId(active.candidate.source_window_id),
            else => null,
        },
        .window => |target| application.stateForId(target.window_id),
        else => null,
    };
}

fn invalidateHover(application: *Application, hover: TabHoverTarget) void {
    const state = hoverState(application, hover) orelse return;
    if (state.tab_control) |control| _ = user32.InvalidateRect(control, null, 0);
}

fn markerSlotForState(application: *Application, state: *WindowState) ?usize {
    return switch (application.tab_drag) {
        .active => |active| switch (active.hover) {
            .source => |slot| if (active.candidate.source_window_id == state.model_window.id) slot else null,
            .window => |target| if (target.window_id == state.model_window.id) target.insertion_index else null,
            else => null,
        },
        else => null,
    };
}

fn drawTabInsertionMarker(application: *Application, state: *WindowState) void {
    const slot = markerSlotForState(application, state) orelse return;
    const control = state.tab_control orelse return;
    const count_raw = user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0);
    if (count_raw < 0) return;
    const count: usize = @intCast(count_raw);
    if (slot > count) return;
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(control, &client) == 0) return;
    var x = client.left;
    var top = client.top;
    var bottom = client.bottom;
    if (count != 0) {
        var item: foundation.RECT = undefined;
        const item_index = if (slot == count) count - 1 else slot;
        if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, item_index, @bitCast(@intFromPtr(&item))) == 0) return;
        x = if (slot == count) item.right else item.left;
        top = @max(item.top, client.top);
        bottom = @min(item.bottom, client.bottom);
    }
    const thickness: i32 = @max(tab_drag_geometry.scale(2, geometry.base_dpi, user32.GetDpiForWindow(control)), 2);
    var marker: foundation.RECT = .{
        .left = std.math.clamp(x - @divTrunc(thickness, 2), client.left, @max(client.right - thickness, client.left)),
        .top = top,
        .right = 0,
        .bottom = bottom,
    };
    marker.right = marker.left + thickness;
    const dc = user32.GetDC(control) orelse return;
    defer _ = user32.ReleaseDC(control, dc);
    _ = user32.FillRect(dc, &marker, user32.GetSysColorBrush(gdi.COLOR_HIGHLIGHT));
}

fn updateDragCursor(application: *Application, point: foundation.POINT, hover: TabHoverTarget) void {
    _ = application;
    const cursor = switch (hover) {
        .none => blk: {
            if (user32.WindowFromPoint(point)) |hit| {
                if (user32.GetAncestor(hit, wm.GA_ROOT)) |root|
                    if (active_application) |app| if (app.stateForWindow(root) != null)
                        break :blk user32.LoadCursorW(null, wm.IDC_NO);
            }
            break :blk user32.LoadCursorW(null, wm.IDC_ARROW);
        },
        else => user32.LoadCursorW(null, wm.IDC_ARROW),
    };
    if (cursor) |value| _ = user32.SetCursor(value);
}

fn finishApplicationTabDrag(
    application: *Application,
    callback_state: *WindowState,
    client_point: foundation.POINT,
) void {
    var screen_point = client_point;
    const control = callback_state.tab_control orelse return cancelApplicationTabDrag(application, true);
    if (user32.ClientToScreen(control, &screen_point) == 0)
        return cancelApplicationTabDrag(application, true);
    const active = switch (application.tab_drag) {
        .candidate => {
            application.tab_drag = .idle;
            return;
        },
        .active => |value| value,
        else => return,
    };
    const final_hover = discoverTabHover(application, &active, screen_point);
    invalidateHover(application, active.hover);
    const request: ?TabDropRequest = switch (final_hover) {
        .source => |slot| .{ .reorder = .{
            .source_window_id = active.candidate.source_window_id,
            .tab_id = active.candidate.tab_id,
            .index = tab_drag_geometry.localIndexForSlot(
                callback_state.ownedWorkspace().indexOfTab(active.candidate.tab_id) orelse active.candidate.original_index,
                slot,
                callback_state.ownedWorkspace().tabs.items.len,
            ),
        } },
        .window => |target| .{ .transfer = .{
            .source_window_id = active.candidate.source_window_id,
            .tab_id = active.candidate.tab_id,
            .destination_window_id = target.window_id,
            .insertion_index = target.insertion_index,
            .original_index = active.candidate.original_index,
        } },
        .tear_out => .{ .tear_out = .{
            .source_window_id = active.candidate.source_window_id,
            .tab_id = active.candidate.tab_id,
            .original_index = active.candidate.original_index,
            .point = screen_point,
            .grab_offset_dip = active.candidate.grab_offset_dip,
            .source_client_width_dip = active.candidate.source_client_width_dip,
            .source_client_height_dip = active.candidate.source_client_height_dip,
        } },
        .none => null,
    };
    if (request == null) {
        rollbackTabDrag(application, active.candidate, active.local_order_changed);
        application.tab_drag = .idle;
        application.tab_drag_diagnostics.canceled +|= 1;
        return;
    }
    application.tab_drag = .{ .finishing = .{
        .request = request,
        .capture_hwnd = active.capture_hwnd,
    } };
}

fn releaseFinishedTabCapture() void {
    const application = active_application orelse return;
    const finishing = switch (application.tab_drag) {
        .finishing => |value| value,
        else => return,
    };
    if (finishing.capture_hwnd) |capture| {
        if (user32.GetCapture() == capture) _ = user32.ReleaseCapture();
    }
    if (finishing.request == null) {
        application.tab_drag = .idle;
        return;
    }
    const receiver = application.notification_window orelse {
        cancelApplicationTabDrag(application, false);
        return;
    };
    if (user32.PostMessageW(receiver, tab_drop_message, 0, 0) == 0)
        cancelApplicationTabDrag(application, false);
}

fn rollbackTabDrag(application: *Application, candidate: TabDragCandidate, changed: bool) void {
    if (!changed) return;
    application.tab_drag_diagnostics.rollback_attempts +|= 1;
    const source = application.stateForId(candidate.source_window_id) orelse return;
    if (source.model_window.lifecycle != .live or source.ownedWorkspace().tab(candidate.tab_id) == null) return;
    bindWindowState(source);
    if (!source.ownedWorkspace().reorderTab(candidate.tab_id, candidate.original_index)) {
        application.tab_drag_diagnostics.rollback_failures +|= 1;
        return;
    }
    syncNativeTabs() catch {
        application.tab_drag_diagnostics.rollback_failures +|= 1;
        if (source.hwnd) |window| _ = user32.InvalidateRect(window, null, 0);
    };
    if (source.hwnd) |window| _ = user32.SetFocus(window);
}

fn cancelApplicationTabDrag(application: *Application, release_capture: bool) void {
    const state = application.tab_drag;
    switch (state) {
        .idle => return,
        .candidate => {},
        .active => |active| {
            invalidateHover(application, active.hover);
            rollbackTabDrag(application, active.candidate, active.local_order_changed);
            if (release_capture and user32.GetCapture() == active.capture_hwnd)
                _ = user32.ReleaseCapture();
        },
        .finishing => |finishing| if (finishing.request) |request| switch (request) {
            .transfer => |value| rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index),
            .tear_out => |value| rollbackStableRequest(application, value.source_window_id, value.tab_id, value.original_index),
            .reorder => {},
        },
    }
    application.tab_drag = .idle;
    application.tab_drag_diagnostics.canceled +|= 1;
    if (user32.LoadCursorW(null, wm.IDC_ARROW)) |cursor| _ = user32.SetCursor(cursor);
}

fn cancelCandidateOrActiveDrag(application: *Application) void {
    switch (application.tab_drag) {
        .candidate, .active => cancelApplicationTabDrag(application, true),
        .idle, .finishing => {},
    }
}

fn rollbackStableRequest(application: *Application, window_id: workspace.WindowId, tab_id: workspace.TabId, index: usize) void {
    const state = application.stateForId(window_id) orelse return;
    const candidate: TabDragCandidate = .{
        .source_window_id = window_id,
        .tab_id = tab_id,
        .original_index = index,
        .anchor_screen = .{ .x = 0, .y = 0 },
        .grab_offset_dip = .{ .x = 0, .y = 0 },
        .source_client_width_dip = 0,
        .source_client_height_dip = 0,
    };
    rollbackTabDrag(application, candidate, state.ownedWorkspace().indexOfTab(tab_id) != index);
}

fn cancelDragIfSource(application: *Application, id: workspace.WindowId) void {
    const is_source = switch (application.tab_drag) {
        .candidate => |candidate| candidate.source_window_id == id,
        .active => |active| active.candidate.source_window_id == id,
        .finishing => |finishing| if (finishing.request) |request| switch (request) {
            .reorder => |value| value.source_window_id == id,
            .transfer => |value| value.source_window_id == id,
            .tear_out => |value| value.source_window_id == id,
        } else false,
        .idle => false,
    };
    if (is_source) cancelApplicationTabDrag(application, true);
}

fn clearDragDestination(application: *Application, id: workspace.WindowId) void {
    var active = switch (application.tab_drag) {
        .active => |value| value,
        else => return,
    };
    switch (active.hover) {
        .window => |target| if (target.window_id == id) {
            invalidateHover(application, active.hover);
            active.hover = .none;
            application.tab_drag = .{ .active = active };
        },
        else => {},
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
    // Set the durable per-window view before any of the work below can
    // synchronously re-enter the window procedure (notably SetFocus).  A
    // nested message binds from WindowState, so leaving the previous model
    // there would restore it while the workspace has already selected `id`.
    if (windowStateFromHwnd(window)) |state| state.active_model = model;
    input_translator.* = .{};
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    pressed_mouse_button = null;
    render_cache.deinit();
    render_cache.* = .init(std.heap.smp_allocator);
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
    // Tab creation activates the new session before returning to the parent
    // window procedure. Keep the durable WindowState in sync at that point:
    // focus changes may synchronously bind it again before the outer callback
    // has a chance to persist its compatibility globals.
    const state = windowStateFromHwnd(window) orelse return error.RuntimeTabCreationMissingWindowState;
    if (state.active_model != &workspace_state.activeSession().?.model)
        return error.RuntimeTabCreationDidNotActivateInputModel;
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
    setTestModifiers(window, .{ .ctrl = true, .shift = true });
    defer setTestModifiers(window, null);

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
    setTestModifiers(window, .{ .ctrl = true });
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 0x09, 1);
    if (workspace_state.active_tab_id != first_id)
        return error.ShortcutCycleDidNotAdvance;
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 0x09, (@as(isize, 1) << 30) | 1);
    if (workspace_state.active_tab_id != created_id)
        return error.ShortcutCycleDidNotRepeat;
    _ = user32.SendMessageW(window, wm.WM_KEYUP, 0x09, @as(isize, 1) << 31);

    setTestModifiers(window, .{ .ctrl = true, .shift = true });
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 'W', 1);
    _ = user32.SendMessageW(window, wm.WM_CHAR, 'w', 1);
    _ = user32.SendMessageW(window, wm.WM_KEYUP, 'W', @as(isize, 1) << 31);
    if (workspace_state.tabs.items.len != count_before)
        return error.ShortcutCloseDidNotSynchronizeTabs;

    // Exercise the real top-level window procedure for the standard keyboard
    // context-menu gesture. The test command is consumed by the production
    // popup path, proving Shift+F10 does not fall through to terminal input.
    setTestContextMenuCommand(window, context_menu_new_tab);
    setTestModifiers(window, .{ .shift = true });
    _ = user32.SendMessageW(window, wm.WM_KEYDOWN, 0x79, 1); // VK_F10
    setTestModifiers(window, .{});
    _ = user32.SendMessageW(window, wm.WM_KEYUP, 0x79, @as(isize, 1) << 31);
    setTestContextMenuCommand(window, null);
    if (workspace_state.tabs.items.len != count_before + 1)
        return error.ShiftF10DidNotOpenTabContextMenu;
    const keyboard_created = workspace_state.active_tab_id orelse
        return error.ShiftF10DidNotActivateNewTab;
    closeTerminalTab(window, keyboard_created);
    if (workspace_state.tabs.items.len != count_before)
        return error.ShiftF10ContextMenuDidNotCloseCreatedTab;
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
    var hit: controls.TCHITTESTINFO = .{
        .pt = messagePoint(point),
        .flags = controls.TCHT_NOWHERE,
    };
    const hit_index = user32.SendMessageW(control, controls.TCM_HITTEST, 0, @bitCast(@intFromPtr(&hit)));
    if (hit_index != 0) return error.RenameDoubleClickDidNotHitActiveTab;
    if (nativeTabIdAt(0) != id) return error.RenameNativeTabIdentityMismatch;
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

    setTestContextMenuCommand(window, context_menu_rename_tab);
    defer setTestContextMenuCommand(window, null);
    _ = user32.SendMessageW(control, wm.WM_CONTEXTMENU, 0, packMessagePoint(screen_point));
    const editor = rename_editor orelse return error.ContextMenuRenameDidNotOpenEditor;
    if (editor.tab_id != hit_id) return error.ContextMenuDidNotSelectHitTab;
    cancelRename();

    const count_before_create = workspace_state.tabs.items.len;
    setTestContextMenuCommand(window, context_menu_new_tab);
    _ = user32.SendMessageW(window, wm.WM_CONTEXTMENU, 0, -1);
    if (workspace_state.tabs.items.len != count_before_create + 1)
        return error.KeyboardContextMenuDidNotCreateTab;
    const created = workspace_state.active_tab_id orelse return error.ContextMenuCreateDidNotActivateTab;
    if (created == hit_id) return error.ContextMenuCreateDidNotSelectNewTab;

    setTestContextMenuCommand(window, context_menu_close_tab);
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

/// Exercise the same keyboard context-menu path used by Shift+F10.  The
/// standard SysTabControl32 remains the accessibility provider; this checks
/// its native item identity, labels, selection, and focusable menu route on
/// both sides of a cross-window transfer.
fn verifyTransferHardening(source: *WindowState, instance: foundation.HINSTANCE) !void {
    const source_window = source.hwnd orelse return error.SourceWindowUnavailable;
    bindWindowState(source);
    try createTerminalTab(source_window);
    storeWindowState(source);
    const moved_id = source.ownedWorkspace().active_tab_id orelse return error.TransferMissingActiveTab;
    const moved_tab = source.ownedWorkspace().tab(moved_id) orelse return error.TransferMissingTab;
    const moved_session = moved_tab.root.terminalSession();
    const moved_tab_address = @intFromPtr(moved_tab);
    const moved_session_address = @intFromPtr(moved_session);

    const destination = try createVisibleWindow(source.application, instance);
    const destination_window = destination.hwnd orelse return error.DestinationWindowUnavailable;

    try sendSyntheticDpi(source_window, 96);
    try sendSyntheticDpi(destination_window, 144);
    if (source.dpi != 96 or destination.dpi != 144)
        return error.IndependentWindowDpiMetricsMismatch;

    try verifyNativeTabPresentation(source);
    try verifyNativeTabPresentation(destination);
    const source_before = source.renderer.diagnostics();
    const destination_before = destination.renderer.diagnostics();

    // Keyboard invocation reaches the standard tab control's WM_CONTEXTMENU
    // path; the selected dynamic command uses the exact production backend.
    source.test_context_menu_command = context_menu_move_tab_to_window_first;
    bindWindowState(source);
    _ = user32.SetFocus(source.tab_control);
    _ = user32.SendMessageW(source.tab_control.?, wm.WM_CONTEXTMENU, 0, -1);
    source.test_context_menu_command = null;

    const moved_destination_tab = destination.ownedWorkspace().tab(moved_id) orelse
        return error.KeyboardMoveDidNotReachDestination;
    if (@intFromPtr(moved_destination_tab) != moved_tab_address or
        @intFromPtr(moved_destination_tab.root.terminalSession()) != moved_session_address)
        return error.KeyboardMoveChangedTerminalIdentity;
    if (source.ownedWorkspace().tab(moved_id) != null or
        source.ownedWorkspace().tabs.items.len != 1 or destination.ownedWorkspace().tabs.items.len != 2)
        return error.KeyboardMoveDidNotPreserveWorkspaceOwnership;

    try verifyNativeTabPresentation(source);
    try verifyNativeTabPresentation(destination);
    const source_after = source.renderer.diagnostics();
    const destination_after = destination.renderer.diagnostics();
    if (source_after.gpu_recreation_count != source_before.gpu_recreation_count or
        destination_after.gpu_recreation_count != destination_before.gpu_recreation_count)
        return error.TransferRecreatedExistingRenderer;
    if (source_after.layout_build_count > source_before.layout_build_count + source.model().?.rows() or
        destination_after.layout_build_count > destination_before.layout_build_count + destination.model().?.rows())
        return error.TransferRebuiltMoreThanVisibleRows;

    beginWindowClose(destination_window);
}

fn sendSyntheticDpi(window: foundation.HWND, dpi: u16) !void {
    var suggested: foundation.RECT = undefined;
    if (user32.GetWindowRect(window, &suggested) == 0) return error.GetWindowRectFailed;
    _ = user32.SendMessageW(
        window,
        wm.WM_DPICHANGED,
        @as(usize, dpi) | (@as(usize, dpi) << 16),
        @bitCast(@intFromPtr(&suggested)),
    );
}

fn verifyNativeTabPresentation(state: *WindowState) !void {
    const control = state.tab_control orelse return error.TabControlUnavailable;
    const workspace_view = state.ownedWorkspace();
    if (user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0) !=
        @as(isize, @intCast(workspace_view.tabs.items.len)))
        return error.NativeTabAccessibilityCountMismatch;
    const active_id = workspace_view.active_tab_id orelse return error.NativeTabAccessibilityMissingSelection;
    const active_index = workspace_view.indexOfTab(active_id) orelse return error.NativeTabAccessibilityMissingSelection;
    if (user32.SendMessageW(control, controls.TCM_GETCURSEL, 0, 0) != @as(isize, @intCast(active_index)))
        return error.NativeTabAccessibilitySelectionMismatch;
    for (workspace_view.tabs.items, 0..) |tab, index| {
        bindWindowState(state);
        if (nativeTabIdAt(index) != tab.id) return error.NativeTabAccessibilityIdentityMismatch;
    }
}

fn verifyTabDragReordering(window: foundation.HWND) !void {
    const control = tab_control orelse return error.TabControlUnavailable;
    try createTerminalTab(window);
    try createTerminalTab(window);
    if (workspace_state.tabs.items.len != 3) return error.TabDragDidNotCreateTestTabs;

    const first_id = workspace_state.tabs.items[0].id;
    const second_id = workspace_state.tabs.items[1].id;
    const third_id = workspace_state.tabs.items[2].id;
    try dragNativeTabToPoint(control, first_id, .right);
    try expectNativeTabOrder(&.{ second_id, third_id, first_id });
    try expectNativeActiveTab(first_id);

    try dragNativeTabToPoint(control, first_id, .left);
    try expectNativeTabOrder(&.{ first_id, second_id, third_id });
    try expectNativeActiveTab(first_id);
}

fn verifyCrossWindowTabDrag(source: *WindowState, instance: foundation.HINSTANCE) !void {
    const source_window = source.hwnd orelse return error.SourceWindowUnavailable;
    bindWindowState(source);
    try createTerminalTab(source_window);
    try createTerminalTab(source_window);
    try createTerminalTab(source_window);
    const first = source.ownedWorkspace().tabs.items[0];
    const second = source.ownedWorkspace().tabs.items[1];
    const third = source.ownedWorkspace().tabs.items[2];
    const first_address = @intFromPtr(first);
    const second_address = @intFromPtr(second);

    const destination = try createVisibleWindow(source.application, instance);
    const destination_window = destination.hwnd orelse return error.DestinationWindowUnavailable;
    const original_destination_id = destination.ownedWorkspace().tabs.items[0].id;

    const transfers = [_]struct { id: workspace.TabId, index: usize }{
        .{ .id = first.id, .index = 0 },
        .{ .id = second.id, .index = 1 },
        .{ .id = third.id, .index = 3 },
    };
    for (transfers) |transfer| {
        source.application.tab_drag = .{ .finishing = .{ .request = .{ .transfer = .{
            .source_window_id = source.model_window.id,
            .tab_id = transfer.id,
            .destination_window_id = destination.model_window.id,
            .insertion_index = transfer.index,
            .original_index = source.ownedWorkspace().indexOfTab(transfer.id).?,
        } } } };
        processPendingTabDrop(source.application);
    }
    if (destination.ownedWorkspace().tabs.items.len != 4 or
        destination.ownedWorkspace().tabs.items[0].id != first.id or
        destination.ownedWorkspace().tabs.items[1].id != second.id or
        destination.ownedWorkspace().tabs.items[2].id != original_destination_id or
        destination.ownedWorkspace().tabs.items[3].id != third.id)
        return error.IndexedDragTransferOrderMismatch;
    if (@intFromPtr(destination.ownedWorkspace().tabs.items[0]) != first_address or
        @intFromPtr(destination.ownedWorkspace().tabs.items[1]) != second_address)
        return error.IndexedDragTransferChangedIdentity;
    try verifyNativeTabPresentation(destination);

    var release_point: foundation.POINT = .{ .x = 200, .y = 120 };
    var destination_bounds: foundation.RECT = undefined;
    if (user32.GetWindowRect(destination_window, &destination_bounds) != 0)
        release_point = .{ .x = destination_bounds.left + 200, .y = destination_bounds.top + 80 };
    const windows_before = source.application.windows.items.len;
    source.application.tab_drag = .{ .finishing = .{ .request = .{ .tear_out = .{
        .source_window_id = destination.model_window.id,
        .tab_id = second.id,
        .original_index = 1,
        .point = release_point,
        .grab_offset_dip = .{ .x = 20, .y = 10 },
        .source_client_width_dip = 700,
        .source_client_height_dip = 420,
    } } } };
    processPendingTabDrop(source.application);
    if (source.application.windows.items.len != windows_before + 1)
        return error.TearOutDidNotCreateDestination;
    const torn = source.application.windows.items[source.application.windows.items.len - 1];
    if (torn.ownedWorkspace().tabs.items.len != 1 or
        @intFromPtr(torn.ownedWorkspace().tabs.items[0]) != second_address)
        return error.TearOutChangedTabIdentity;
    const torn_window = torn.hwnd orelse return error.TearOutWindowUnavailable;
    var torn_bounds: foundation.RECT = undefined;
    if (user32.GetWindowRect(torn_window, &torn_bounds) == 0 or
        torn_bounds.right <= torn_bounds.left or torn_bounds.bottom <= torn_bounds.top)
        return error.TearOutPlacementInvalid;

    bindWindowState(source);
    try createTerminalTab(source_window);
    try createTerminalTab(source_window);
    const rollback_id = source.ownedWorkspace().tabs.items[0].id;
    if (!source.ownedWorkspace().reorderTab(rollback_id, 2)) return error.RollbackSetupFailed;
    try syncNativeTabs();
    source.application.tab_drag = .{ .active = .{
        .candidate = .{
            .source_window_id = source.model_window.id,
            .tab_id = rollback_id,
            .original_index = 0,
            .anchor_screen = .{ .x = 0, .y = 0 },
            .grab_offset_dip = .{ .x = 0, .y = 0 },
            .source_client_width_dip = 700,
            .source_client_height_dip = 420,
        },
        .capture_hwnd = source.tab_control.?,
        .local_order_changed = true,
    } };
    cancelApplicationTabDrag(source.application, false);
    if (source.ownedWorkspace().indexOfTab(rollback_id) != 0)
        return error.CanceledDragDidNotRestoreOriginalOrder;
    try verifyNativeTabPresentation(source);

    bindWindowState(torn);
    beginWindowClose(torn_window);
    bindWindowState(destination);
    beginWindowClose(destination_window);
    bindWindowState(source);
}

const TabDragDirection = enum { left, right };

fn dragNativeTabToPoint(
    control: foundation.HWND,
    id: workspace.TabId,
    direction: TabDragDirection,
) !void {
    const source_index = nativeIndexForTab(id) orelse return error.TabDragMissingSource;
    var source: foundation.RECT = undefined;
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, source_index, @bitCast(@intFromPtr(&source))) == 0)
        return error.GetTabItemRectFailed;
    const anchor: foundation.POINT = .{
        .x = source.left + @divTrunc(source.right - source.left, 2),
        .y = source.top + @divTrunc(source.bottom - source.top, 2),
    };
    var boundary: foundation.RECT = undefined;
    const boundary_index: usize = switch (direction) {
        .left => 0,
        .right => @intCast(user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0) - 1),
    };
    if (user32.SendMessageW(control, controls.TCM_GETITEMRECT, boundary_index, @bitCast(@intFromPtr(&boundary))) == 0)
        return error.GetTabItemRectFailed;
    const destination: foundation.POINT = .{
        .x = switch (direction) {
            .left => boundary.left + 1,
            .right => boundary.right + 4,
        },
        .y = anchor.y,
    };

    _ = user32.SendMessageW(control, wm.WM_LBUTTONDOWN, 0, packMessagePoint(anchor));
    _ = user32.SendMessageW(control, wm.WM_MOUSEMOVE, 1, packMessagePoint(destination));
    _ = user32.SendMessageW(control, wm.WM_LBUTTONUP, 0, packMessagePoint(destination));
    // SendMessage does not pump the deferred notification-window request as a
    // real input loop would. Consume it here before starting the next gesture.
    if (active_application) |application| processPendingTabDrop(application);
}

fn expectNativeTabOrder(expected: []const workspace.TabId) !void {
    const control = tab_control orelse return error.TabControlUnavailable;
    if (workspace_state.tabs.items.len != expected.len) return error.TabDragWorkspaceCountMismatch;
    if (user32.SendMessageW(control, controls.TCM_GETITEMCOUNT, 0, 0) != @as(isize, @intCast(expected.len)))
        return error.TabDragNativeCountMismatch;
    for (expected, 0..) |id, index| {
        if (workspace_state.tabs.items[index].id != id) return error.TabDragWorkspaceOrderMismatch;
        if (nativeTabIdAt(index) != id) return error.TabDragNativeIdentityMismatch;
    }
}

fn expectNativeActiveTab(id: workspace.TabId) !void {
    const control = tab_control orelse return error.TabControlUnavailable;
    if (workspace_state.active_tab_id != id) return error.TabDragActiveIdentityMismatch;
    const active_index = nativeIndexForTab(id) orelse return error.TabDragMissingActiveNativeItem;
    if (user32.SendMessageW(control, controls.TCM_GETCURSEL, 0, 0) != @as(isize, @intCast(active_index)))
        return error.TabDragNativeSelectionMismatch;
}

fn windowProc(
    window: foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const result = windowProcImpl(window, message, wparam, lparam);
    if (windowStateFromHwnd(window)) |state| storeWindowState(state);
    return result;
}

fn windowProcImpl(
    window: foundation.HWND,
    message: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    if (message == wm.WM_NCCREATE) {
        const create: *const wm.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (create.lpCreateParams) |parameter| {
            const state: *WindowState = @ptrCast(@alignCast(parameter));
            state.hwnd = window;
            _ = win32.zig.setWindowLongPtrW(
                window,
                @intFromEnum(wm.GWLP_USERDATA),
                @intFromPtr(state),
            );
            bindWindowState(state);
        }
        return user32.DefWindowProcW(window, message, wparam, lparam);
    }

    const state = windowStateFromHwnd(window);
    if (state) |value| bindWindowState(value);
    if (state) |value| if (value.model_window.lifecycle == .destroyed)
        return user32.DefWindowProcW(window, message, wparam, lparam);

    switch (message) {
        wm.WM_PAINT => {
            paint_completed = paint(window);
            if (isSmokeMode(active_mode) and
                (state == null or state.?.auto_close_on_paint))
            {
                _ = user32.PostMessageW(window, wm.WM_CLOSE, 0, 0);
            }
            return 0;
        },
        wm.WM_SIZE => {
            if (frame_trace.enabled) resize_message_count +|= 1;
            if (state) |value| cancelDragIfSource(value.application, value.model_window.id);
            if (wparam != wm.SIZE_MINIMIZED and
                (state == null or (state.?.renderer.gpu != null and state.?.active_model != null)))
            {
                resizeForClient(window) catch {
                    std.log.err("failed to resize terminal for client area", .{});
                };
            }
            return 0;
        },
        wm.WM_ENTERSIZEMOVE => {
            return 0;
        },
        wm.WM_EXITSIZEMOVE => {
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
            if (state) |value| cancelDragIfSource(value.application, value.model_window.id);
            const dpi: u16 = @truncate(wparam);
            if (state) |value| value.dpi = dpi;
            terminal_metrics.* = active_renderer.metricsForDpi(dpi);
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
            if (wparam == cursor_timer_id) {
                model.toggleCursorBlink();
                invalidateRenderDamage(window);
            }
            return 0;
        },
        frame_message => {
            if (state) |value| {
                if (value.frame_request_timestamp != 0)
                    value.frame_delay_trace.recordSince(value.frame_request_timestamp);
                value.frame_request_timestamp = 0;
            }
            frame_message_pending = false;
            _ = user32.UpdateWindow(window);
            return 0;
        },
        renderer_failure_message => {
            const failure = renderer_failure orelse error.RendererUnavailable;
            showRendererFailure(window, failure);
            beginWindowClose(window);
            return 0;
        },
        tab_drop_message => {
            if (state == null) if (active_application) |application|
                processPendingTabDrop(application);
            return 0;
        },
        conpty.output_message => {
            const id: workspace.SessionId = @enumFromInt(@as(u64, @intCast(wparam)));
            const target = notificationTarget(window, id) orelse return 0;
            const target_state = windowStateFromHwnd(target) orelse return 0;
            bindWindowState(target_state);
            handleConptyOutput(target, id);
            storeWindowState(target_state);
            return 0;
        },
        conpty.child_exit_message => {
            const id: workspace.SessionId = @enumFromInt(@as(u64, @intCast(wparam)));
            const target = notificationTarget(window, id) orelse return 0;
            if (windowStateFromHwnd(target)) |target_state| bindWindowState(target_state);
            if (workspace_state.session(id)) |session| {
                if (session.processAs(conpty.Session)) |process| {
                    _ = process.beginClosingAfterChildExit();
                    if (process.childExitCode()) |code|
                        std.log.info("ConPTY child exited with code {d}", .{code});
                    if (isMultiSessionIntegrationMode(active_mode)) {
                        _ = session.noteChildExit();
                        finishMultiSessionIntegration(target);
                        return 0;
                    }
                    if (session.noteChildExit())
                        closeTerminalTab(target, workspace_state.tabForSession(session.id).?.id);
                }
            }
            return 0;
        },
        conpty.input_failure_message => {
            const id: workspace.SessionId = @enumFromInt(@as(u64, @intCast(wparam)));
            const target = notificationTarget(window, id) orelse return 0;
            if (windowStateFromHwnd(target)) |target_state| bindWindowState(target_state);
            if (workspace_state.session(id)) |session| {
                if (session.processAs(conpty.Session)) |process| if (process.inputFailureCode()) |code|
                    std.log.err(
                        "WriteFile for ConPTY input failed with Win32 error {d}",
                        .{code},
                    );
            }
            return 0;
        },
        wm.WM_KEYDOWN, wm.WM_SYSKEYDOWN, wm.WM_KEYUP, wm.WM_SYSKEYUP => {
            if (wparam == 0x1b) if (active_application) |application| {
                if (switch (application.tab_drag) {
                    .idle => false,
                    else => true,
                }) {
                    if (message == wm.WM_KEYDOWN or message == wm.WM_SYSKEYDOWN) {
                        application.suppress_drag_escape_character = true;
                        cancelApplicationTabDrag(application, true);
                    }
                    return 0;
                }
            };
            // Do not turn the real Windows system gestures into terminal
            // input.  In particular DefWindowProc owns Alt+F4 and Alt+Space;
            // unbound Alt combinations remain terminal input below.
            if (keyRoute(message, wparam) == .system)
                return user32.DefWindowProcW(window, message, wparam, lparam);
            _ = handleKeyMessage(message, wparam, lparam);
            return 0;
        },
        wm.WM_CHAR, wm.WM_SYSCHAR => {
            if (wparam == 0x1b) if (active_application) |application| {
                if (application.suppress_drag_escape_character) {
                    application.suppress_drag_escape_character = false;
                    return 0;
                }
            };
            // WM_SYSCHAR is generated for system-menu mnemonics. Application
            // shortcuts have already accounted for their generated character;
            // ordinary Alt text is intentionally delivered to the terminal.
            // Let DefWindowProc consume the Alt+Space character before it can
            // reach the terminal. Calling the terminal path first was enough
            // to open the native menu, but also queued a literal space.
            if (isSystemCharacterMessage(message, wparam))
                return user32.DefWindowProcW(window, message, wparam, lparam);
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
            cancelSelectionDrag();
            queueFocus(.lost);
            return 0;
        },
        wm.WM_CANCELMODE, wm.WM_CAPTURECHANGED => {
            cancelSelectionDrag();
            return user32.DefWindowProcW(window, message, wparam, lparam);
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
            beginWindowClose(window);
            return 0;
        },
        wm.WM_DESTROY => {
            return 0;
        },
        wm.WM_NCDESTROY => {
            if (state) |value| {
                value.hwnd = null;
                value.tab_control = null;
                value.model_window.lifecycle = .destroyed;
                if (active_mode == .integration_final_retirement and
                    value.application.liveWindowCount() == 0 and
                    value.application.retirementPending() != 0)
                    value.application.final_window_destroyed_while_retiring = true;
                _ = win32.zig.setWindowLongPtrW(
                    window,
                    @intFromEnum(wm.GWLP_USERDATA),
                    0,
                );
            }
            return user32.DefWindowProcW(window, message, wparam, lparam);
        },
        else => return user32.DefWindowProcW(window, message, wparam, lparam),
    }
}

fn windowStateFromHwnd(window: foundation.HWND) ?*WindowState {
    const raw = win32.zig.getWindowLongPtrW(window, @intFromEnum(wm.GWLP_USERDATA));
    if (raw == 0) return null;
    return @ptrFromInt(raw);
}

/// The only top-level close entry point. Completion and error paths often do
/// not receive WM_CLOSE, so they must establish the same lifecycle boundary
/// before DestroyWindow synchronously enters WM_DESTROY.
fn beginWindowClose(window: foundation.HWND) void {
    const closing_state = windowStateFromHwnd(window);
    const caller_state = if (app_window) |caller| windowStateFromHwnd(caller) else null;
    if (closing_state) |state| {
        if (caller_state != state) bindWindowState(state);
        defer if (caller_state) |caller| {
            if (caller != state and caller.model_window.lifecycle != .destroyed)
                bindWindowState(caller);
        };
        cancelDragIfSource(state.application, state.model_window.id);
        clearDragDestination(state.application, state.model_window.id);
        capturePerformanceSnapshot(state);
        switch (state.model_window.lifecycle) {
            .destroyed, .closing => return,
            .constructing, .live, .transferring => state.model_window.lifecycle = .closing,
        }
    }
    if (model_initialized) while (workspace_state.active_tab_id) |id| {
        const tab = workspace_state.tab(id) orelse break;
        retireTab(tab);
        _ = workspace_state.detachTab(id);
    };
    model_initialized = false;
    if (windowStateFromHwnd(window)) |state| state.active_model = null;
    _ = user32.DestroyWindow(window);
}

fn capturePerformanceSnapshot(state: *WindowState) void {
    if (state.performance_snapshot != null) return;
    const active = state.active_model orelse return;
    state.performance_snapshot = .{
        .terminal = active.diagnostics(),
        .cache = state.render_cache.diagnostics(),
        .renderer = state.renderer.diagnostics(),
        .output_trace = output_trace.snapshot(),
        .paint_trace = paint_trace.snapshot(),
        .cache_trace = cache_trace.snapshot(),
        .queue_delay_trace = state.queue_delay_trace.snapshot(),
        .frame_delay_trace = state.frame_delay_trace.snapshot(),
        .output_to_present_trace = state.output_to_present_trace.snapshot(),
        .resize_messages = resize_message_count,
        .bytes_read = state.bytes_read,
        .bytes_parsed = state.bytes_parsed,
        .maximum_backlog = state.maximum_backlog,
        .continuation_count = state.continuation_count,
        .maximum_ui_batch = state.maximum_ui_batch,
    };
}

/// Establish the session boundary before the tab leaves visible ownership.
/// `beginClosing` only initiates ConPTY shutdown; all waits happen in the
/// retirement worker after the tab is detached.
fn retireTab(tab: *workspace.Tab) void {
    const application = active_application orelse return;
    const session = tab.root.terminalSession();
    session.model.setReplySink(null);
    if (session.processAs(conpty.Session)) |process| _ = process.beginClosing();
    if (application.model.session_owners.getPtr(session.id)) |owner|
        owner.* = .retiring;
    if (application.retirement_manager) |manager| _ = manager.enqueue(tab);
}

fn notificationTarget(window: foundation.HWND, id: workspace.SessionId) ?foundation.HWND {
    if (notification_window) |receiver| {
        if (window == receiver) {
            const application = active_application orelse return null;
            const state = application.stateForSession(id) orelse return null;
            if (state.model_window.lifecycle != .live) return null;
            const target = state.hwnd orelse return null;
            return if (user32.IsWindow(target) != 0) target else null;
        }
    }
    return window;
}

const Shortcut = enum {
    suppress,
    new_tab,
    new_window,
    close_tab,
    cycle_forward,
    cycle_backward,
    select_tab,
    paste,
    copy,
    tab_context_menu,
};

/// Windows reserves a small set of Alt gestures for the non-client/system
/// surface. Everything else, including ordinary Alt-modified terminal input,
/// stays on the terminal route.
const KeyRoute = enum { terminal, system };

fn keyRoute(message: u32, virtual_key: usize) KeyRoute {
    return switch (message) {
        wm.WM_SYSKEYDOWN, wm.WM_SYSKEYUP => switch (virtual_key) {
            0x73, // VK_F4
            0x20, // VK_SPACE
            => .system,
            else => .terminal,
        },
        // Alt+Space can produce a WM_SYSCHAR while DefWindowProc is opening
        // the system menu. Do not feed that character to ConPTY.
        wm.WM_SYSCHAR => if (virtual_key == 0x20) .system else .terminal,
        else => .terminal,
    };
}

fn isSystemCharacterMessage(message: u32, virtual_key: usize) bool {
    return message == wm.WM_SYSCHAR and keyRoute(message, virtual_key) == .system;
}

test "key routing reserves system gestures but keeps terminal Alt input" {
    try std.testing.expectEqual(KeyRoute.system, keyRoute(wm.WM_SYSKEYDOWN, 0x73));
    try std.testing.expectEqual(KeyRoute.system, keyRoute(wm.WM_SYSKEYUP, 0x20));
    try std.testing.expectEqual(KeyRoute.system, keyRoute(wm.WM_SYSCHAR, 0x20));
    try std.testing.expectEqual(KeyRoute.terminal, keyRoute(wm.WM_SYSKEYDOWN, 'A'));
    try std.testing.expectEqual(KeyRoute.terminal, keyRoute(wm.WM_SYSCHAR, 'a'));
    try std.testing.expectEqual(KeyRoute.terminal, keyRoute(wm.WM_KEYDOWN, 0x79)); // VK_F10
    try std.testing.expect(isSystemCharacterMessage(wm.WM_SYSCHAR, 0x20));
    try std.testing.expect(!isSystemCharacterMessage(wm.WM_SYSCHAR, 'a'));
}

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
    // ttyrtle has no menu bar, so F10 remains available to the terminal.
    // Shift+F10 retains its standard Windows meaning: invoke the context menu
    // for the focused content, which here is the active tab's menu.
    if (mods.shift and !mods.ctrl and !mods.alt and virtual_key == 0x79)
        return .tab_context_menu;
    if (mods.ctrl and mods.shift) return switch (virtual_key) {
        'T' => .new_tab,
        'N' => if (mods.shift) .new_window else null,
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
        .new_window => virtual_key == 'N',
        .close_tab => virtual_key == 'W',
        .cycle_forward, .cycle_backward => virtual_key == 0x09,
        .select_tab => virtual_key >= '1' and virtual_key <= '9',
        .paste => virtual_key == 'V',
        .copy => virtual_key == 'C',
        .tab_context_menu => virtual_key == 0x79,
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

test "F10 keeps its terminal route while Shift+F10 invokes the tab menu" {
    try std.testing.expect(shortcutForKey(0x79, .{}) == null);
    try std.testing.expectEqual(
        Shortcut.tab_context_menu,
        shortcutForKey(0x79, .{ .shift = true }).?,
    );
    var state: ShortcutState = .{};
    try std.testing.expectEqual(
        Shortcut.tab_context_menu,
        state.handleKey(wm.WM_KEYDOWN, 0x79, false, .{ .shift = true }).?,
    );
    // The release remains consumed even after Shift is released first.
    try std.testing.expectEqual(
        Shortcut.tab_context_menu,
        state.handleKey(wm.WM_KEYUP, 0x79, false, .{}).?,
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
    // Escape follows the normal Windows text-selection convention while a
    // local terminal selection is present. A subsequent Escape is delivered
    // to the hosted terminal normally.
    if (is_down and wparam == 0x1b and cancelTerminalSelection(app_window))
        return true;
    if (handleViewportKey(message, wparam, modifiers)) return true;
    if (shortcut_state.handleKey(message, wparam, repeated, modifiers)) |shortcut| switch (shortcut) {
        .suppress => {},
        .new_tab => if (is_down) {
            const window = app_window orelse return true;
            createTerminalTab(window) catch |err| std.log.err("failed to create terminal tab: {}", .{err});
        },
        .new_window => if (is_down) {
            createNewWindow() catch |err| std.log.err("failed to create terminal window: {}", .{err});
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
        .tab_context_menu => if (is_down) {
            showActiveTabContextMenu() catch |err|
                std.log.err("failed to show keyboard tab context menu: {}", .{err});
        },
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

/// Cancel an in-progress local drag and clear its rendered selection. Mouse
/// capture is owned only while the drag is active, so releasing it here cannot
/// affect mouse reporting for a terminal-managed interaction.
fn cancelTerminalSelection(window: ?foundation.HWND) bool {
    const has_selection = model.core.screens.active.selection != null;
    const was_dragging = selection_dragging;
    if (!has_selection and !was_dragging) return false;

    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
    if (was_dragging) _ = user32.ReleaseCapture();
    if (has_selection) {
        model.clearSelection();
        if (window) |value| invalidateRenderDamage(value);
    }
    return true;
}

/// Windows sends these cancellation notifications when another window takes
/// capture (including during modal system interactions). The existing visual
/// selection remains available, but ttyrtle must no longer treat later mouse
/// motion as part of the abandoned drag.
fn cancelSelectionDrag() void {
    selection_dragging = false;
    selection_anchor = null;
    selection_head = null;
}

test "escape clears a local terminal selection" {
    var test_model: terminal.TerminalModel = undefined;
    try test_model.init(std.testing.allocator, 4, 16);
    defer test_model.deinit();

    const previous_dragging = selection_dragging;
    const previous_anchor = selection_anchor;
    const previous_head = selection_head;
    model = &test_model;
    selection_dragging = true;
    selection_anchor = null;
    selection_head = null;
    defer {
        model = undefined;
        selection_dragging = previous_dragging;
        selection_anchor = previous_anchor;
        selection_head = previous_head;
    }

    model.startSelection(1, 2);
    model.updateSelection(2, 4);

    try std.testing.expect(handleKeyMessage(wm.WM_KEYDOWN, 0x1b, 0));
    try std.testing.expect(model.core.screens.active.selection == null);
    try std.testing.expect(!selection_dragging);
    try std.testing.expect(selection_anchor == null);
    try std.testing.expect(selection_head == null);
}

test "capture cancellation stops a local selection drag" {
    const previous_dragging = selection_dragging;
    const previous_anchor = selection_anchor;
    const previous_head = selection_head;
    selection_dragging = true;
    selection_anchor = null;
    selection_head = null;
    defer {
        selection_dragging = previous_dragging;
        selection_anchor = previous_anchor;
        selection_head = previous_head;
    }

    cancelSelectionDrag();

    try std.testing.expect(!selection_dragging);
    try std.testing.expect(selection_anchor == null);
    try std.testing.expect(selection_head == null);
}

const ViewportShortcut = enum(u2) { page_up, page_down, top, bottom };

var held_viewport_shortcuts: std.EnumSet(ViewportShortcut) = .initEmpty();

/// Windows navigation shortcuts reserved for local history. Handle both press
/// and release so terminal applications never see a mismatched key sequence.
fn handleViewportKey(message: u32, virtual_key: usize, modifiers: input.Mods) bool {
    const is_key_message = message == wm.WM_KEYDOWN or message == wm.WM_SYSKEYDOWN or
        message == wm.WM_KEYUP or message == wm.WM_SYSKEYUP;
    if (!is_key_message) return false;
    const shortcut: ?ViewportShortcut = switch (virtual_key) {
        0x21 => .page_up,
        0x22 => .page_down,
        0x24 => .top,
        0x23 => .bottom,
        else => null,
    };
    const is_down = message == wm.WM_KEYDOWN or message == wm.WM_SYSKEYDOWN;
    if (!is_down) {
        const action = shortcut orelse return false;
        if (!held_viewport_shortcuts.contains(action)) return false;
        held_viewport_shortcuts.remove(action);
        return true;
    }
    const action = shortcut orelse return false;
    const modifier_matches = switch (action) {
        .page_up, .page_down => modifiers.shift,
        .top, .bottom => modifiers.ctrl,
    };
    if (!modifier_matches) return false;
    held_viewport_shortcuts.insert(action);
    {
        switch (action) {
            .page_up => model.scrollViewportPage(.up) catch {},
            .page_down => model.scrollViewportPage(.down) catch {},
            .top => model.scrollViewportTop() catch {},
            .bottom => model.scrollViewportBottom() catch {},
        }
        if (app_window) |window| invalidateRenderDamage(window);
    }
    return true;
}

test "viewport shortcuts consume release after modifier is released first" {
    var test_model: terminal.TerminalModel = undefined;
    try test_model.init(std.testing.allocator, 4, 16);
    defer test_model.deinit();
    try test_model.write("zero\r\none\r\ntwo\r\nthree\r\nfour");

    model = &test_model;
    defer model = undefined;
    const previous_window = app_window;
    app_window = null;
    defer app_window = previous_window;

    try std.testing.expect(handleViewportKey(
        wm.WM_KEYDOWN,
        0x21,
        .{ .shift = true },
    ));
    try std.testing.expect(handleViewportKey(wm.WM_KEYUP, 0x21, .{}));
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
    // Any input sent to the hosted application returns this tab to its live
    // viewport; output itself deliberately leaves a historical view alone.
    if (!model.viewportFollowsBottom()) model.scrollViewportBottom() catch {};
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

    if (message == wm.WM_MOUSEWHEEL and
        (model.core.flags.mouse_event == .none or currentModifiers().shift))
    {
        const wheel_delta: i32 = signedHighWord(wparam);
        if (wheel_delta != 0) {
            const lines = wheelScrollLines();
            const delta = wheel_scroll_accumulator.consume(wheel_delta, lines);
            model.scrollViewport(-delta) catch {};
            invalidateRenderDamage(window);
        }
        return;
    }

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

fn wheelScrollLines() u32 {
    var lines: u32 = 3;
    const param: *anyopaque = @ptrCast(&lines);
    if (user32.SystemParametersInfoW(wm.SPI_GETWHEELSCROLLLINES, 0, param, .{}) == 0)
        return 3;
    // WHEEL_PAGESCROLL is UINT_MAX; a page is the closest native equivalent.
    return if (lines == std.math.maxInt(u32)) @max(model.rows() -| 1, 1) else lines;
}

const WheelScrollAccumulator = struct {
    remainder: isize = 0,

    fn consume(self: *WheelScrollAccumulator, wheel_delta: i32, lines: u32) isize {
        const accumulated = self.remainder + @as(isize, wheel_delta);
        const detents = @divTrunc(accumulated, 120);
        self.remainder = accumulated - detents * 120;
        return detents * @as(isize, @intCast(lines));
    }
};

var wheel_scroll_accumulator: WheelScrollAccumulator = .{};

test "precision wheel deltas accumulate into complete scroll lines" {
    var accumulator: WheelScrollAccumulator = .{};
    var scrolled_lines: isize = 0;
    for (0..4) |_| scrolled_lines += accumulator.consume(30, 1);
    try std.testing.expectEqual(@as(isize, 1), scrolled_lines);
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
    if (renderer_failure_queued) return;
    const damage = model.damage();
    if (damage.rows == .none and !damage.cursor) return;
    switch (damage.rows) {
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
    scheduleFrameMessage(window);
}

fn scheduleFrameMessage(window: foundation.HWND) void {
    if (renderer_failure_queued) return;
    active_renderer.requestFrame();
    if (frame_message_pending) return;
    frame_message_pending = true;
    if (windowStateFromHwnd(window)) |state|
        state.frame_request_timestamp = frame_trace.timestamp();
    if (user32.PostMessageW(window, frame_message, 0, 0) == 0) {
        frame_message_pending = false;
        _ = user32.UpdateWindow(window);
    }
}

fn initializeRenderer(window: foundation.HWND, target: *renderer.Renderer) !void {
    target.initialize(window) catch |err| {
        showRendererFailure(window, err);
        return err;
    };
}

fn queueRendererFailure(window: foundation.HWND, failure: anyerror) void {
    if (renderer_failure_queued) return;
    renderer_failure_queued = true;
    renderer_failure = failure;
    frame_message_pending = false;
    if (user32.PostMessageW(window, renderer_failure_message, 0, 0) == 0)
        _ = user32.PostMessageW(window, wm.WM_CLOSE, 0, 0);
}

fn showRendererFailure(window: foundation.HWND, failure: anyerror) void {
    if (active_mode != .normal) return;
    const message = std.fmt.allocPrint(
        std.heap.smp_allocator,
        "Direct2D initialization or recovery failed ({s}).",
        .{@errorName(failure)},
    ) catch return;
    defer std.heap.smp_allocator.free(message);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(
        std.heap.smp_allocator,
        message,
    ) catch return;
    defer std.heap.smp_allocator.free(wide);
    _ = user32.MessageBoxW(
        window,
        wide,
        window_title,
        .{ .ICONHAND = 1 },
    );
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
    if (!model.viewportFollowsBottom()) try model.scrollViewportBottom();
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

/// Hidden-window dispatch binds the receiving WindowState before every
/// message. Keep synthetic modifier state there too so a test key sequence
/// sees the same modifiers on its press, repeat, and release messages.
fn setTestModifiers(window: foundation.HWND, modifiers: ?input.Mods) void {
    test_modifiers = modifiers;
    if (windowStateFromHwnd(window)) |state| state.test_modifiers = modifiers;
}

fn setTestContextMenuCommand(window: foundation.HWND, command: ?usize) void {
    test_context_menu_command = command;
    if (windowStateFromHwnd(window)) |state| state.test_context_menu_command = command;
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
    _ = user32.BeginPaint(window, &paint_state) orelse return false;
    defer _ = user32.EndPaint(window, &paint_state);

    const damage = model.damage();
    const cache_start = frame_trace.timestamp();
    const effective_damage = render_cache.updateEffective(
        model,
        terminal_metrics.*,
        damage,
    ) catch |err| {
        std.log.err("updating the retained render cache failed: {s}", .{@errorName(err)});
        return false;
    };
    cache_trace.recordSince(cache_start);
    const rendered = active_renderer.paint(
        render_cache,
        effective_damage,
        terminal_metrics.*,
        user32.GetDpiForWindow(window),
    ) catch |err| {
        std.log.err("painting the Direct2D frame failed: {s}", .{@errorName(err)});
        queueRendererFailure(window, err);
        return false;
    };
    if (rendered) render_cache.acknowledgeRendererPaint();
    if (rendered) if (windowStateFromHwnd(window)) |state| {
        if (state.oldest_pending_output_timestamp != 0) {
            state.output_to_present_trace.recordSince(state.oldest_pending_output_timestamp);
            state.oldest_pending_output_timestamp = 0;
        }
    };
    model.acknowledgeDamage();
    return rendered;
}

/// Keep a pixel-exact presentation target throughout a live resize. The
/// retained terminal scene remains valid and is clipped or surrounded by its
/// normal background until the final grid resize below.
fn resizePresentationForClient(window: foundation.HWND) !void {
    const surface = try surfaceForClient(window);
    commitSurfaceResize(window, surface);
}

/// A terminal viewport is entirely visible.  Unlike a document editor there
/// is no non-visible wrapping work to defer: a crossed cell boundary must
/// synchronously update the model and its retained command cache so the next
/// WM_PAINT always sees the current grid.
fn resizeForClient(window: foundation.HWND) !void {
    const surface = try surfaceForClient(window);
    commitSurfaceResize(window, surface);
    const dimensions = terminal_metrics.dimensions(
        @intCast(surface.width),
        @intCast(surface.height),
    ) orelse return;
    if (dimensions.rows == model.rows() and dimensions.columns == model.columns()) return;

    try resizeTerminalForDimensions(dimensions);
    // Ghostty resize is atomic and marks full damage. Copy that current state
    // now, rather than waiting for a timer that may be starved by WM_SIZE.
    const damage = model.damage();
    try render_cache.update(model, terminal_metrics.*, damage);
    model.acknowledgeDamage();
}

const SurfaceSize = struct {
    width: u32,
    height: u32,
    dpi: u32,
};

fn surfaceForClient(window: foundation.HWND) !SurfaceSize {
    if (!model_initialized) return error.ModelUnavailable;

    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0)
        return error.GetClientRectFailed;
    try layoutTabControl(window);
    repositionRenameEditor();
    return .{
        .width = @intCast(@max(client.right - client.left, 0)),
        .height = @intCast(@max(client.bottom - client.top, 0)),
        .dpi = if (windowStateFromHwnd(window)) |state| state.dpi else user32.GetDpiForWindow(window),
    };
}

fn resizeTerminalForDimensions(dimensions: geometry.Dimensions) !void {
    for (workspace_state.tabs.items) |tab| {
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
}

fn commitSurfaceResize(
    window: foundation.HWND,
    size: SurfaceSize,
) void {
    if (size.width == 0 or size.height == 0) return;
    _ = active_renderer.resize(size.width, size.height, size.dpi) catch |err| {
        queueRendererFailure(window, err);
        return;
    };
    // A resized swap-chain needs a complete client presentation even when the
    // terminal model has no dirty rows. GPU scene/cache content is retained.
    _ = user32.InvalidateRect(window, null, 0);
    scheduleFrameMessage(window);
}

fn handleConptyOutput(window: foundation.HWND, session_id: workspace.SessionId) void {
    const handler_entry = frame_trace.timestamp();
    const session = workspace_state.session(session_id) orelse return;
    const process = session.processAs(conpty.Session) orelse return;
    var batch = process.drainOutput() catch {
        std.log.err("failed to drain queued ConPTY output", .{});
        _ = process.beginClosing();
        return;
    };
    defer batch.deinit();
    if (windowStateFromHwnd(window)) |state| {
        if (batch.oldest_enqueue_timestamp != 0)
            state.queue_delay_trace.recordTicks(@max(
                handler_entry - batch.oldest_enqueue_timestamp,
                0,
            ));
        state.bytes_read +|= @intCast(batch.byte_count);
        state.bytes_parsed +|= @intCast(batch.byte_count);
        state.maximum_ui_batch = @max(state.maximum_ui_batch, batch.byte_count);
        state.continuation_count +|= @intFromBool(batch.continuation_required);
        state.maximum_backlog = @max(
            state.maximum_backlog,
            process.outputDiagnostics().maximum_backlog,
        );
        if (batch.oldest_enqueue_timestamp != 0 and
            (state.oldest_pending_output_timestamp == 0 or
                batch.oldest_enqueue_timestamp < state.oldest_pending_output_timestamp))
            state.oldest_pending_output_timestamp = batch.oldest_enqueue_timestamp;
    }

    const changed = batch.chunks.items.len != 0;
    if (changed) {
        applyOutputBatchForSession(window, session, batch.chunks.items, true) catch {
            std.log.err("failed to apply ConPTY output to the terminal model", .{});
            if (isIntegrationMode(active_mode)) beginWindowClose(window);
            return;
        };
        if (workspace_state.activeSession() == session) scheduleOutputFrame(window);
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
            beginWindowClose(window);
            return;
        };
    }

    if (batch.continuation_required and !process.postOutputContinuation()) {
        std.log.err("posting the bounded ConPTY output continuation failed", .{});
        _ = process.beginClosing();
        return;
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

    if (isMultiSessionIntegrationMode(active_mode) and batch.finished) {
        if (batch.failure != null) integration_multi_session.failed = true;
        _ = session.noteOutputFinished();
        finishMultiSessionIntegration(window);
    } else if (isIntegrationMode(active_mode) and batch.finished) {
        const marker = switch (active_mode) {
            .integration_input => integration_input_marker,
            .integration_resize => integration_resize_marker,
            else => integration_marker,
        };
        integration_succeeded = batch.failure == null and
            terminalContains(marker);
        beginWindowClose(window);
    } else if (batch.finished) {
        if (session.noteOutputFinished())
            closeTerminalTab(window, workspace_state.tabForSession(session.id).?.id);
    }
}

fn finishMultiSessionIntegration(window: foundation.HWND) void {
    const first_id = integration_multi_session.first orelse return;
    const second_id = integration_multi_session.second orelse return;
    const first = workspace_state.session(first_id) orelse {
        integration_multi_session.failed = true;
        beginWindowClose(window);
        return;
    };
    const second = workspace_state.session(second_id) orelse {
        integration_multi_session.failed = true;
        beginWindowClose(window);
        return;
    };
    if (!first.output_finished or !first.child_exited or
        !second.output_finished or !second.child_exited)
        return;

    integration_succeeded = !integration_multi_session.failed and
        workspace_state.activeSession() == second and
        terminalContainsForSession(first, integration_multi_first_marker) and
        terminalContainsForSession(second, integration_multi_second_marker) and
        nativeTabLabelEquals(first_id, integration_multi_first_title);
    beginWindowClose(window);
}

fn logDebugCounters() void {
    if (!frame_trace.enabled or active_mode != .normal) return;
    const application = active_application orelse return;
    const drag = application.tab_drag_diagnostics;
    std.log.info(
        "tab drag counters: candidates={d} started={d} canceled={d} completed={d} target_changes={d} indexed_transfers={d} tear_outs={d} rollback_attempts={d} rollback_failures={d} stale_requests={d}",
        .{ drag.candidates, drag.started, drag.canceled, drag.completed, drag.target_changes, drag.indexed_transfers, drag.tear_outs, drag.rollback_attempts, drag.rollback_failures, drag.stale_requests },
    );
    var captured: ?PerformanceSnapshot = null;
    for (application.windows.items) |state| if (state.performance_snapshot) |snapshot| {
        captured = snapshot;
        break;
    };
    const snapshot = captured orelse return;
    const terminal_counts = snapshot.terminal;
    const cache_counts = snapshot.cache;
    const renderer_counts = snapshot.renderer;
    std.log.info(
        "performance counters: batches={d} chunks={d} refreshes={d} core_resizes={d} " ++
            "dirty_rows={d} rebuilt_rows={d} scroll_reuses={d} scroll_reused_rows={d} full_rebuilds={d} layout_rebuilds={d} row_layout_cache_hits={d} row_layout_cache_evictions={d} " ++
            "rectangle_requests={d} rectangle_commands={d} " ++
            "frames_requested={d} frames_presented={d} " ++
            "gpu_presents={d} device_recreations={d} resize_messages={d} surface_resizes={d} scene_recreations={d} scene_redraws={d} " ++
            "cached_row_layout_draws={d} cached_cursor_layout_redraws={d} reflow_layout_builds={d} cursor_overlays={d} cursor_only_frames={d} unchanged_rows_skipped={d}",
        .{
            terminal_counts.output_batches,
            terminal_counts.chunks_parsed,
            terminal_counts.render_refreshes,
            terminal_counts.core_resizes,
            cache_counts.dirty_rows,
            cache_counts.rebuilt_rows,
            cache_counts.scroll_reuses,
            cache_counts.scroll_reused_rows,
            cache_counts.full_rebuilds,
            renderer_counts.layout_build_count,
            renderer_counts.layout_pool_hits,
            renderer_counts.layout_pool_evictions,
            cache_counts.rectangle_requests,
            cache_counts.rectangle_commands,
            renderer_counts.frames_requested,
            renderer_counts.frames_presented,
            renderer_counts.gpu_present_count,
            renderer_counts.gpu_recreation_count,
            snapshot.resize_messages,
            renderer_counts.surface_resize_count,
            renderer_counts.scene_recreation_count,
            renderer_counts.scene_redraw_count,
            renderer_counts.rows_drawn_from_cached_layouts,
            renderer_counts.cursor_redraws_from_cached_layouts,
            renderer_counts.reflow_layout_builds,
            renderer_counts.cursor_overlay_draws,
            renderer_counts.cursor_only_frames,
            cache_counts.unchanged_dirty_rows_skipped,
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
            "performance counters: batches={d} chunks={d} refreshes={d} core_resizes={d} " ++
                "dirty_rows={d} rebuilt_rows={d} scroll_reuses={d} scroll_reused_rows={d} full_rebuilds={d} layout_rebuilds={d} row_layout_cache_hits={d} row_layout_cache_evictions={d} " ++
                "rectangle_requests={d} rectangle_commands={d} " ++
                "frames_requested={d} frames_presented={d} " ++
                "gpu_presents={d} device_recreations={d} resize_messages={d} surface_resizes={d} scene_recreations={d} scene_redraws={d} " ++
                "cached_row_layout_draws={d} cached_cursor_layout_redraws={d} reflow_layout_builds={d} cursor_overlays={d} cursor_only_frames={d} unchanged_rows_skipped={d}",
            .{
                terminal_counts.output_batches,
                terminal_counts.chunks_parsed,
                terminal_counts.render_refreshes,
                terminal_counts.core_resizes,
                cache_counts.dirty_rows,
                cache_counts.rebuilt_rows,
                cache_counts.scroll_reuses,
                cache_counts.scroll_reused_rows,
                cache_counts.full_rebuilds,
                renderer_counts.layout_build_count,
                renderer_counts.layout_pool_hits,
                renderer_counts.layout_pool_evictions,
                cache_counts.rectangle_requests,
                cache_counts.rectangle_commands,
                renderer_counts.frames_requested,
                renderer_counts.frames_presented,
                renderer_counts.gpu_present_count,
                renderer_counts.gpu_recreation_count,
                snapshot.resize_messages,
                renderer_counts.surface_resize_count,
                renderer_counts.scene_recreation_count,
                renderer_counts.scene_redraw_count,
                renderer_counts.rows_drawn_from_cached_layouts,
                renderer_counts.cursor_redraws_from_cached_layouts,
                renderer_counts.reflow_layout_builds,
                renderer_counts.cursor_overlay_draws,
                renderer_counts.cursor_only_frames,
                cache_counts.unchanged_dirty_rows_skipped,
            },
        );
        writeTraceLine(
            trace_file,
            "output bytes: read={d} parsed={d} max_backlog={d} continuations={d} max_ui_batch={d}",
            .{ snapshot.bytes_read, snapshot.bytes_parsed, snapshot.maximum_backlog, snapshot.continuation_count, snapshot.maximum_ui_batch },
        );
        writeFrameTrace(trace_file, "output", snapshot.output_trace);
        writeFrameTrace(trace_file, "parse", terminal_counts.parse_trace);
        writeFrameTrace(
            trace_file,
            "render_state",
            terminal_counts.render_state_trace,
        );
        writeFrameTrace(trace_file, "damage", terminal_counts.damage_trace);
        writeFrameTrace(trace_file, "core_resize", terminal_counts.resize_trace);
        writeFrameTrace(trace_file, "queue_delay", snapshot.queue_delay_trace);
        writeFrameTrace(trace_file, "frame_delay", snapshot.frame_delay_trace);
        writeFrameTrace(trace_file, "output_to_present", snapshot.output_to_present_trace);
        writeFrameTrace(trace_file, "paint", snapshot.paint_trace);
        writeFrameTrace(trace_file, "cache", snapshot.cache_trace);
        writeFrameTrace(trace_file, "gpu", renderer_counts.gpu_paint_trace);
        writeFrameTrace(trace_file, "scene", renderer_counts.scene_trace);
        writeFrameTrace(trace_file, "layout", renderer_counts.layout_trace);
        writeFrameTrace(trace_file, "copy", renderer_counts.copy_trace);
        writeFrameTrace(trace_file, "present", renderer_counts.present_trace);
        writeFrameTrace(trace_file, "surface_resize", renderer_counts.surface_resize_trace);
    }
    logFrameTrace("output", snapshot.output_trace);
    logFrameTrace("parse", terminal_counts.parse_trace);
    logFrameTrace("render_state", terminal_counts.render_state_trace);
    logFrameTrace("damage", terminal_counts.damage_trace);
    logFrameTrace("core_resize", terminal_counts.resize_trace);
    logFrameTrace("queue_delay", snapshot.queue_delay_trace);
    logFrameTrace("frame_delay", snapshot.frame_delay_trace);
    logFrameTrace("output_to_present", snapshot.output_to_present_trace);
    logFrameTrace("paint", snapshot.paint_trace);
    logFrameTrace("cache", snapshot.cache_trace);
    logFrameTrace("gpu", renderer_counts.gpu_paint_trace);
    logFrameTrace("scene", renderer_counts.scene_trace);
    logFrameTrace("layout", renderer_counts.layout_trace);
    logFrameTrace("copy", renderer_counts.copy_trace);
    logFrameTrace("present", renderer_counts.present_trace);
    logFrameTrace("surface_resize", renderer_counts.surface_resize_trace);
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
    const line = std.fmt.allocPrint(
        std.heap.smp_allocator,
        format ++ "\r\n",
        args,
    ) catch |err| {
        std.log.err("formatting the frame trace failed: {s}", .{@errorName(err)});
        return;
    };
    defer std.heap.smp_allocator.free(line);
    var offset: usize = 0;
    while (offset < line.len) {
        var written: u32 = 0;
        if (kernel32.WriteFile(
            file,
            line.ptr + offset,
            @intCast(@min(line.len - offset, std.math.maxInt(u32))),
            &written,
            null,
        ) == 0 or written == 0) {
            std.log.err("writing the frame trace failed", .{});
            return;
        }
        offset += written;
    }
}

fn applyOutputBatch(window: foundation.HWND, chunks: []const []const u8) !void {
    try applyOutputBatchForSession(
        window,
        workspace_state.activeSession() orelse return,
        chunks,
        false,
    );
}

fn applyOutputBatchForSession(
    window: foundation.HWND,
    session: *workspace.TerminalSession,
    chunks: []const []const u8,
    defer_paint: bool,
) !void {
    const trace_start = frame_trace.timestamp();
    defer output_trace.recordSince(trace_start);
    try session.model.writeBatch(chunks);
    session.model.resetCursorBlink();
    applyTerminalEffectsForSession(window, session);
    if (workspace_state.activeSession() == session and !defer_paint)
        invalidateRenderDamage(window);
}

fn scheduleOutputFrame(window: foundation.HWND) void {
    invalidateRenderDamage(window);
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
        initial.gpu_present_count != before_initial.gpu_present_count + 1)
        return error.InitialGpuPaintDiagnosticsMismatch;

    try paintForTesting(window);
    const clean = active_renderer.diagnostics();
    if (clean.gpu_present_count != initial.gpu_present_count + 1 or
        clean.layout_build_count != initial.layout_build_count)
        return error.CleanPaintRebuiltLayouts;

    // The bundled Powerline separator reaches the right edge of its cell and
    // is followed by a blank. It must use the row layout path whose only
    // normal clip is the viewport/row clip, not a layout- or cell-bound clip.
    try model.write("\x1b[?25l\x1b[1;1H\xee\x82\xb2 ");
    const before_nerd = active_renderer.diagnostics();
    try paintForTesting(window);
    const after_nerd = active_renderer.diagnostics();
    if (after_nerd.layout_build_count > before_nerd.layout_build_count + 1 or
        after_nerd.rows_drawn_from_cached_layouts <= before_nerd.rows_drawn_from_cached_layouts)
        return error.NerdFontDidNotUseRowLayout;
    const nerd_overhang = active_renderer.nerdFontRightOverhangForTesting(
        terminal_metrics.*,
        user32.GetDpiForWindow(window),
    ) orelse return error.NerdFontOverhangProbeFailed;
    // DirectWrite reports this bundled glyph's ink within one DIP of the cell
    // boundary. A cell clip would visibly cut its antialiased right edge.
    if (nerd_overhang <= -1.0) return error.NerdFontRightEdgeMissing;

    // Every script keeps row-wide shaping while each grapheme is forced back
    // onto its terminal-cell boundary by the final spacing pass.
    try model.write(
        "\x1b[1;1Hgypq" ++
            "\x1b[2;1Hoffice" ++
            "\x1b[3;1He\xcc\x81" ++
            "\x1b[4;1H\xe7\x95\x8c" ++
            "\x1b[5;1H\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x92\xbb" ++
            "\x1b[6;1H\xd8\xb3\xd9\x84\xd8\xa7\xd9\x85" ++
            "\x1b[7;1H\xe0\xa4\x95\xe0\xa5\x8d\xe0\xa4\xb7" ++
            "\x1b[8;1H\xee\x82\xb2",
    );
    try paintForTesting(window);
    var saw_vertical_overhang = false;
    for (0..8) |row_index| {
        if (!active_renderer.rowGraphemeStartsOnGridForTesting(
            render_cache,
            row_index,
            terminal_metrics.*,
            user32.GetDpiForWindow(window),
        )) return error.GraphemeStartDidNotMatchTerminalGrid;
        const coverage = active_renderer.rowOverhangCoverageForTesting(row_index) orelse
            return error.RowOverhangCoverageUnavailable;
        if (coverage[0] > row_index or coverage[1] <= row_index or
            coverage[2] > coverage[0] or coverage[3] < coverage[1])
            return error.RowOverhangCoverageInvalid;
        if (coverage[0] < row_index or coverage[1] > row_index + 1)
            saw_vertical_overhang = true;
    }
    if (!saw_vertical_overhang) return error.DirectWriteReportedNoVerticalOverhang;

    // Every same-grid WM_SIZE must update the presentation target immediately
    // while retaining the existing layouts and scene pixels.
    var resize_outer: foundation.RECT = undefined;
    if (user32.GetWindowRect(window, &resize_outer) == 0)
        return error.GetWindowRectFailed;
    var resize_client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &resize_client) == 0)
        return error.GetClientRectFailed;
    const client_width = resize_client.right - resize_client.left;
    const usable_width = @max(
        client_width - @as(i32, @intCast(terminal_metrics.margin_x * 2)),
        0,
    );
    const cell_width: i32 = @intCast(terminal_metrics.cell_width);
    const remainder = @mod(usable_width, cell_width);
    const room_to_expand = cell_width - remainder - 1;
    const pixel_delta: i32 = if (room_to_expand >= 2) 1 else -1;
    const before_pixel_resize = active_renderer.diagnostics();
    const before_pixel_cache = render_cache.diagnostics();
    const initial_rows = model.rows();
    const initial_columns = model.columns();
    _ = user32.SendMessageW(window, wm.WM_ENTERSIZEMOVE, 0, 0);
    for ([_]i32{ pixel_delta, pixel_delta * 2, pixel_delta }) |offset| {
        if (user32.SetWindowPos(
            window,
            null,
            0,
            0,
            resize_outer.right - resize_outer.left + offset,
            resize_outer.bottom - resize_outer.top,
            .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
        ) == 0) return error.ResizeLifecycleFailed;

        if (model.rows() != initial_rows or model.columns() != initial_columns)
            return error.PixelResizeChangedTerminalGrid;
    }
    _ = user32.SendMessageW(window, wm.WM_EXITSIZEMOVE, 0, 0);
    const after_pixel_resize = active_renderer.diagnostics();
    if (after_pixel_resize.surface_resize_count !=
        before_pixel_resize.surface_resize_count + 3)
        return error.LiveResizeTargetCountMismatch;
    if (after_pixel_resize.scene_recreation_count !=
        before_pixel_resize.scene_recreation_count)
        return error.PixelResizeRecreatedScene;
    if (after_pixel_resize.scene_redraw_count !=
        before_pixel_resize.scene_redraw_count)
        return error.PixelResizeRedrewScene;
    if (after_pixel_resize.layout_build_count !=
        before_pixel_resize.layout_build_count)
        return error.PixelResizeDiscardedLayouts;
    if (render_cache.diagnostics().full_rebuilds != before_pixel_cache.full_rebuilds)
        return error.PixelResizeRebuiltRenderCache;

    // Cross several cell boundaries in one sizing loop. Both the presentation
    // target and terminal model must be current before WM_SIZE returns: a
    // terminal has no off-screen document lines which may be wrapped later.
    const before_crossed = active_renderer.diagnostics();
    _ = user32.SendMessageW(window, wm.WM_ENTERSIZEMOVE, 0, 0);
    const crossed_columns: i32 = @intCast(terminal_metrics.cell_width * 3);
    for ([_]i32{ crossed_columns, crossed_columns + cell_width, crossed_columns - cell_width }) |offset| {
        if (user32.SetWindowPos(
            window,
            null,
            0,
            0,
            resize_outer.right - resize_outer.left + offset,
            resize_outer.bottom - resize_outer.top,
            .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
        ) == 0) return error.ResizeLifecycleFailed;
        var current_client: foundation.RECT = undefined;
        if (user32.GetClientRect(window, &current_client) == 0)
            return error.GetClientRectFailed;
        const current = active_renderer.diagnostics();
        if (current.target_width != @as(u32, @intCast(current_client.right - current_client.left)) or
            current.target_height != @as(u32, @intCast(current_client.bottom - current_client.top)))
            return error.LiveResizeTargetWasNotExact;
        const current_grid = terminal_metrics.dimensions(
            @intCast(current_client.right - current_client.left),
            @intCast(current_client.bottom - current_client.top),
        ) orelse return error.ResizeDimensionsUnavailable;
        if (model.rows() != current_grid.rows or model.columns() != current_grid.columns)
            return error.LiveResizeDidNotApplyCurrentGrid;
    }
    const crossed_surface = try surfaceForClient(window);
    const crossed_grid = terminal_metrics.dimensions(
        @intCast(crossed_surface.width),
        @intCast(crossed_surface.height),
    ) orelse return error.ResizeDimensionsUnavailable;
    _ = user32.SendMessageW(window, wm.WM_EXITSIZEMOVE, 0, 0);
    try paintForTesting(window);
    const after_crossed = active_renderer.diagnostics();
    if (model.rows() != crossed_grid.rows or model.columns() != crossed_grid.columns)
        return error.LiveResizeDidNotSettle;
    if (after_crossed.scene_recreation_count > before_crossed.scene_recreation_count + 1)
        return error.LiveResizeRepeatedSceneAllocation;
    const reflow_builds = after_crossed.reflow_layout_builds -
        before_crossed.reflow_layout_builds;
    if (reflow_builds == 0 or reflow_builds > model.rows())
        return error.LiveResizeReflowDiagnosticsMismatch;

    model.startSelection(0, 0);
    const before_selection = active_renderer.diagnostics();
    try paintForTesting(window);
    const after_selection = active_renderer.diagnostics();
    // A completed staged reflow may retain a layout candidate that was moved
    // from the former grid; DirectWrite is allowed to warm at most one new
    // viewport worth of layouts here, never rebuild repeatedly per selection.
    if (after_selection.layout_build_count > before_selection.layout_build_count + model.rows())
        return error.SelectionRebuiltLayout;
    model.clearSelection();
    try paintForTesting(window);
    if (active_renderer.diagnostics().layout_build_count !=
        after_selection.layout_build_count)
        return error.SelectionClearRebuiltLayout;

    const clean_row_fingerprint = active_renderer.rowLayoutFingerprintForTesting(2) orelse
        return error.RowLayoutFingerprintUnavailable;
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
    if (after_batch.layout_build_count > before_batch.layout_build_count + 1)
        return error.DirtyRowLayoutRebuildWasNotProportional;
    if (active_renderer.rowLayoutFingerprintForTesting(2) != clean_row_fingerprint)
        return error.CleanRowLayoutFingerprintChanged;

    // ASCII and box drawing use the same row-wide shaping path. Mutating one
    // cell in every row builds at most one new layout per changed row.
    var sequence_buffer: [64]u8 = undefined;
    try model.write("\x1b[?25l\x1b[2J");
    for (0..model.rows()) |row_index| {
        const sequence = try std.fmt.bufPrint(
            &sequence_buffer,
            "\x1b[{d};1HASCII-{s}",
            .{ row_index + 1, "─" },
        );
        try model.write(sequence);
    }
    try paintForTesting(window);
    const before_direct_mutations = active_renderer.diagnostics();
    for (0..3) |frame| {
        for (0..model.rows()) |row_index| {
            const sequence = try std.fmt.bufPrint(
                &sequence_buffer,
                "\x1b[{d};2H{c}",
                .{ row_index + 1, @as(u8, @intCast('a' + frame)) },
            );
            try model.write(sequence);
        }
        try paintForTesting(window);
    }
    const after_direct_mutations = active_renderer.diagnostics();
    if (after_direct_mutations.gpu_present_count != before_direct_mutations.gpu_present_count + 3 or
        after_direct_mutations.layout_build_count >
            before_direct_mutations.layout_build_count + @as(u64, model.rows()) * 3 or
        after_direct_mutations.rows_drawn_from_cached_layouts <=
            before_direct_mutations.rows_drawn_from_cached_layouts)
        return error.RowLayoutMutationWasNotProportional;
    try model.write("\x1b[?25h");

    // Identical complete rows share one layout key. Editing either ordinary
    // text or a combining sequence introduces exactly one new row key.
    try model.write("\x1b[1;1HAe\xcc\x81\x1b[2;1HAe\xcc\x81");
    const before_mixed_warm = active_renderer.diagnostics();
    try paintForTesting(window);
    const after_mixed_warm = active_renderer.diagnostics();
    if (after_mixed_warm.layout_build_count != before_mixed_warm.layout_build_count + 1 or
        after_mixed_warm.layout_pool_hits <= before_mixed_warm.layout_pool_hits)
        return error.IdenticalRowsDidNotShareLayout;
    try model.write("\x1b[1;1HC");
    try paintForTesting(window);
    const after_direct_neighbor = active_renderer.diagnostics();
    if (after_direct_neighbor.layout_build_count != after_mixed_warm.layout_build_count + 1)
        return error.RowTextMutationDidNotBuildOneLayout;
    try model.write("\x1b[1;2Ha\xcc\x81");
    try paintForTesting(window);
    if (active_renderer.diagnostics().layout_build_count !=
        after_direct_neighbor.layout_build_count + 1)
        return error.CombiningMutationDidNotBuildOneLayout;

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
            before_invalidation.layout_build_count or
        after_invalidation.reflow_layout_builds !=
            before_invalidation.reflow_layout_builds)
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
    if (after_dpi_paint.gpu_present_count != before_dpi_paint.gpu_present_count + 1)
        return error.DpiChangeDidNotPresent;

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
    }
    // This models a real output burst: terminal state is updated for every
    // chunk, but only one frame is presented after coalescing the burst.
    try paintForTesting(window);
    if (kernel32.QueryPerformanceCounter(&scroll_end) == 0)
        return error.PerformanceCounterUnavailable;
    const after_scroll = active_renderer.diagnostics();
    if (after_scroll.gpu_present_count !=
        before_scroll.gpu_present_count + 1)
        return error.ScrollingPresentationCountMismatch;
    const scroll_milliseconds = @divTrunc(
        (scroll_end.QuadPart - scroll_start.QuadPart) * 1000,
        frequency.QuadPart,
    );
    if (scroll_milliseconds > 3_000)
        return error.DebugScrollingNotResponsive;

    // Thousands of coalesced cursor movements must remain overlay-only after
    // the retained rows and DirectWrite layouts are warm.
    const cursor_fixture = ("\x1b[2;2H\x1b[3;3H" ** 1000) ++ "\x1b[4;5H";
    const before_cursor_cache = render_cache.diagnostics();
    const before_cursor = active_renderer.diagnostics();
    try model.write(cursor_fixture);
    try paintForTesting(window);
    const after_cursor_cache = render_cache.diagnostics();
    const after_cursor = active_renderer.diagnostics();
    if (model.cursor().row != 3 or model.cursor().column != 4)
        return error.CursorFixturePositionMismatch;
    if (after_cursor_cache.rebuilt_rows != before_cursor_cache.rebuilt_rows or
        after_cursor.layout_build_count != before_cursor.layout_build_count or
        after_cursor.scene_redraw_count != before_cursor.scene_redraw_count or
        after_cursor.cursor_only_frames != before_cursor.cursor_only_frames + 1 or
        after_cursor.cursor_overlay_draws != before_cursor.cursor_overlay_draws + 1)
        return error.CursorFixtureRebuiltRetainedContent;

    const before_loss = active_renderer.diagnostics();
    if (!active_renderer.simulateTargetLossForTesting())
        return error.GpuRendererUnavailable;
    try paintForTesting(window);
    const after_loss = active_renderer.diagnostics();
    if (after_loss.gpu_recreation_count != before_loss.gpu_recreation_count or
        after_loss.gpu_present_count != before_loss.gpu_present_count + 1 or
        after_loss.scene_recreation_count != before_loss.scene_recreation_count + 1 or
        after_loss.layout_build_count != before_loss.layout_build_count or
        after_loss.reflow_layout_builds != before_loss.reflow_layout_builds or
        after_loss.layout_pool_hits <= before_loss.layout_pool_hits)
        return error.TargetLossRecoveryDiagnosticsMismatch;
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
        mode == .smoke_phase5 or
        mode == .smoke_tabs or
        mode == .smoke_shortcuts or
        mode == .smoke_rename or
        mode == .smoke_tab_interactions or
        mode == .smoke_tab_drag or
        mode == .smoke_cross_window_drag or
        mode == .smoke_multi_window or
        mode == .smoke_transfer_hardening;
}

fn isIntegrationMode(mode: Mode) bool {
    return switch (mode) {
        .integration,
        .integration_input,
        .integration_resize,
        .integration_multi_session,
        .integration_multi_resize,
        => true,
        else => false,
    };
}

fn isMultiSessionIntegrationMode(mode: Mode) bool {
    return mode == .integration_multi_session or mode == .integration_multi_resize;
}

fn verifyMultiSessionResizeAndDpi(window: foundation.HWND) !void {
    if (workspace_state.tabs.items.len != 2)
        return error.MultiSessionResizeTabCountMismatch;

    var outer: foundation.RECT = undefined;
    if (user32.GetWindowRect(window, &outer) == 0)
        return error.GetWindowRectFailed;
    if (user32.SetWindowPos(
        window,
        null,
        0,
        0,
        outer.right - outer.left + 173,
        outer.bottom - outer.top + 91,
        .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
    ) == 0) return error.SetWindowPosFailed;
    try expectAllSessionDimensions(window);

    if (user32.GetWindowRect(window, &outer) == 0)
        return error.GetWindowRectFailed;
    const target_dpi: u16 = if (user32.GetDpiForWindow(window) == 144) 96 else 144;
    const suggested: foundation.RECT = .{
        .left = outer.left,
        .top = outer.top,
        .right = outer.right,
        .bottom = outer.bottom,
    };
    _ = user32.SendMessageW(
        window,
        wm.WM_DPICHANGED,
        @as(usize, target_dpi) | (@as(usize, target_dpi) << 16),
        @bitCast(@intFromPtr(&suggested)),
    );
    try expectAllSessionDimensions(window);
}

fn exerciseStaleSessionNotifications(window: foundation.HWND) !void {
    const stale_session = workspace_state.activeSession() orelse
        return error.StaleNotificationMissingSession;
    const stale_tab = workspace_state.tabForSession(stale_session.id) orelse
        return error.StaleNotificationMissingTab;
    const stale_session_id = stale_session.id;
    const stale_tab_id = stale_tab.id;
    try createIntegrationTerminalTab(window, integration_host_close_command);
    closeTerminalTab(window, stale_tab_id);
    if (workspace_state.session(stale_session_id) != null)
        return error.StaleNotificationSessionWasNotRemoved;
    if (active_application) |application|
        _ = application.model.session_owners.remove(stale_session_id);
    const receiver = notification_window orelse return error.StaleNotificationReceiverUnavailable;

    inline for ([_]u32{
        conpty.output_message,
        conpty.child_exit_message,
        conpty.input_failure_message,
    }) |message| {
        _ = user32.SendMessageW(receiver, message, @intFromEnum(stale_session_id), 0);
    }
    if (workspace_state.tabs.items.len != 1)
        return error.StaleNotificationChangedWorkspace;
}

fn expectAllSessionDimensions(window: foundation.HWND) !void {
    var client: foundation.RECT = undefined;
    if (user32.GetClientRect(window, &client) == 0)
        return error.GetClientRectFailed;
    const expected = terminal_metrics.dimensions(
        client.right - client.left,
        client.bottom - client.top,
    ) orelse return error.MultiSessionResizeDimensionsUnavailable;

    for (workspace_state.tabs.items) |tab| {
        const session = tab.root.terminalSession();
        if (session.model.columns() != expected.columns or session.model.rows() != expected.rows)
            return error.MultiSessionModelResizeMismatch;
        const process = session.processAs(conpty.Session) orelse
            return error.MultiSessionProcessMissing;
        if (!std.meta.eql(process.dimensions, expected))
            return error.MultiSessionConptyResizeMismatch;
    }
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
    return terminalContainsForSession(workspace_state.activeSession() orelse return false, needle);
}

fn terminalContainsForSession(session: *workspace.TerminalSession, needle: []const u8) bool {
    const session_model = &session.model;
    for (0..session_model.rows()) |row| {
        for (0..session_model.columns()) |start| {
            if (start + needle.len > session_model.columns()) break;
            for (needle, start..) |expected, column| {
                const cell = session_model.cell(row, column) orelse break;
                if (cell.spacer or cell.codepoint != expected) break;
            } else return true;
        }
    }
    return false;
}

fn nativeTabLabelEquals(id: workspace.SessionId, expected: []const u8) bool {
    const tab = workspace_state.tabForSession(id) orelse return false;
    const index = nativeIndexForTab(tab.id) orelse return false;
    const control = tab_control orelse return false;
    var text: [256:0]u16 = std.mem.zeroes([256:0]u16);
    var item: controls.TCITEMW = .{
        .mask = .{ .TEXT = 1 },
        .dwState = controls.TCIS_BUTTONPRESSED,
        .dwStateMask = controls.TCIS_BUTTONPRESSED,
        .pszText = text[0.. :0].ptr,
        .cchTextMax = text.len,
        .iImage = -1,
        .lParam = 0,
    };
    if (user32.SendMessageW(control, controls.TCM_GETITEMW, index, @bitCast(@intFromPtr(&item))) == 0)
        return false;
    const label = std.unicode.utf16LeToUtf8Alloc(
        std.heap.smp_allocator,
        std.mem.sliceTo(item.pszText.?, 0),
    ) catch return false;
    defer std.heap.smp_allocator.free(label);
    return std.mem.eql(u8, label, expected);
}

test "move destination snapshot contains only other live stable windows" {
    var application = Application.init(std.testing.allocator, .normal);
    defer application.deinit();

    const source_model = try application.model.createWindow();
    const destination_model = try application.model.createWindow();
    const closing_model = try application.model.createWindow();
    try std.testing.expect(application.model.markLive(source_model.id));
    try std.testing.expect(application.model.markLive(destination_model.id));
    try std.testing.expect(application.model.markLive(closing_model.id));
    closing_model.lifecycle = .closing;

    for ([_]*workspace.Window{ source_model, destination_model, closing_model }) |model_window| {
        const state = try std.testing.allocator.create(WindowState);
        state.* = .init(&application, model_window);
        try application.windows.append(std.testing.allocator, state);
    }

    var snapshot: std.ArrayListUnmanaged(workspace.WindowId) = .empty;
    defer snapshot.deinit(std.heap.smp_allocator);
    try appendMoveDestinations(&snapshot, application.windows.items[0]);
    try std.testing.expectEqualSlices(workspace.WindowId, &.{destination_model.id}, snapshot.items);
}
