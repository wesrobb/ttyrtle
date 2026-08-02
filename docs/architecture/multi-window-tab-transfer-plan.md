# Multiple top-level windows and tab transfer

## Goal

Support multiple independent native top-level Windows and command-driven moves
of running tabs between them. Moving a tab transfers the existing tab and its
complete pane-layout root; it does not recreate the Ghostty model, ConPTY,
child process, title, scrollback, selection, or future pane state.

This milestone also makes session retirement asynchronous. Closing a tab or
window must remove its visible UI promptly while ConPTY shutdown, worker joins,
and terminal-model destruction finish outside the UI thread. The application
notification receiver and message loop remain alive until all retiring
sessions are unable to post further notifications.

The implementation remains native and direct:

- one unowned `WS_OVERLAPPEDWINDOW` and one `WC_TABCONTROL` per top-level
  window;
- one UI thread and message pump for all windows;
- stable application identities rather than HWNDs or native indices as model
  identity;
- Ghostty owns terminal semantics and model state;
- the application owns Win32 integration, pane placement, rendering, ConPTY,
  input routing, transfer, and retirement.

## Scope

Included:

- multiple live top-level windows with independent workspaces, renderers, DPI,
  input state, focus, captions, tab controls, and timers;
- `Ctrl+Shift+N` and native menu commands for a new window;
- native tab-menu commands to move a tab to a new window or another existing
  window;
- transfer of the same tab, pane root, terminal models, ConPTY handles, and
  child processes;
- application-lifetime asynchronous notification routing;
- non-blocking tab/window close and background session cleanup;
- Per-Monitor V2 DPI awareness and cross-DPI transfer behavior;
- explicit application/terminal/system key routing;
- unit, hidden-window integration, failure-injection, performance, DPI,
  lifecycle, renderer-cost, accessibility, and manual tests.

Deferred:

- cross-window tab dragging and tab tear-out;
- pane creation, split rendering, split focus commands, and split resizing;
- owner-drawn tab affordances;
- process-status UI and close confirmation policy;
- configurable shortcuts.

Same-window drag reordering remains supported. Cross-window drag and tear-out
will be a follow-up built on the transfer coordinator from this milestone.

## Current implementation constraints

The existing model already provides stable `TabId` and `SessionId` values. A
`Tab` owns a `PaneNode`, and the current terminal node points to a heap-stable
`TerminalSession`. Same-window reorder preserves session identity, native tab
items store `TabId` in `TCITEM.lParam`, and inactive sessions process output by
stable `SessionId`.

The application layer is still single-window:

- `app.zig` stores one workspace, top-level HWND, tab control, renderer,
  render cache, DPI value, input translator, selection state, rename editor,
  drag state, timers, and diagnostic counters in process globals;
- every `WM_DESTROY` posts `WM_QUIT`;
- `conpty.Session` stores the top-level HWND that created it and its worker
  threads post notifications directly to that HWND;
- `Workspace.closeTab` destroys its sessions synchronously;
- `conpty.Session.destroy` performs waits, cancellation, thread joins, and
  handle cleanup synchronously;
- resize, close, lookup, and label paths assume the pane root contains exactly
  one terminal.

Those constraints must be removed before cross-window ownership is exposed.

## Platform decision

This milestone supports 64-bit x86 Windows only.

`SessionId` is a `u64` carried losslessly in `WPARAM`, whose Zig type is
`usize`. The build must reject non-Windows and non-`x86_64` application targets
with a clear diagnostic, and a compile-time assertion must document that the
notification token can represent every `SessionId`. CI continues to build the
supported x64 target.

A future 32-bit port must introduce a dispatcher-owned 32-bit notification
token table or carry an allocated notification record rather than truncating a
`SessionId`. Silent truncation is not permitted. ARM64 support is also deferred
until it is deliberately built and tested.

## Ownership model

```text
Application
├── notification HWND (message-only, application lifetime)
├── application-wide WindowId, TabId, and SessionId sources
├── WindowId -> *WindowState registry
├── SessionId -> SessionOwner registry
├── RetirementManager and bounded cleanup workers
└── WindowState (heap-stable, one per top-level HWND)
    ├── top-level HWND and native tab-control HWND
    ├── lifecycle state
    ├── Workspace
    │   └── *Tab
    │       ├── stable TabId and title override
    │       ├── embedded retirement record
    │       └── PaneNode root
    │           └── one or more TerminalSession objects
    ├── renderer and active presentation cache
    ├── DPI metrics and last valid client geometry
    ├── input, shortcut, focus, mouse, and selection state
    ├── rename editor and same-window drag state
    └── cursor/output timers and per-window diagnostics
```

### Application ownership

`Application` owns class registration, the message-only receiver, the message
pump, all stable ID sources, live-window enumeration, session-owner routing,
the retirement manager, transfer coordination, application commands, and
test-run state.

Window and session registries use stable IDs. HWNDs are transient platform
handles and are never sufficient identity because Windows may reuse them.

### Window ownership

Every HWND-bound or active-view value belongs to `WindowState`: workspace,
renderer, render cache, DPI metrics, client geometry, native children, input
translator, shortcut-held state, wheel accumulator, focus recipient,
selection-drag state, rename editor, same-window drag state, timers, and
window-level diagnostics.

