# ttyrtle

A deliberately small native Windows terminal prototype:

- Zig application and build
- native Win32 window/message loop via zigwin32
- terminal state and VT parsing via libghostty-vt
- a real shell hosted by ConPTY
- asynchronous, UI-thread-safe terminal output delivery
- queued, mode-aware keyboard input via Ghostty's encoder
- non-blocking terminal query replies, title changes, and bells
- a workspace model with stable tab and terminal-session identities
- heap-stable tab owners and an application-level transfer coordinator
- independent top-level terminal windows and command-driven tab transfer
- non-blocking terminal-session retirement after tab or window close
- a native Win32 tab strip synchronized from the workspace model
- cursor, cell-background, inverse-video, and combining-mark rendering
- bracketed paste, selection, clipboard copy, focus, and mouse reporting
- direct, minimal rendering inspired by Nvy's native approach

Normal mode launches `pwsh.exe`, feeds its UTF-8/VT output through the Ghostty
terminal model, and paints retained dirty rows with Direct2D/DirectWrite on a
DXGI swap chain. This is the only rendering backend. Hardware D3D11 is
preferred and WARP is the software device fallback. If both device paths fail,
ttyrtle reports a native error and closes only the affected window. The UI
remains responsive while the output reader blocks on an idle shell. Keyboard
input is encoded on the UI thread from the active Ghostty terminal modes, then
written to ConPTY by a dedicated worker so a blocked child cannot stall
painting or output.

Ghostty-generated replies use the same ordered ConPTY input queue as keyboard
input. Device attributes, cursor and mode reports, terminal size reports, and
other supported Ghostty queries therefore remain non-blocking. OSC title
changes are applied on the UI thread and BEL uses the Windows notification
sound.

## Interaction

- `Ctrl+Shift+T` opens a new terminal tab.
- `Ctrl+Shift+N` opens an independent terminal window.
- `Ctrl+Shift+W` closes the active tab. Closing the final tab closes the window.
- `Ctrl+Tab` and `Ctrl+Shift+Tab` cycle tabs; `Alt+1` through `Alt+9` select a
  one-based tab position.
- Right-click a tab, or invoke the keyboard context menu, for New Tab, Rename,
  and Close actions.
- Drag a tab with the left mouse button to reorder same-window tabs.
- Drag a tab onto another ttyrtle window's tab strip to insert it at the shown
  marker, or release it sufficiently outside every eligible strip to tear it
  into a new window near the pointer. Press `Escape` to cancel and restore the
  original order.
- A tab's context menu provides **Move Tab to New Window** and a **Move Tab to
  Window** submenu. A move preserves the existing terminal, ConPTY child,
  title, selection, and scrollback.
- Terminal output continues to be parsed while its tab is inactive. OSC titles
  label the corresponding tab and window; an explicit tab name takes priority.
- `Ctrl+Shift+C` copies the current selection as Unicode text.
- `Ctrl+Shift+V` pastes Unicode clipboard text.
- Drag with the left mouse button to select text, including retained history.
- Hold `Shift` while dragging to select locally when an application has mouse
  reporting enabled.
- Focus and mouse events are sent only when requested by terminal modes.
- Each tab retains up to 10 MiB of primary-screen scrollback. Use the mouse
  wheel to browse it; when an application enables mouse reporting, hold
  `Shift` while wheeling for local history. `Shift+Page Up`/`Shift+Page Down`
  page through history, and `Ctrl+Home`/`Ctrl+End` go to its top/live bottom.
- Paste bytes are sanitized by Ghostty. Multiline paste is rejected unless
  bracketed-paste mode is active.

OSC 52 clipboard reads are never answered, so a hosted or remote program cannot
silently retrieve clipboard contents. OSC clipboard writes are ignored. Only
an explicit local copy or paste gesture accesses the Windows clipboard.

## Build

This checkout expects these sibling repositories:

```text
../ghostty
../zigwin32
../Nvy
```

Using Zig 0.16:

