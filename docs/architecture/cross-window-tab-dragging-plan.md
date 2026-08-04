# Cross-window tab dragging and tear-out

## Progress

Status: **In progress** (2026-08-04).

Implemented:

- deterministic threshold, insertion-slot, local-index, tear-out, DPI scaling,
  and work-area placement helpers with unit coverage;
- one application-wide candidate/active/finishing coordinator with DPI-aware
  capture, stable identities, live same-window reorder, idempotent cancellation,
  original-order rollback, Escape suppression, and debug counters;
- screen-space, topmost-root destination discovery with fresh native item
  geometry, overflow/rename-child exclusion, insertion markers, and no-drop
  cursor feedback without hover activation;
- deferred notification-window drops, indexed reuse of `prepareTransfer`, and
  allocation-free identity-preserving commit for first/middle/append positions;
- release-time hidden receiver construction and monitor-work-area-clamped
  tear-out placement based on source client DIPs and destination DPI;
- pre-commit rollback and post-commit presentation recovery boundaries;
- hidden Win32 coverage for indexed cross-window moves, exact `*Tab` identity,
  tear-out placement, native presentation, and cancellation rollback.

Automated verification: `zig build verify` passed on 2026-08-04, including 113
unit tests and all 18 hidden Win32 integration tests. The manual Windows QA
matrix below has not yet been run, so this plan and `todo.md` must remain **In
progress**. In particular, real mixed-DPI monitor seams, native overflow,
occlusion, capture theft/system transitions, Narrator/Accessibility Insights,
left-handed input, high contrast/text scaling, and sustained-output resource
stress still require recorded results before **Done**.

## Goal

Extend the existing native tab drag so a running tab can be dropped into the
tab strip of another ttyrtle window or torn out into a new top-level window.
The drop must use the existing command-driven transfer transaction: the exact
heap-stable `*Tab`, pane root, terminal models, ConPTY handles, child processes,
scrollback, selection, and future pane state move together. Dragging must not
introduce a second ownership path or recreate a session.

The result should follow normal Windows expectations:

- dragging within a strip continues to reorder by the system drag threshold;
- hovering another ttyrtle strip shows an insertion position without activating
  that window;
- releasing over that position transfers and activates the tab there;
- releasing sufficiently outside every eligible strip tears the tab into a new
  foreground window near the pointer;
- Escape, capture loss, source closure, and other cancellation paths leave the
  tab attached exactly once and restore any provisional same-window reorder;
- menu and keyboard move commands remain the complete non-mouse alternative.

## Scope

Included:

- one application-wide drag coordinator for the one UI thread and one system
  mouse capture;
- same-window reorder, cross-window strip discovery, indexed insertion, and
  tear-out placement;
- screen/client coordinate conversion across Per-Monitor V2 DPI boundaries;
- lightweight drag and insertion feedback that preserves the standard
  `WC_TABCONTROL` as the accessible tab surface;
- stable-ID deferred drop execution, transfer preflight, cancellation,
  rollback, reentrancy, and lifecycle handling;
- unit, hidden-window integration, mixed-DPI, accessibility, and manual QA.

Deferred:

- inter-process or cross-application OLE drag and drop;
- dragging terminal panes independently of their owning tab;
- touch-specific manipulation or multi-pointer gestures beyond Windows mouse
  promotion;
- animated previews, acrylic, owner-drawn tabs, and close/pin/activity
  affordances;
- changing the command-driven transfer, session routing, or retirement
  ownership model.

## Existing seams to preserve

The required ownership foundation is already implemented:

- `workspace.Application.prepareTransfer` accepts stable source/destination
  `WindowId`, `TabId`, and destination index, reserves all storage, validates
  session routes, and returns an allocation-free `TransferTransaction` commit;
- `moveTabToState` commits the exact `*Tab`, refreshes each window's native and
  renderer presentation, closes an empty source, and foregrounds the receiver;
- `createTransferDestination` creates a complete hidden, empty receiver before
  a move-to-new-window commit;
- the application registry owns heap-stable `WindowState` objects, while HWNDs
  are presentation handles and stable IDs cross callbacks;
- each native item stores `TabId` in `TCITEM.lParam`;
- the message-only notification HWND and `SessionOwner` routing keep ConPTY
  events independent of the source HWND;