`WindowState` is allocated at a stable address before `CreateWindowExW`. Its
pointer is passed in `lpParam`, installed in `GWLP_USERDATA` during
`WM_NCCREATE`, and passed as subclass reference data to child controls.

### Tab and pane ownership

Change workspace storage from relocatable `Tab` values to heap-stable `*Tab`
owners. This provides one explicit ownership object that can move between
workspaces or be handed to the retirement manager without copying internal
owners.

A tab owns its entire `PaneNode` root. Transfer never reconstructs or walks the
tree to create a replacement. Pane traversal is used only to register, find,
resize, focus, close, or retire terminal leaves.

Add traversal helpers such as:

- `PaneNode.forEachTerminalSession`;
- `PaneNode.sessionById`;
- `Tab.forEachTerminalSession`;
- `Workspace.tabForSession`.

They initially handle only `.terminal`. The pane milestone will extend the
same functions recursively for `.split`, so the transfer algorithm itself
does not change. Future split ratios, focused-pane identity, and pane metadata
must live under `Tab` and therefore move automatically.

### Presentation ownership

Direct2D, DirectWrite, DXGI, GDI, and render-command cache resources remain
owned by their window. They never move with a tab. After transfer, source and
destination rebuild only the presentation state needed for their active tabs
from the preserved terminal models.

## Window lifecycle state machine

Each `WindowState` has an explicit state:

```text
constructing -> live -> transferring -> live
      |           |          |          |
      +-----------+----------+--------> closing -> destroyed
```

### `constructing`

- The heap object and `WindowId` exist; HWND creation may be partial.
- `GWLP_USERDATA` may be installed, but child controls, renderer, workspace,
  or active tab may not yet exist.
- The window is not included in move-destination menus.
- A receiver for “Move Tab to New Window” is created hidden and may have an
  empty workspace.
- `WM_NCCREATE`, `WM_CREATE`, `WM_SIZE`, `WM_DPICHANGED`, `WM_PAINT`, theme,
  and non-client callbacks must tolerate missing child controls and no active
  model.
- Paint validates the region and clears to the normal background when no model
  exists. Resize records geometry and DPI but does not dereference an active
  tab.
- The state becomes `live` only after the HWND, tab control, subclass,
  renderer/fallback, workspace contents, native tab view, initial layout, and
  application registries are coherent.
- Failure transitions through `closing` to `destroyed` without showing the
  window. A source tab has not yet been detached, so its semantics are
  unchanged.

### `live`

- The window appears in destination menus and accepts normal application,
  terminal, focus, tab, paint, resize, and close actions.
- A visible live window has at least one tab.
- Its session registry entries resolve to this `WindowId`.

### `transferring`

- Source and destination enter this state together under one application-level
  `TransferTransaction`.
- No second tab/workspace mutation may begin on either window.
- Application commands, tab notifications, rename commits, and same-window
  reorder requests that would mutate either workspace are deferred or ignored.
- Paint, size, DPI, focus, activation, non-client, and accessibility callbacks
  remain safe. They may record `needs_layout`, `needs_repaint`,
  `pending_focus_change`, or `close_requested`, but cannot allocate or mutate
  workspace ownership during the commit interval.
- No application code enters a nested message loop after detach. Native
  `SendMessageW`, `SetFocus`, `SetWindowPos`, tab-control notifications, and
  destruction may still synchronously reenter callbacks, so every callback
  checks lifecycle state before accessing workspace or presentation state.
- The model commit is short and allocation-free. There is no user-visible
  detached interval.
- Deferred resize, focus, close, caption, and repaint actions are applied after
  both workspaces and registries are coherent and both states return to
  `live`, or after a source transitions directly to `closing` because it is
  empty.

### `closing`

- The window is removed from destination-menu enumeration immediately.
- It rejects new tabs, new transfers, terminal input, rename, and reorder.
- Its timers, capture, rename editor, focus recipient, and child-control
  interactions are cancelled exactly once.
- Remaining tabs are detached and queued for asynchronous retirement without
  waiting for ConPTY or worker threads.
- `WM_PAINT` remains valid and may clear the client; other reentrant messages
  delegate to safe cleanup handling or `DefWindowProcW`.
- Repeated `WM_CLOSE`, child exit, output EOF, and destroy requests are
  idempotent.

### `destroyed`

- `WM_NCDESTROY` clears `GWLP_USERDATA`, unregisters the HWND and `WindowId`,
  and marks the state destroyed.
- No registry or queued command may resolve it as a destination.
- Memory is reclaimed only after the current window-procedure invocation has
  unwound, using an application deferred-free queue. A callback never frees the
  state object it is still executing against.
- Destruction of one window does not post `WM_QUIT` while another window is
  live or any retirement is pending.

## Reentrant callback invariants

All model and registry mutation remains on the UI thread, but that does not
make calls non-reentrant. The implementation must obey these invariants:

1. A callback resolves `WindowState` once from `GWLP_USERDATA` and validates
   its lifecycle before use.