```powershell
zig build
zig build run
zig build -Doptimize=ReleaseFast -Dframe-trace=true run
```

ttyrtle currently targets 64-bit x86 Windows. Per-Monitor V2 DPI awareness is
enabled before its first HWND; 32-bit and ARM64 support are deliberately
deferred until their notification-token and test coverage are designed.

`Nvy` is a design/reference dependency, not a linked source dependency.

## Verification

Run the complete automated verification suite before committing:

```powershell
zig build test              # Fast Ghostty/model/render-command unit tests
zig build test-integration  # Hidden Win32 window lifecycle test
zig build smoke             # Self-closing end-to-end executable
zig build check             # Compile Debug and ReleaseFast
zig build verify            # Formatting plus every check above
```

The smoke path requests a paint synchronously and then exits through the normal
`WM_CLOSE`/`WM_DESTROY` message flow, so it does not depend on sleeps or manual
interaction. On normal Debug-session shutdown, diagnostics report aggregated
output batches/chunks, Ghostty refreshes, dirty and rebuilt rows, DirectWrite
layout rebuilds, requested and presented frames, GPU presents, and device
recreations. Tracing defaults on in Debug and off in optimized builds; the
`-Dframe-trace=true` option enables the same counters in ReleaseFast. The
integration path launches finite ConPTY children, verifies
known truecolor VT output and queued Unicode input in the Ghostty model,
confirms reader teardown, requires a hosted process to observe an exact
window-driven terminal resize, and exercises multiple inactive sessions,
background OSC labels, resize/DPI propagation, stale notifications,
independent windows, indexed cross-window drag/tear-out transactions,
command-driven transfers, asynchronous retirement, and keyboard routing.
GitHub Actions runs `zig build verify` on Windows with pinned Ghostty and
zigwin32 revisions.

The GPU smoke benchmark also sends a 180-line live-output burst to a populated
viewport. It must coalesce that burst into one presentation and complete within
three seconds. This guards against a regression that waits for v-sync once per
output notification; detailed diagnostics identify whether time is spent in
terminal refresh, retained-row rebuilding, text layout, scene drawing, or
presentation.

ConPTY startup failures are recoverable errors. The failing API and its Win32
error code (or HRESULT for `CreatePseudoConsole`) are written to diagnostics
before the application exits.

## Current limitations

Keyboard input supports printable Unicode, common editing/navigation keys,
function keys, modifiers, and repeats. Committed IME text follows the normal
Windows character path, but pre-edit composition and candidate positioning are
not rendered yet. Selection is backed by Ghostty's retained screen state and
can span scrollback and the live viewport.

The Direct2D renderer shapes one complete UTF-16 row at a time with persistent
system font fallback plus bundled Symbols Nerd Font Mono fallback for Nerd Font
Private Use Area glyphs. Ghostty graphemes retain exact one- or two-cell advances,
including combining marks, CJK, supplementary characters, emoji sequences, and
missing glyphs. Text colors are ranges within the row layout; backgrounds,
inverse video, underline, selection, and cursor drawing remain aligned to cell
rectangles. DirectWrite color fonts are enabled with its monochrome fallback.
The default terminal-safe typography disables standard, contextual,
discretionary, and historical ligatures plus pair kerning. Cell width, line
metrics, baseline, and underline geometry come from the configured DirectWrite
font face at the active DPI.

Font selection and size are not configurable yet. The internal workspace owns
each tab's pane root, terminal model, and ConPTY process. Tabs support creation,
closing, switching, inline renaming, context-menu actions, same-window drag
reordering, and dynamic OSC labels while inactive tabs continue to process
output. Heap-stable tab ownership lets the application move an existing pane
root between independent windows without recreating its terminal or process.
Closing a tab or window removes its visible UI promptly; its session cleanup
then completes asynchronously while the application notification receiver and
message pump remain alive. The [feature-work tracker](todo.md) is the
authoritative roadmap for future capabilities such as panes, configuration,
accessibility, and release work.