- closing and transfer use the existing `constructing`, `live`, `transferring`,
  `closing`, and `destroyed` lifecycle guards.

The current `TabDrag` is per-window and stores only a candidate ID, client
anchor, and Boolean. `tabControlProc` begins it from `WM_LBUTTONDOWN`, calls
`SetCapture` after the system threshold, reorders on client-coordinate
midpoint crossings, and clears it for button-up, `WM_CANCELMODE`, or
`WM_CAPTURECHANGED`. It must be generalized rather than layered with a second
cross-window gesture. Selection dragging in the terminal remains separate and
must never own capture at the same time.

## Interaction contract

### Start and local reorder

1. On primary `WM_LBUTTONDOWN`, let the standard tab control perform its normal
   selection behavior, but snapshot the hit-tested `TabId`, source `WindowId`,
   original model index, pointer-to-tab offset, and anchor in screen pixels.
2. Do not start a drag for tab-strip whitespace, scroll buttons, a rename edit,
   a non-live source, or a missing native/model identity.
3. Start only after movement exceeds `SM_CXDRAG` or `SM_CYDRAG`, queried with
   `GetSystemMetricsForDpi` for the source window. Require the primary button to
   remain down before calling `SetCapture` on the source tab-control HWND.
4. Cancel any source rename before capture. Keep the dragged tab active and do
   not route tab mouse messages into the terminal.
5. While the pointer remains in the source strip, preserve today's live
   same-window midpoint reorder. Record the original index so cancellation or
   a failed cross-window drop can restore it without allocation.

Click-without-drag behavior, double-click rename, middle-click close, context
menus, native selection, and keyboard focus must remain unchanged.

### Cross-window hover and drop

On every captured `WM_MOUSEMOVE`, convert the point from the source tab
control to screen coordinates and recompute the target. Do not cache an HWND or
native index across messages.

An existing-window target is eligible only when all of these remain true:

- `WindowFromPoint` and `GetAncestor(..., GA_ROOT)` identify the visible,
  topmost window at the pointer, so ttyrtle cannot accept a drop through an
  occluding application;
- that root HWND resolves to the application registry and the same live
  `WindowId`; HWND equality alone is not identity;
- the registered window and tab-control HWND still exist, are visible and
  enabled, and the model lifecycle is `.live`;
- the pointer is inside the tab control's screen rectangle, not its rename
  editor or native overflow/scroll child;
- a fresh `TCM_HITTEST`/`TCM_GETITEMRECT` calculation yields an insertion slot
  in `0...tab_count`.

Map the screen point into the candidate control with `ScreenToClient`. Insert
before an item's horizontal midpoint, after the last visible item when in
trailing strip whitespace, and into slot zero for an empty internal receiver.
Clamp item rectangles to the tab-control client rectangle. Treat the native
overflow buttons as no-drop zones rather than depending on undocumented
messages to scroll them. A later enhancement may add tested hover scrolling.

The hover snapshot contains only `WindowId` and insertion index. On mouse-up,
recompute it from the final screen point; the earlier hover result is only
visual feedback. A drop onto the source strip finalizes its local order. A
drop onto another eligible strip requests indexed transfer and brings that
window to the foreground only after ownership commit and presentation refresh
succeed.

### Tear-out

Leaving all eligible strips does not detach the model. Arm tear-out only after
the pointer is outside the source strip by the DPI-scaled system drag threshold;
small vertical excursions can therefore return to ordinary local reorder.
While armed, show new-window feedback. Create no HWND or model window until
primary-button release.

On release with no eligible strip target:

1. end capture and enqueue a stable-ID tear-out request;
2. re-resolve the live source and tab;
3. create a complete hidden transfer destination, as move-to-new-window already
   does, but pass a requested screen placement;
4. size the new client area from the source window's size in device-independent
   units and place it on the monitor nearest the release point;
5. after creation, use `GetDpiForWindow` and `AdjustWindowRectExForDpi` to obtain
   the final outer size, preserve the pointer-to-tab offset where practical,
   and clamp enough caption/tab area into `MONITORINFO.rcWork`;
6. preflight and commit the existing transfer, synchronize both presentations,
   then show, foreground, and focus the new window;
7. if construction or preflight fails, destroy the empty receiver and restore
   the source's original reorder and focus.