2. `WindowId`, `TabId`, and `SessionId`, not pointers into array storage or
   native indices, cross callback boundaries.
3. No pointer into a workspace list remains live across `SendMessageW`,
   `SetWindowPos`, `SetFocus`, `DestroyWindow`, menu tracking, or other calls
   that can dispatch callbacks.
4. A transfer sets both lifecycle guards before any native call that can
   reenter either window.
5. `constructing`, hidden-empty, and `closing` paint/resize paths never assume
   an active model.
6. `WM_CLOSE` during transfer sets `close_requested`; it does not destroy a
   source or destination in the middle of ownership commit.
7. `WM_DPICHANGED` during transfer records the newest DPI and suggested rect;
   terminal resize and cache rebuilding occur after commit.
8. Programmatic tab selection does not reapply `TCN_SELCHANGE` as another
   model operation.
9. Native view synchronization is idempotent and can rebuild from the
   workspace after a partial Win32 failure.
10. A state becomes eligible for deferred free only after `WM_NCDESTROY`; stale
    messages then fail stable-ID lookup and are ignored.

## Application-lifetime notification receiver

Create a message-only HWND before starting any ConPTY session. Every session
stores this `notification_window`, not an owning top-level HWND, and posts its
stable x64 `SessionId` for output, child-exit, and input-failure events.

`SessionOwner` records one of:

- `attached(WindowId)`;
- `transferring` with the transaction's stable destination;
- `retiring`;
- absent after final cleanup.

The receiver resolves the current owner at dispatch time:

- attached output is drained into the preserved model and window effects are
  applied only if that model is active there;
- events observed during the allocation-free commit use the transaction's
  stable resolution and are applied after commit; normal dispatch cannot
  interleave unless a native callback reenters, and the lifecycle guard still
  prevents workspace mutation;
- retiring and absent sessions ignore UI effects and stale messages safely;
- child-exit and output-EOF completion close or retire the tab in its current
  window, never its creator window.

The message-only receiver is not a user window, never appears in Alt+Tab or the
taskbar, owns no workspace or renderer, and remains valid when zero visible
windows exist.

## Non-blocking retirement and message-loop lifetime

### Retirement ownership

Each heap-stable `Tab` contains or permanently owns an intrusive retirement
record, so enqueueing it cannot fail. Closing follows this order on the UI
thread:

1. mark the tab/session tree closing and stop accepting new input;
2. remove all session routes from visible ownership or mark them `retiring`;
3. detach renderer/cache/focus references to its models;
4. detach the `*Tab` from its workspace without deinitializing it;
5. enqueue the embedded retirement record in O(1);
6. update or destroy the visible window and return to message dispatch.

A bounded pool of four cleanup workers owns retired tabs. A worker performs the
potentially blocking ConPTY close, job termination, pseudoconsole closure,
reader/writer/waiter joins, handle release, terminal-model deinitialization,
pane-tree destruction, and final tab free. Application allocation uses the
thread-safe application allocator; any future non-thread-safe resource must be
released before handoff or explicitly marshalled back to the UI thread.

Every blocking ConPTY cleanup stage has a named deadline and diagnostic. The
existing graceful wait, kill-on-close job, process termination fallback,
synchronous-I/O cancellation, and worker-thread completion remain ordered so
final buffered output is not exposed to freed storage. Cleanup failures are
reported but do not return ownership to a destroyed window.

### Wakeable message pump

The retirement manager owns a manual-reset completion event. Cleanup workers
signal it after publishing completion counters/records. The UI message pump
uses `MsgWaitForMultipleObjectsEx` (or an equivalent wait on both the event and
the Windows message queue), then drains completion records and ordinary
messages. Cleanup progress therefore does not depend solely on `PostMessageW`
success.

The application may terminate only when all of these are true:

- no live or constructing top-level window remains;
- no transfer transaction is active;
- the retirement queue and in-flight cleanup count are zero;
- every ConPTY-owned worker has stopped and can no longer post;
- session routing contains no attached or retiring entry;
- deferred window frees are drained.

Only then does the UI thread request cleanup-worker shutdown, observe the
worker-stopped event, destroy the notification HWND, unregister window classes,
and exit the pump. The dispatcher is always created before session workers and
destroyed after them.

When the last visible window closes while cleanup remains, ttyrtle intentionally
has no taskbar/Alt+Tab window but keeps the hidden receiver and message pump
alive until retirement completes. It must not create a replacement terminal or
show an empty receiver.

### Responsiveness requirements

Automated instrumentation records close-handler duration, retirement queue
latency, cleanup duration, dispatcher probe latency, and final shutdown time.

Acceptance thresholds on the Windows CI x64 Debug integration build are:

- a close-tab or final-window close handler returns within 100 ms while an
  injected cleanup backend remains blocked for at least two seconds;
- the visible HWND for that final close reaches `WM_NCDESTROY` within 250 ms;
- a probe posted immediately after retirement begins is dispatched within
  100 ms, proving that cleanup does not block the UI pump;
- closing four busy ConPTY tabs begins all cleanup work without UI-thread waits
  and the bounded four-worker pool completes the integration case within
  15 seconds;
