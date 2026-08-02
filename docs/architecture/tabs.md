# Tabs

## Decision

Ttyrtle will keep tabs in its own workspace model and present them with one
native Win32 tab control (`WC_TABCONTROL`) per top-level window.

The workspace model is the source of truth. The Win32 control is a view and
input surface: it displays labels and icons, reports selection changes, and
provides standard tab sizing, overflow, hit testing, keyboard behavior,
tooltips, and an accessibility baseline. It does not own terminal sessions or
determine their lifetime.

Start with the standard native appearance. The control is subclassed for
middle-click close, focus restoration, and drag reordering; it otherwise
retains native painting, selection, overflow, and accessibility behavior. Add
owner drawing only when required for close buttons, pin or activity indicators,
and application themes. Notepad++ follows this general hybrid
approach: its `TabBarPlus` extends an owner-drawn, subclassed
`WC_TABCONTROL` rather than replacing the control.

References:

- [Microsoft: About Tab Controls](https://learn.microsoft.com/en-us/windows/win32/controls/tab-controls)
- [Notepad++ TabBar implementation](https://github.com/notepad-plus-plus/notepad-plus-plus/blob/master/PowerEditor/src/WinControls/TabBar/TabBar.cpp)

## Ownership

The intended ownership hierarchy is:

```text
Application
└── Window
    ├── native tab-control HWND
    ├── renderer
    └── Workspace
        └── Tab
            └── PaneNode
                ├── terminal session
                └── split with two child PaneNodes
```

Each top-level window owns one workspace and one tab-control child window. A
tab owns a pane-layout root from the beginning, even while only a single
terminal pane is supported. This avoids changing tab ownership when split panes
are introduced.

Terminal panes do not need individual child windows. The application can divide
the terminal client area into pane rectangles and render them through the
window's existing Direct2D renderer.

## Model

The exact Zig types may evolve, but the model should express these
relationships:

```zig
const Workspace = struct {
    // Heap-stable tab owners permit an entire pane root to move without
    // copying the terminal session or its process ownership.
    tabs: std.ArrayListUnmanaged(*Tab),
    active_tab_id: TabId,
};

const Tab = struct {
    id: TabId,
    title_override: ?[]u8,
    root: PaneNode,
};

const PaneNode = union(enum) {
    terminal: TerminalSession,
    split: Split,
};

const Split = struct {
    direction: enum { horizontal, vertical },
    ratio: f32,
    first: *PaneNode,
    second: *PaneNode,
};
```

Tabs and sessions require stable identifiers. Array positions and tab-control
indices are transient presentation details and must not be used as identity.
This is especially important when tabs are reordered or moved between windows
and when asynchronous ConPTY messages arrive.

## Synchronization with Win32

Each native tab item associates its `TCITEM.lParam` application data with the
corresponding stable `TabId`. The view resolves tab-control indices through
that identifier rather than assuming the native and model indices will always
remain identical.

The interaction flow is:

1. A workspace operation creates, closes, renames, or reorders a `Tab`.
2. The window synchronizes the native tab items from the resulting model.
3. `TCN_SELCHANGE` resolves the selected item's `TabId` and updates
   `Workspace.active_tab_id`.
4. The window resizes and invalidates the active tab's terminal or pane layout.

Programmatic selection must update both sides without treating the resulting
notification as a second model operation.

Closing a tab first removes it from the workspace and begins orderly teardown
of all terminal sessions in its pane tree. Destroying a window closes its
workspace only after tabs intended for another window have been detached.
Moving a tab transfers the same tab and pane tree to the destination workspace;
it must not restart the contained terminal sessions.

## Extended behavior

The native control does not by itself implement the complete ttyrtle tab
experience. Application code remains responsible for:

- close buttons and their hit regions;
- moving tabs between top-level windows;
- editable or overridden names;
- process, working-directory, bell, and activity status;
- pinned-tab policy, if introduced;
- theme-specific drawing and high-contrast verification;
- commands, hotkeys, and command-palette actions;
- orderly session teardown and focus transfer.

When owner drawing is enabled, keep the native tab items and selection
semantics intact. Custom painting should not turn the tab strip into an
unrelated custom widget or discard the accessibility benefits of using the
standard control.

## Implementation status

Same-window tabs are complete. Their implementation and verification record is
the [runtime-tabs plan](runtime-tabs-plan.md). Unit tests cover workspace
operations without Win32; hidden-window integration tests cover native selection
and drag notifications, multiple asynchronous sessions, resize/DPI propagation,
and repeated teardown.

The multiple-window transfer milestone is in progress. The model now allocates
each `Tab` separately, uses application-wide `WindowId`/`SessionId` routing,
and prepares every destination allocation before detaching a tab. Its commit
moves the existing `*Tab` and pane root without allocation, then updates the
existing session routes. The application also creates a message-only ConPTY
notification receiver before it starts a session. Cross-window dragging and
tear-out remain deferred.

The feature-work tracker in [todo.md](../../todo.md) is the authoritative place
for status and plans for future work, including cross-window transfer, panes,
owner-drawn tab affordances, and activity/status behavior.