The destination is positioned before it is shown, avoiding a visible
`CW_USEDEFAULT` jump. Maximized and minimized source state is not copied; a
tear-out starts as a normal window. Its restored size is based on the source's
normal client size, bounded to the target work area and existing minimum-size
policy. Releasing over the taskbar or outside a monitor still uses
`MonitorFromPoint(..., MONITOR_DEFAULTTONEAREST)` and clamps to that monitor's
work area.

## Application-wide drag coordinator

Replace `WindowState.tab_drag` with one `Application.drag` because Win32 has one
mouse capture per UI thread and two window drags cannot be active at once.
Keep terminal selection drag state per window.

The exact type may evolve, but it should encode the state explicitly:

```zig
const TabDragCoordinator = union(enum) {
    idle,
    candidate: Candidate,
    active: Active,
    finishing: Finishing,
};

const Candidate = struct {
    source_window_id: WindowId,
    tab_id: TabId,
    original_index: usize,
    anchor_screen: POINT,
    grab_offset_dip: POINT,
};

const Active = struct {
    candidate: Candidate,
    capture_hwnd: HWND,
    hover: HoverTarget,
    local_order_changed: bool,
    tear_out_armed: bool,
};

const HoverTarget = union(enum) {
    none,
    source: usize,
    window: struct { window_id: WindowId, insertion_index: usize },
    tear_out,
};

const DropRequest = union(enum) {
    reorder: struct { source_window_id: WindowId, tab_id: TabId, index: usize },
    transfer: struct {
        source_window_id: WindowId,
        tab_id: TabId,
        destination_window_id: WindowId,
        insertion_index: usize,
    },
    tear_out: struct { source_window_id: WindowId, tab_id: TabId, point: POINT },
};
```

The coordinator owns any feedback HWND/GDI resources and one pending
`DropRequest` slot. It never owns a `*Tab`, `*WindowState`, HWND-derived model
identity, workspace slice, or native index.

### Deferred drop execution

Do not transfer or destroy a source window inside the tab-control subclass.
`WM_LBUTTONUP` follows this order:

1. compute a final intent from stable IDs and the current screen point;
2. enter `.finishing`, clear feedback, and make `WM_CAPTURECHANGED` cleanup
   idempotent;
3. pass the button-up behavior required by the standard control, then release
   capture exactly once;
4. store the single pending request and post an application-private message to
   the application-lifetime notification HWND;
5. return from the subclass;
6. on later dispatch, take the request, return the coordinator to `.idle`,
   re-resolve all IDs/lifecycles, then reorder or invoke the shared transfer
   command.

Posting removes `DestroyWindow`, `SetForegroundWindow`, native tab rebuilds,
and their synchronous callbacks from the mouse callback's stack. If posting
fails, clear the request and run cancellation rollback while the source is
still valid. Only one request may be pending; starting another drag is rejected
until it is consumed.

Refactor `moveTabToState` into a shared operation accepting destination index,
optional new-window placement, and activation policy. Context-menu commands
continue to request append; drag requests use their hit-tested insertion slot.
Both paths call the same `prepareTransfer` and presentation recovery code.

## Visual and cursor feedback

Keep the standard tab control responsible for normal painting and accessibility.
Drag feedback is transient application chrome, not a replacement tab widget:

- draw a high-contrast insertion line at the computed source/destination item
  boundary after the control's normal paint, or through a no-activate overlay
  owned by the coordinator;
- optionally show a small no-activate tool-window proxy containing the effective
  tab label; it must be click-through, excluded from Alt+Tab/taskbar, and never
  participate in `WindowFromPoint` target discovery;
- use system colors/metrics and a distinct no-drop cursor when a ttyrtle window
  is under the pointer but its strip is not eligible;
- avoid animation when Windows client-area animation is disabled, and ensure
  high contrast never relies on color alone;
- invalidate the old and new target when hover changes and remove every marker
  on completion, cancellation, capture loss, DPI change, or destruction.

The minimum implementation requires the insertion marker and cursor state;
the label proxy is optional and must not delay functional delivery. Feedback
must not activate the target or move keyboard focus during hover.

## DPI and coordinate rules

The process remains Per-Monitor V2 aware. All target discovery uses one screen
`POINT` in raw physical pixels; `ClientToScreen`, `ScreenToClient`,
`GetWindowRect`, and tab item rectangles are converted only at HWND boundaries.
Never compare source-client coordinates directly with a destination rectangle,
and never manually rescale a screen point.