- no teardown wait is unbounded; a named timeout or a test failure identifies
  the specific process, pseudoconsole, reader, writer, waiter, or cleanup-pool
  stage.

Timing tests should use monotonic high-resolution counters, generous process
startup exclusions, and diagnostic output so CI regressions are actionable.

## Allocation-free transfer transaction

The application-level coordinator accepts stable source `WindowId`,
destination `WindowId`, `TabId`, and destination index. The only cross-window
move entry point is this coordinator.

### Preflight: all fallible work before detach

Before changing ownership:

1. resolve live source and destination states by `WindowId` and verify that the
   source owns the tab;
2. reject closing, destroyed, already-transferring, same-window, or stale
   destinations;
3. for “Move to New Window,” construct a complete hidden receiver through HWND,
   child-control, subclass, renderer/GDI fallback, DPI, workspace, and registry
   initialization, but do not show or enumerate it;
4. collect all session IDs below the pane root into transaction-owned storage;
5. reserve destination workspace capacity and any source/destination deferred
   action capacity;
6. reserve session-owner registry capacity and prepare every new registry value;
7. allocate and encode all UTF-16 native labels and prepare native-tab sync
   scratch storage for both windows;
8. compute destination pane rectangles, target terminal dimensions, caption,
   active-tab choices, and focus transitions;
9. snapshot semantic source and destination state: membership, order, active
   IDs, focus recipient, and visibility;
10. cancel or commit rename editors as defined by the command, cancel transient
    selection drag, and establish transfer lifecycle guards.

If any preflight step fails, destroy an unshown receiver if one was created and
return with the source and destination semantically unchanged. Reserved
capacity, diagnostic counters, and other invisible implementation details may
change; rollback is semantic, not byte-for-byte.

### Commit: no allocation and no model failure

After detach, the commit path uses only preallocated or intrusive operations:

1. detach the existing `*Tab` without deinitializing it;
2. insert it with `insertAssumeCapacity` at the destination index;
3. update all existing session-owner entries without allocation;
4. select the source's nearest remaining tab and the moved tab in the
   destination;
5. publish coherent workspace and registry ownership;
6. leave both transfer guards and apply deferred lifecycle actions.

No allocator, process start, reply-sink replacement, model creation, or
fallible model operation is permitted between detach and coherent publication.
The transaction temporarily owns the `*Tab`; exactly one destination workspace
owns it when commit returns.

Native tab-control calls can still fail internally after the model commit.
They do not roll model ownership back. Prepared label buffers are used for the
first incremental update; on failure the affected window is marked
`native_tabs_dirty`, preserves the running tab, logs the Win32 failure, and
schedules an idempotent full rebuild from the workspace. A hidden receiver is
shown only after native synchronization succeeds; if repeated synchronization
cannot make it usable, the allocation-free transaction attaches the tab back
to its pre-reserved source position semantically before the source resumes.

Terminal and ConPTY resize occurs after ownership commit. A resize failure is
diagnosed and retried on the next size/layout event; it never restarts or loses
the process and does not roll ownership back.

### Post-commit presentation and lifecycle

- Rebuild the source active cache only if its active tab changed.
- Rebuild the destination active cache for the moved model.
- Invalidate window-bound retained scenes; do not move device resources.
- Recompute both captions and native selections.
- Apply destination DPI metrics to each moved terminal leaf and resize its
  existing ConPTY only when cell dimensions differ.
- Route focus-lost to the session that previously received focus-gained, then
  focus-gained to the destination's moved active session when appropriate.
- Show and activate a new receiver only after it becomes coherent and live.
- If the source becomes empty, transition it to closing and destroy its HWND
  after commit; do not retire the moved tab.
- If `WM_CLOSE` was recorded reentrantly for either window, apply it after
  transfer completion against the now-current ownership.

## Window creation and command behavior

Every new top-level window is an unowned `WS_OVERLAPPEDWINDOW`, so Windows
provides ordinary taskbar, Alt+Tab, activation, snap, minimize, maximize,
system-menu, and monitor behavior.

Commands:

- `Ctrl+Shift+N` creates a new top-level window with one new terminal session.
- The tab context menu includes New Tab, New Window, Rename, Move Tab to New
  Window, Move Tab to Window, and Close.
- “Move Tab to Window” is present only when another live destination exists.
- Destination entries use the effective active caption plus a stable ordinal
  when captions collide.
- A moved tab becomes active in the destination, the destination is restored if
  minimized, and the command brings it to the foreground using normal Windows
  activation rules.
- Moving the final source tab closes the empty source window.

Use `TrackPopupMenuEx` with `TPM_RETURNCMD` and a command-to-`WindowId` snapshot.
After the native menu loop returns, resolve the stable destination again. If it
disappeared, became closing, or is no longer eligible while the menu was open,
the move is a no-op, the source remains unchanged, and focus returns to its
terminal. Raw HWNDs and menu positions are never retained as destination
identity.

Keyboard context-menu invocation remains anchored to the active native tab.
All move operations are available without a mouse. The standard tab control
continues to own native painting, selection, overflow, high-contrast defaults,
and its accessibility baseline.

## Focus and input ownership

