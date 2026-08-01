# Finish Runtime Tabs

## Goal

Complete same-window tabs on top of `Workspace` and the native
`WC_TABCONTROL`. Tabs own independent terminal models and ConPTY sessions,
continue processing output while inactive, and support creation, closing,
switching, naming, status labels, and drag reordering.

Cross-window transfer, panes, owner-drawn close buttons, shell
working-directory integration, configurable hotkeys, and activity indicators
remain out of scope for this milestone.

## Progress summary

The runtime lifecycle is implemented and tested: each tab has its own terminal
model and ConPTY process, output is routed by stable session ID even when the
tab is inactive, resizing applies to every session, and the native strip stays
synchronized for creation, close, and selection. The standard control is
subclassed only for middle-click close and focus restoration.

Inline rename, context menus, and drag reordering are the primary remaining
same-window tab work.

## Implementation work

### 1. Session-safe asynchronous ConPTY events

- [x] Extend `conpty.Session.create` with a stable notification token derived
  from `SessionId`; output, child-exit, and input-failure messages carry it in
  `wParam`.
- [x] Add `SessionId -> TerminalSession` and `SessionId -> Tab` workspace
  lookup helpers. Ignore notifications after their tab has been removed.
- [x] Replace the global output-finished state with per-session EOF state.
- [x] Drain output into the originating model while inactive; apply title and
  bell effects to that model and repaint only when it is active.
- [x] Wait for both child exit and output EOF before automatic normal-mode
  close, preserving final buffered output.
- [x] Keep existing marker-based integration completion behavior explicit.

### 2. Tab/session lifecycle actions

- [x] Create a terminal tab with dimensions from the client area, a new model,
  a default-shell ConPTY session, reply sink, native synchronization, active
  selection, and terminal focus.
- [x] Roll back a newly created tab when ConPTY startup or process attachment
  fails.
- [x] Activate by stable `TabId`, reset input/selection state, rebuild the
  render cache, invalidate retained GPU terminal content, update native
  selection/caption, and repaint.
- [x] Close a tab idempotently, tear down only its process, select the nearest
  remaining tab, synchronize the strip, and close the window when no tabs
  remain.
- [ ] Reorder by stable ID, rebuild the native list, and restore the active
  selection. The workspace model already supports reordering; UI interaction
  remains to be added.
- [x] Resize every terminal model and attached ConPTY session on window-size
  and DPI changes.
- [x] On `WM_CLOSE`, tear down all workspace sessions exactly once.

### 3. Labels, titles, and inline renaming

- [x] Use the effective-label policy: explicit override, then OSC title, then
  `"Terminal"`.
- [x] Update only the affected native item after an OSC title change.
- [x] Use active explicit/OSC titles for the window caption, falling back to
  `"ttyrtle"`.
- [x] Subclass the native tab control while retaining standard control
  painting, selection, focus, overflow, and accessibility behavior.
- [x] On double-click, create a temporary Unicode `EDIT` over the tab label.
- [x] Commit Enter/focus-loss edits, cancel Escape, trim whitespace, clear an
  empty override, update the item/caption, and restore terminal focus.
- [x] Cancel or reposition an active editor safely for close, reorder, resize,
  and DPI changes.

### 4. Native interactions and shortcuts

- [x] Implement `Ctrl+Shift+T` and `Ctrl+Shift+W`.
- [x] Implement wrapping `Ctrl+Tab` / `Ctrl+Shift+Tab` and `Alt+1`–`Alt+9`.
- [x] Preserve ordinary `Ctrl+W` for the hosted terminal.
- [x] Middle-click closes the hit-tested tab and restores terminal focus.
- [x] Consume both press/release messages for handled shortcuts and suppress
  matching `WM_CHAR` messages so shortcut input cannot reach ConPTY.
- [x] Prevent held-key repeats for create/close while allowing repeat cycling.
- [ ] Right-click: select the hit tab and show a native `New Tab`, `Rename`,
  `Close` popup; support keyboard invocation anchored to the active tab.
- [ ] Left-button drag: record a stable-ID candidate, begin after the system
  drag threshold, capture the mouse, reorder on tab-boundary crossings, allow
  drops before/after the visible range, and cancel/reset reliably.

## Tests

### Unit tests

- [x] Resolve sessions and owning tabs by stable session ID; removed/unknown
  IDs return null.
- [x] Verify active-tab nearest-neighbor selection and process ownership.
- [x] Verify reordering preserves model/session identity and completion state.
- [x] Verify explicit title overrides take precedence and clearing restores an
  OSC title.
- [x] Add a direct per-session child-exit/output-EOF order test.
- [x] Add direct create-tab rollback tests using injected startup/attachment
  failures.

### Hidden Win32 integration tests

- [x] Verify native tab count, stable `lParam` identities, selection changes,
  runtime tab creation/activation, and close synchronization.
- [x] Verify the existing finite-session, resize, input, and host-close paths.
- [ ] Exercise shortcut dispatch itself (rather than its shared lifecycle
  helpers), including release/character suppression.
- [ ] Exercise rename commit/cancel/reset, middle-click close, context-menu
  actions, and drag reordering in both directions.
- [ ] Start multiple finite ConPTY sessions with distinct markers and verify
  inactive output, background OSC labels, and EOF/exit arrival in either
  order.
- [ ] Verify multi-session resize/DPI dimensions and repeated window close
  without stale-message dereferences.

## Documentation and completion

- [x] Update the README with implemented tab shortcuts and current limits.
- [x] Update `todo.md` and `docs/architecture/tabs.md` with current progress.
- [ ] Mark the user-facing tabs TODO fully complete only after inline naming,
  drag reordering, status behavior, and their tests pass.
- [ ] Keep multiple windows/cross-window tab movement, panes, richer process
  and CWD integration, owner-drawn close buttons, configurable hotkeys, and
  large-tab stress testing as future work.

## Verification

Run before handing off or committing tab work:

```powershell
zig fmt build.zig src test
zig build verify
```