Use each HWND's current `GetDpiForWindow` result for drag thresholds, marker
thickness, proxy metrics, and device-independent tear-out sizing. Recompute
destination item rectangles after `WM_DPICHANGED`, resize, tab insertion, or
native overflow changes. A `WM_DPICHANGED` during drag removes stale feedback
and recomputes from the latest screen point; it does not mutate ownership.
Destroy and recreate DPI-bound proxy resources if needed. The destination's
normal transfer refresh remains responsible for sizing the moved terminal and
ConPTY to its own client geometry.

## Cancellation, rollback, and failure boundaries

Cancellation is a first-class operation, safe to call repeatedly. It must:

- clear candidate/active/hover/pending state as appropriate;
- remove feedback and restore the normal cursor;
- release capture only when the coordinator owns it and is not already handling
  `WM_CAPTURECHANGED`;
- restore the dragged tab to its original source index when live local reorder
  changed it, preserving `TabId`, active selection, and session routes;
- rebuild the native source view idempotently and restore focus to the terminal
  when the source is still live.

Cancel for Escape, `WM_CANCELMODE`, unexpected `WM_CAPTURECHANGED`, lost primary
button state, source close/destruction, session-driven tab close, application
shutdown, conflicting rename/context menu, or invalid source identity. Window
deactivation/capture transfer to another thread also cancels; do not reacquire
capture from `WM_CAPTURECHANGED`. A destination closing merely clears that
hover target and allows tear-out or another target.

Failure behavior is split at the existing ownership commit:

- before commit, allocation, target, window-construction, or transfer-preflight
  failure leaves ownership/routes unchanged; close an empty tear-out receiver
  and roll back local order;
- `TransferTransaction.commit` is the point of no return and remains
  allocation-free;
- after commit, native synchronization, renderer, focus, or foreground failure
  must not attempt a reverse transfer. Keep the new model ownership, log the
  error, and use the existing idempotent full-view rebuild/repaint path;
- source-empty closure occurs only after commit. The pending request and capture
  hold no source HWND dependency, so destroying the source cannot strand input;
- repeated or stale posted requests resolve by stable IDs and become harmless
  no-ops, never a close or retirement request for a different tab.

If rollback's native rebuild fails, model order is still authoritative. Queue a
full synchronization/repaint and leave the tab attached; never retire it as an
error recovery shortcut.

## Lifetime and reentrancy invariants

1. All drag model mutation runs on the UI thread, but every Win32 call is still
   treated as synchronously reentrant.
2. No `*WindowState`, workspace-item pointer, slice pointer, HWND, or native
   index survives a message boundary; posted work carries stable IDs and values.
3. The source is `.live`, owns the `TabId`, and matches the captured tab-control
   HWND whenever active input is processed.
4. Capture ends before a transfer begins. Transfer lifecycle guards remain the
   only ownership guard; drag state does not invent a detached phase.
5. Hover never changes workspace membership, session routing, active tabs,
   focus, z-order, or window activation.
6. Rename commit/cancel and native view synchronization finish before transfer
   preflight, then source/destination identities are resolved again.
7. Close and retirement paths call coordinator cancellation before detaching a
   dragged tab or destroying a capture/feedback HWND.
8. `WM_CAPTURECHANGED` observes `.finishing` without rolling back a valid queued
   drop and observes `.active` as cancellation. It never calls `SetCapture`.
9. A posted request cannot outlive the application notification receiver; the
   message loop termination condition includes no active drag or pending drop.
10. Feedback windows contain no model ownership and can be destroyed at any
    point without affecting the transfer result.

## Keyboard, focus, and accessibility

- Escape is handled at application-command routing before terminal translation
  while a candidate, active drag, or pending cancellable drop exists. Consume
  its press/release and suppress the corresponding character so Escape does not
  reach ConPTY. Other terminal keyboard input should not be silently queued
  during active capture; preserve existing focus behavior and document any
  keys consumed by the gesture.
- Alt+Tab, system commands, secure-desktop transitions, and another window
  taking capture cancel safely. Do not block the system menu or application
  shutdown to preserve a drag.
- Successful cross-window drops activate the moved tab, focus the receiving
  terminal, and update both captions. A canceled/failed drop restores source
  terminal focus when possible. Hover alone never steals focus.