Each `WindowState` records the `SessionId` that actually received a terminal
focus-gained event. `WM_KILLFOCUS` sends focus-lost to that recorded session,
not whichever tab happens to be active when the callback arrives.

Switching active tabs in a focused window sends an ordered lost/gained pair
when terminal modes request focus events. Moving a focused tab sends no
spurious event to the source's newly selected neighbor. A background move emits
no focus event. Selection and scrollback stored in the terminal model survive;
only in-progress window-local mouse and translation state is cancelled.

Keyboard, character, paste, mouse, selection, and viewport operations always
resolve through the receiving window's active terminal or, after panes exist,
its focused terminal leaf.

## System-key routing

Key dispatch returns an explicit route:

```text
application | terminal | system
```

The key-down decision is stored by physical key/scancode until key-up so a
modifier change cannot route the release to a different owner. Matching
`WM_CHAR`, `WM_SYSCHAR`, dead-character, and repeat behavior follows that
decision.

Routing policy:

- exact ttyrtle shortcuts, including `Ctrl+Shift+N`, tab commands, copy, paste,
  and tab selection, are application-routed; handled press, repeat policy,
  release, and generated character messages are consumed consistently;
- `Alt+F4` and its release are system-routed through `DefWindowProcW`, producing
  normal `SC_CLOSE`/`WM_CLOSE` behavior and no terminal bytes;
- `Alt+Space` and its release/`WM_SYSCHAR` path are system-routed so the native
  window system menu opens and no terminal bytes are sent;
- `Shift+F10` is application/system-routed to the native keyboard context-menu
  path and never sent to ConPTY;
- bare `F10` is terminal-routed because ttyrtle has no menu bar and terminal
  applications conventionally use F10; both press and release follow the
  terminal encoder, and `DefWindowProcW` must not synthesize `SC_KEYMENU`;
- other Alt-modified keys are terminal-routed unless an exact application
  binding or documented Windows system chord claims them;
- genuinely unhandled system messages and system-routed releases reach
  `DefWindowProcW` rather than being swallowed.

This deliberately preserves Windows window-management conventions while
retaining a predictable way to send F10 and ordinary Alt terminal input.

## Per-Monitor V2 DPI behavior

Before common controls or any HWND is created, opt the process into Per-Monitor
V2 awareness with `SetProcessDpiAwarenessContext(
DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`. Treat an unexpected failure as a
startup diagnostic; verify the effective context rather than silently running
virtualized. A manifest-based declaration may be added later, but runtime setup
must remain early and explicit for this milestone.

Each `WindowState` owns metrics for `GetDpiForWindow(hwnd)`. Window creation and
placement use DPI-aware non-client calculations such as
`AdjustWindowRectExForDpi`. `WM_DPICHANGED` applies the suggested rectangle,
recomputes renderer/font metrics, lays out the native tab control and rename
editor, updates presentation synchronously, and resizes that window's terminal
leaves only at changed cell boundaries.

A hidden receiver records DPI and client geometry even with no active model.
When a moved tab attaches, its pane layout is evaluated in the receiver's DPI
and terminal content rectangle. Moving between different DPI windows preserves
logical pane ratios and session content but necessarily changes terminal cell
dimensions; the same ConPTY receives `ResizePseudoConsole`.

Per-Monitor V2 child behavior must not double-scale the standard tab control or
rename editor. Hit testing, context-menu anchoring, and focus rectangles use the
correct client/screen coordinate conversions for each HWND.

## Renderer cost contract

For a move between existing windows:

- neither window recreates its D3D/D2D device or swap chain solely because of
  transfer;
- no inactive tab is rendered or given a new retained cache;
- only the destination moved tab and a changed source active tab rebuild
  presentation caches;
- model damage and layout generations remain model-local;
- total layout rebuilding is O(source visible rows + destination visible rows),
  not O(total tabs or total scrollback).

A new destination window creates exactly one normal renderer and may fall back
to GDI under the existing policy. Renderer initialization failure must not
restart the moved session. Existing-window GPU recreation counters must remain
unchanged across transfer, and diagnostics record cache rebuilds attributable
to each window.

## Affected modules

### `src/app.zig`

- Replace production globals with `Application` and heap-stable `WindowState`.
- Register top-level and message-only classes and run the wakeable pump.
- Implement lifecycle guards, deferred window frees, independent window
  construction, application commands, transfer coordination, session routing,
  retirement completion, last-window shutdown, explicit key routing, and new
  integration modes.
- Convert paint, resize, input, focus, native-tab, caption, and timer helpers to
  accept explicit state.
- Keep test orchestration application-owned.

Perform the initial ownership conversion in place so behavior changes are
reviewable. After the boundary is stable, extract cohesive window-state or
retirement helpers into focused modules without combining that mechanical move
with a lifecycle change.

### `src/workspace.zig`

- Store `*Tab` and make ownership explicit.
- Add reserve, detach, and allocation-free attach operations.
- Add generic pane/session traversal.
- Separate visual removal/retirement from destructive deinitialization.
- Add semantic rollback, identity, and exactly-once ownership tests.

### `src/conpty.zig`

- Replace creator-window semantics with the application notification HWND.
- Split non-blocking close initiation from blocking retirement/finalization.
- Make cleanup stages bounded, observable, and suitable for cleanup workers.
- Preserve ordered input/output behavior and exact child process identity.
- Expose test hooks for blocked and failed cleanup stages without sleeping the
  UI thread.

### New focused module, if useful

Add `src/retirement.zig` for the intrusive queue, bounded worker pool,
completion event, counters, and unit-testable shutdown gate. Import it from
`src/test_root.zig`.

### Rendering modules

No renderer ownership redesign is expected. Update callers and diagnostics to
prove per-window isolation and bounded cache/device work.

### `build.zig`

- Reject unsupported application targets clearly.
- Keep x64 Windows unit, integration, smoke, Debug, and ReleaseFast checks.
- Include new unit modules and integration modes in `zig build verify`.

### `test/integration.zig`

Add multi-window, transfer, retirement, DPI, key-routing, accessibility,
failure-injection, and renderer-cost cases while retaining all existing
single-window tests.

## Implementation sequence

### Current implementation status

The verified foundation is in place: tabs are heap-stable; the workspace has
an allocation-free transfer transaction; ConPTY notifications use an
application-lifetime receiver; and Per-Monitor V2 is enabled before HWND
creation. `Application`/`WindowState` now own the initial window's workspace,
renderer, cache, DPI metrics, input translation/shortcut state, and stable
`GWLP_USERDATA` identity. Window destruction now consistently enters the
`closing` lifecycle before destroying the HWND, restoring message-loop shutdown
for ConPTY completion and error paths.

`zig build verify` passed after this work. The native ownership conversion is
still incomplete: single-window callback helpers retain compatibility views,
and native new-window/move commands and asynchronous retirement remain
disabled until that conversion is complete.

### Phase 1: Ownership and lifecycle scaffolding

- Add the x64 platform guard.
- Introduce `Application`, `WindowId`, `WindowState`, lifecycle states,
  `GWLP_USERDATA`, child subclass data, and deferred frees.
- Move all HWND-bound globals into `WindowState`.
- Preserve current one-window behavior.
- Make callbacks safe for constructing, empty, closing, and destroyed states.
- Change termination to depend on the application shutdown gate rather than
  any single `WM_DESTROY`.

### Phase 2: Per-Monitor V2 and independent window construction

- Enable Per-Monitor V2 before creating HWNDs.
- Make metrics, renderer, layout, timers, input, and native children fully
  per-window.
- Add reusable visible-new-window and hidden-receiver construction paths.
- Implement `Ctrl+Shift+N` and New Window.
- Prove that closing one window leaves the other live.

### Phase 3: Application notification routing

- Create the message-only receiver before sessions.
- Point all ConPTY notifications to it.
- Add `SessionOwner` routing and stable lookup.
- Route background output, title, bell, exit, EOF, and failure events to the
  current window.
- Prove stale and retiring notifications are safe.

### Phase 4: Non-blocking retirement

- Add heap-stable tab ownership and embedded retirement records.
- Split ConPTY close initiation from blocking cleanup.
- Add the bounded cleanup pool, completion event, wakeable pump, diagnostics,
  and shutdown gate.
- Convert tab close, process auto-close, window close, construction rollback,
  and application shutdown to the same idempotent retirement path.
- Meet responsiveness and total-cleanup thresholds before enabling transfer.

### Phase 5: Allocation-free transfer model

- Add pane traversal, reserve/detach/attach, semantic snapshots, and prepared
  registry/native-view storage.
- Implement preflight and allocation-free commit with lifecycle guards.
- Add failure injection at every preflight boundary and view-repair coverage.
- Keep all movement internal until model and registry invariants pass.

### Phase 6: Command-driven moves

- Add Move Tab to New Window and the dynamic Move Tab to Window submenu.
- Use `TPM_RETURNCMD` and stable destination snapshots.
- Apply resize, focus, caption, native-view repair, renderer invalidation, and
  final-source close behavior.
- Defer cross-window drag and tear-out.

### Phase 7: Input, DPI, accessibility, and cost hardening

- Land explicit application/terminal/system key routing.
- Add DPI seam and renderer-cost assertions.
- Verify the standard tab control's accessibility tree and keyboard-only move
  path.
- Complete real-monitor, Narrator, high-contrast, system-menu, taskbar, and
  multi-window manual QA.

### Phase 8: Documentation and verification

- Update `README.md` interaction, platform, lifecycle, and limitation text.
- Update `docs/architecture/tabs.md` implementation status and ownership notes.
- Update `todo.md` as work advances.
- Run:

```powershell
zig fmt build.zig src test
zig build verify
```

## Test plan

### Workspace and transfer unit tests

- Cross-workspace transfer preserves the exact `*Tab`, pane root,
  `TerminalSession` addresses, `TabId`, every `SessionId`, title override, OSC
  title, model contents, scrollback, selection, viewport, completion flags, and
  process owner.
- Insert at beginning, middle, and end preserves destination order.
- Moving active/inactive and first/middle/last tabs selects the correct source
  neighbor and destination active tab.
- Moving the only source tab produces a transient empty source without retiring
  the moved tab.