- Retain native tab items, `TCITEM.lParam` identities, selection, arrow-key
  navigation, context menus, and the command-driven **Move Tab** alternatives.
  Mouse drag is never the only way to achieve the operation.
- After native lists synchronize, emit only the WinEvent/UIA notifications
  needed for reorder/selection if the standard control does not already expose
  them; avoid duplicate announcements. Verify the moved tab's accessible name,
  position-in-set, selected state, destination window name, and focus with
  Narrator and Accessibility Insights/Inspect.
- Markers/proxies are presentation-only and should not appear as focusable or
  meaningful accessibility elements. High contrast, text scaling, left-handed
  mouse configuration, and keyboard-only operation remain valid.

## Implementation stages

### Stage 1: Pure drag geometry and intent

- Add deterministic helpers for threshold decisions, strip containment,
  insertion slots, tear-out arming, DIP/physical-size conversion, and work-area
  clamping.
- Use half-open rectangles and explicit `[0, count]` insertion semantics.
- Add unit tests before wiring HWND discovery.

### Stage 2: Application coordinator and local regression parity

- Replace per-window `TabDrag` with the application-wide state machine.
- Route source tab subclass messages through stable IDs, DPI-aware thresholds,
  capture ownership, Escape, and idempotent cancellation.
- Preserve same-window live reorder and add original-order rollback.
- Keep existing rename, selection, context-menu, and middle-click behavior.

### Stage 3: Cross-HWND discovery and feedback

- Add topmost-root discovery through the application window registry and fresh
  target-control hit testing.
- Add destination insertion markers/cursors without activating the target.
- Handle overflow children, obscured windows, movement, resize, DPI, close, and
  feedback cleanup.

### Stage 4: Indexed shared transfer

- Refactor command and drag transfer entry points around destination index and
  activation policy.
- Add the deferred pending-drop message and stable-ID revalidation.
- Transfer into first/middle/last destination slots; close an empty source only
  after commit; recover presentation failures without reverse ownership moves.

### Stage 5: Tear-out placement

- Parameterize hidden destination creation with screen placement and normal
  client size.
- Create on release only, query its actual DPI, clamp to the target monitor work
  area, commit through the same transfer transaction, then show and focus it.
- Cover construction/preflight rollback and only-tab source destruction.

### Stage 6: Hardening and completion

- Complete failure injection, lifecycle/reentrancy, mixed-DPI, overflow,
  accessibility, high-contrast, and performance checks.
- Update `tabs.md`, README interaction documentation, and this plan's progress
  record during implementation; keep `todo.md` authoritative.

## Automated tests

### Unit tests

- threshold uses independent horizontal/vertical system metrics and does not
  start below either limit;
- insertion math returns before, between, after, empty-strip, clipped-item, and
  right-edge slots without off-by-one errors;
- same-source move index adjustment is correct in both directions;
- leaving/re-entering the source strip arms and disarms tear-out predictably;
- cancellation restores the original order and active `TabId` after multiple
  live reorder crossings;
- stable requests reject stale source, tab, destination, lifecycle, and index;
- source/DPI client-size conversion and work-area placement handle negative
  monitor coordinates and 96/144/192 DPI;
- state transitions are idempotent for release, Escape, capture change, close,
  and duplicate posted completion.

Extend workspace transfer tests to cover first, middle, and append insertion
through the shared command/drag entry point while preserving exact tab, pane,
session, process, route, label, active-neighbor, and output identity.

### Hidden Win32 integration tests

- drag within one native strip in both directions and verify existing identity,
  selection, focus, and `lParam` behavior;
- drag from source to the first, middle, trailing-whitespace, and last positions
  of a second strip; verify exact `*Tab`/session identity and native order;
- ensure hovering a background destination does not activate it, while a
  successful drop foregrounds/focuses it;
- obscure a ttyrtle strip with another top-level HWND and prove it is not a
  target; close or destroy a hovered destination before mouse-up and re-resolve;
- send Escape, `WM_CANCELMODE`, unexpected `WM_CAPTURECHANGED`, focus loss,
  source resize/DPI, source close, and session close at each coordinator phase;
- transfer the only source tab and verify capture/feedback end before its HWND
  is destroyed and other windows/message routing remain alive;