- Repeated two-way moves and later close destroy every process/model exactly
  once.
- Pane traversal finds every current leaf and is ready for recursive split
  coverage in the pane milestone.
- Incompatible application ownership is rejected before detach.

### Allocation and failure tests

Inject failure independently for:

- hidden `WindowState` allocation;
- `CreateWindowExW`, tab-control creation, subclass installation, and initial
  renderer setup;
- destination workspace reserve;
- transaction session-ID collection;
- registry/deferred-action reserve;
- UTF-16 label and native-sync scratch allocation;
- native destination tab insertion after model commit;
- destination terminal-model resize and `ResizePseudoConsole`;
- cleanup enqueue signaling and cleanup completion notification.

Every pre-detach failure preserves semantic source/destination membership,
order, active identity, focus ownership, process identity, and visibility.
Capacity and diagnostic changes are allowed. Post-commit native-view failure
must repair from the model without process loss. Resize failure leaves
ownership committed and retries safely.

### Lifecycle and reentrancy tests

- Exercise every valid lifecycle transition and reject invalid/repeated ones.
- Deliver `WM_SIZE`, `WM_DPICHANGED`, `WM_PAINT`, focus, tab notification,
  `WM_CLOSE`, and `WM_NCDESTROY` during constructing, hidden-empty,
  transferring, and closing states.
- Force native callbacks during model commit and verify no second mutation,
  freed pointer, missing active-model dereference, or premature destroy.
- A close recorded during transfer applies to the correct post-commit owner.
- Deferred `WindowState` free occurs only after `WM_NCDESTROY` unwinds.
- A hidden receiver never appears in destination menus, taskbar expectations,
  or user-visible painting and is destroyed cleanly on preflight failure.

### Notification and cleanup tests

- Output posted before transfer and dispatched afterward reaches the
  destination model.
- Child exit and output EOF in either order close the tab in its current owner.
- Input failure, title, bell, stale, retiring, unknown, and duplicate messages
  are safe.
- Closing one of two windows does not exit the pump or affect the other.
- Closing the final visible window keeps the hidden receiver alive until every
  cleanup worker and ConPTY worker stops, then destroys it and exits.
- Inject a two-second cleanup stall and enforce the 100 ms handler/probe and
  250 ms visible-destroy thresholds.
- Retire four busy sessions concurrently and finish within 15 seconds.
- Inject process wait timeout, termination fallback, broken pipe,
  `CancelSynchronousIo`, output-reader completion, cleanup-worker failure, and
  event/post failure paths; ownership remains singular, diagnostics identify
  the stage, and the pump cannot exit prematurely.
- Repeated close, EOF, exit, and stale notifications never double-retire or
  double-free.

### Process and session identity tests

- Capture the `TerminalSession` and `conpty.Session` addresses, process handle,
  `GetProcessId` result, session ID, reply-sink context, and model marker before
  transfer; they are identical afterward.
- Input queued before and after transfer remains ordered and reaches the same
  child process.
- Background output and OSC title changes continue during repeated moves.
- Transfer never calls process creation, pseudoconsole creation, or session
  destroy counters.

### Multi-window integration tests

- Two or more hidden top-level windows maintain independent workspaces, native
  item counts/`lParam`, selections, captions, timers, input state, client
  dimensions, and renderers.
- Move active and inactive running tabs to existing and new windows through the
  same command backend used by the UI.
- Move the last source tab and verify only the source HWND closes.
- Move a minimized destination tab, restore it, and apply correct deferred
  layout.
- Repeatedly create windows, transfer tabs, close source/destination windows,
  and retire busy sessions without leaks, stale dereferences, or early quit.
- A destination captured by an open Move Tab submenu disappears before command
  execution; stable lookup makes the command a no-op and leaves the source
  unchanged.
- Duplicate destination captions remain distinguishable and select the correct
  stable `WindowId`.

### System-key tests

Exercise real dispatch, not only the helper:

- `Alt+F4` down/up reaches `DefWindowProcW`, closes only the addressed window,
  sends no terminal bytes, and does not quit while another window lives.
- `Alt+Space` down/up and `WM_SYSCHAR` take the system-menu path and send no
  terminal bytes.
- bare F10 press/repeat/release reaches the terminal encoder and does not
  produce `SC_KEYMENU`.
- `Shift+F10` opens the keyboard tab context menu and neither press nor release
  reaches ConPTY.
- application shortcuts consume matching releases and generated character
  messages even if modifiers change before release.
- unbound Alt input and its release reach the terminal, while genuinely
  system-routed messages reach `DefWindowProcW`.

### DPI seam tests

- Startup reports an effective Per-Monitor V2 context before the first HWND.
- Two windows retain independent synthetic 96/144/192 DPI metrics and renderer
  targets.
- `WM_DPICHANGED` during constructing, live, transfer, and closing respects the
  state invariants and latest suggested rect.
- Transfer across different DPI metrics preserves identity and pane ratios,
  rebuilds destination font/layout state, and sends the exact new cell size to
  the same ConPTY.
- Native tab strip, rename editor, hit testing, context-menu anchoring, client
  margins, cursor, and selection geometry do not double-scale at seams.