- inject destination capacity, hidden-window creation, renderer setup, posting,
  preflight, native synchronization, and foreground/focus failures at their
  named boundaries;
- tear out on negative-coordinate and synthetic 96/144/192-DPI monitor seams,
  checking bounded normal placement and destination terminal dimensions;
- verify pending output/EOF/child-exit/input-failure messages before, during,
  and after drop resolve to the one current owner;
- repeat drag/cancel/transfer/tear-out/close cycles under allocator and handle
  diagnostics, with no stale capture, proxy HWND, route, tab, or retirement.

Automated synthetic DPI tests are seams, not a substitute for real-monitor QA.

## Manual Windows QA matrix

Run Debug and ReleaseFast builds on supported Windows x64 with:

- one monitor at 100%, and two monitors at mixed 100%/150% and 150%/200%,
  including a monitor left of or above the primary;
- normal, maximized, snapped, minimized/restored, overlapping, and partially
  off-screen ttyrtle windows;
- destination strips with one tab, many tabs and native overflow buttons, long
  Unicode/emoji labels, renamed tabs, and background activity;
- drag slowly and quickly across monitor seams, between overlapping strips,
  over another application's window, taskbar, non-client areas, terminal
  content, and empty desktop;
- cancel via Escape, Alt+Tab, system menu, capture theft, source/destination
  close, display/DPI change, lock/unlock, and shutdown/logoff initiation;
- verify left-handed mouse settings and touchpad pointer input;
- verify no terminal Escape/mouse sequence leaks, no hover activation, correct
  foreground/focus after drop, and no unexpected process restart or output gap;
- Narrator plus Accessibility Insights/Inspect for tab names, selection, order,
  destination focus, keyboard move alternatives, and absence of focusable drag
  feedback;
- Windows high contrast, light/dark system settings, 200% text scaling, reduced
  animation, and both Direct2D and renderer fallback paths.

Record the OS build, display layout/scales, renderer path, assistive technology,
and result in this document before moving the tracker to **Done**.

## Performance and diagnostics

Pointer motion must not allocate, rebuild terminal render commands, resize
ConPTY, or synchronize native tab lists unless a same-window boundary is
actually crossed. HWND discovery and item-rectangle work are bounded by the
small number of live ttyrtle windows and visible tabs. Coalesce feedback
invalidations when the hover target is unchanged.

Add debug counters for candidates, started/canceled/completed drags, target
changes, indexed transfers, tear-outs, rollback attempts/failures, stale posted
requests, and feedback HWND balance. Do not log terminal content or tab titles.
Stress QA should show responsive pointer tracking during sustained terminal
output and balanced GDI/HWND resources after repeated tear-outs.

## Acceptance criteria

The feature is complete when:

- a tab reorders locally, transfers to any insertion slot in another live
  window, and tears out near the pointer without recreating its pane/session or
  losing output/input state;
- all ownership-changing drops use `prepareTransfer` and its allocation-free
  commit, shared with command-driven moves;
- target discovery respects z-order, registered stable identity, native strip
  hit testing, overflow controls, lifecycle, and Per-Monitor V2 coordinates;
- capture always ends, stale callbacks/requests are harmless, only-source-tab
  destruction is safe, and cancellation/preflight failure restores source order
  with exactly one owner and route;
- post-commit presentation failures retain coherent model ownership and recover
  through idempotent synchronization rather than reverse transfer;
- keyboard/system input, focus, accessibility, high contrast, and command-based
  alternatives follow the documented Windows behavior;
- unit and hidden-window coverage passes, the real mixed-DPI/accessibility QA
  matrix is recorded, and `zig build verify` passes;
- `tabs.md`, README, this plan, and the feature tracker reflect the completed
  behavior.

## References

- [Microsoft: About Tab Controls](https://learn.microsoft.com/en-us/windows/win32/controls/tab-controls)
- [Microsoft: Mouse Input Overview](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-mouse-input)
- [Microsoft: SetCapture](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setcapture)
- [Microsoft: WM_CAPTURECHANGED](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-capturechanged)
- [Microsoft: WindowFromPoint](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-windowfrompoint)
- [Microsoft: High DPI Desktop Application Development](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows)
- [Multiple top-level windows and tab transfer](multi-window-tab-transfer-plan.md)
- [Tabs architecture](tabs.md)
- [Runtime tabs implementation plan](runtime-tabs-plan.md)