- Synthetic integration tests are supplemented by the real-monitor manual
  matrix below; synthetic messages alone are not accepted as complete DPI
  verification.

### Renderer cost tests

- Moving between existing GPU windows leaves both GPU recreation counters and
  device identities unchanged.
- Only source/destination active presentation caches rebuild; inactive tabs do
  not add layout builds.
- Layout rebuild count is bounded by the sum of visible source and destination
  rows, allowing only explicitly documented fixed overhead.
- Moving to a new window initializes exactly one renderer and preserves the
  session/process counters.
- A destination GPU failure follows the GDI fallback policy without restarting
  the tab; failure in one window does not invalidate another window's device.

### Accessibility and Windows behavior tests

- `AccessibleObjectFromWindow`/MSAA exposes each standard tab control as a tab
  list with correct tab names, order, selection, and window separation before
  and after transfer.
- Keyboard context-menu and move commands are reachable without a mouse, return
  focus to the correct terminal, and preserve native tab selection semantics.
- No hidden receiver is exposed as an interactive application window.
- Native taskbar, Alt+Tab, system menu, snap, minimize/maximize, activation,
  close, and focus behavior remain independent for each top-level window.
- Owner drawing is not introduced, preserving standard high-contrast and
  accessibility behavior.

## Manual QA matrix

Perform before marking the feature done:

- two real monitors at different scale factors, including 100% and at least
  one of 150% or 200%; move each top-level window across the seam in both
  directions, then command-move running tabs between them;
- mixed monitor positions, negative virtual-screen coordinates, maximized,
  snapped, minimized, and restored destinations;
- verify crisp text, correct client size, tab height, rename-editor bounds,
  mouse cell hit testing, cursor/selection alignment, and exact ConPTY rows and
  columns after every seam crossing;
- exercise Alt+F4, Alt+Space, bare F10, Shift+F10, keyboard-only tab selection,
  system-menu commands, taskbar activation, and Alt+Tab;
- use Narrator or Inspect to verify window and tab names, selection, destination
  menus, and focus announcements before and after moves;
- enable a Windows high-contrast theme and verify the standard tab controls,
  focus, menus, and terminal fallback remain usable;
- close a busy final window and confirm it disappears immediately while the
  process retires without a frozen visible UI or replacement window;
- run with GPU rendering and forced GDI fallback, including device loss in one
  window while another remains active.

Record the monitor scale factors, Windows version, renderer mode, and results
in the implementation PR. Visible UI changes require a screenshot or short
recording under the repository PR guidelines.

## Risks and mitigations

- **UI-thread teardown stalls:** hand stable tab ownership to the bounded
  retirement pool and enforce timing probes in integration tests.
- **Premature dispatcher destruction:** centralize the shutdown gate and use a
  completion event that the pump waits on alongside messages.
- **Double-free during transfer or close:** use heap-stable `*Tab`, one
  transaction owner, embedded retirement records, and exactly-once state
  transitions.
- **Reentrant Win32 mutation:** set lifecycle guards before native calls, retain
  only stable IDs across callbacks, and defer mutations until commit ends.
- **Allocation failure after detach:** reserve every application-owned resource
  and prepare native data before detach; make the model commit allocation-free.
- **Native control failure after commit:** treat workspace state as truth and
  repair the view idempotently without destroying the process.
- **Stale HWND/menu identity:** resolve stable `WindowId` after menu tracking and
  reject non-live destinations.
- **DPI virtualization or double scaling:** enable Per-Monitor V2 before HWNDs,
  keep metrics per window, and require real mixed-DPI QA.
- **Renderer work scales with total tabs:** assert device identity and bounded
  visible-row layout counts.
- **Platform token truncation:** enforce x64 at build time until a 32-bit token
  indirection is designed.
- **Scope collision with panes:** move the opaque pane root and add traversal
  seams, but leave split creation and layout to its own milestone.

## Acceptance criteria

The milestone is complete when all of the following are true:

- multiple independent native top-level windows coexist and closing one does
  not terminate another;
- a running tab moves through keyboard/menu commands to a new or existing
  window without changing any model, session, process handle, or process ID;
- the complete pane root transfers as one owner and is ready to preserve future
  split layouts;
- preflight failures leave source/destination semantics unchanged and the
  post-detach model commit performs no allocation;
- constructing, live, transferring, closing, and destroyed states pass
  reentrant callback and hidden-receiver tests;
- session retirement never blocks the UI thread, meets the stated latency and
  cleanup thresholds, and the dispatcher/pump outlive every posting worker;
- Per-Monitor V2 automated seams and real mixed-monitor QA pass;
- Alt+F4, Alt+Space, bare F10, Shift+F10, shortcut releases, and terminal Alt
  input follow the documented routes;
- stale menus, stale notifications, native-view failures, cleanup failures,
  renderer fallback, and repeated lifecycle operations do not lose or
  double-destroy a session;
- the standard tab control retains correct keyboard and accessibility behavior;
- renderer/device work remains within the stated cost contract;
- cross-window drag and tear-out remain explicitly deferred;
- documentation is current and `zig build verify` passes.
