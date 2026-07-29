# ttyrtle

A deliberately small native Windows terminal prototype:

- Zig application and build
- native Win32 window/message loop via zigwin32
- terminal state and VT parsing via libghostty-vt
- a real shell hosted by ConPTY
- asynchronous, UI-thread-safe terminal output delivery
- queued, mode-aware keyboard input via Ghostty's encoder
- non-blocking terminal query replies, title changes, and bells
- cursor, cell-background, inverse-video, and combining-mark rendering
- bracketed paste, selection, clipboard copy, focus, and mouse reporting
- direct, minimal rendering inspired by Nvy's native approach

Normal mode launches `%COMSPEC%` (falling back to `cmd.exe`), feeds its
UTF-8/VT output through the Ghostty terminal model, and paints all 80 by 24
cells with GDI. The UI remains responsive while the output reader blocks on an
idle shell. Keyboard input is encoded on the UI thread from the active Ghostty
terminal modes, then written to ConPTY by a dedicated worker so a blocked child
cannot stall painting or output.

Ghostty-generated replies use the same ordered ConPTY input queue as keyboard
input. Device attributes, cursor and mode reports, terminal size reports, and
other supported Ghostty queries therefore remain non-blocking. OSC title
changes are applied on the UI thread and BEL uses the Windows notification
sound.

## Interaction

- `Ctrl+Shift+C` copies the current selection as Unicode text.
- `Ctrl+Shift+V` pastes Unicode clipboard text.
- Drag with the left mouse button to select text.
- Hold `Shift` while dragging to select locally when an application has mouse
  reporting enabled.
- Focus and mouse events are sent only when requested by terminal modes.
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
```

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
interaction. The integration path launches finite ConPTY children, verifies
known truecolor VT output and queued Unicode input in the Ghostty model,
confirms reader teardown, and requires a hosted process to observe an exact
window-driven terminal resize.
GitHub Actions runs `zig build verify` on Windows with pinned Ghostty and
zigwin32 revisions.

ConPTY startup failures are recoverable errors. The failing API and its Win32
error code (or HRESULT for `CreatePseudoConsole`) are written to diagnostics
before the application exits.

## Current limitations

Keyboard input supports printable Unicode, common editing/navigation keys,
function keys, modifiers, and repeats. Committed IME text follows the normal
Windows character path, but pre-edit composition and candidate positioning are
not rendered yet. Selection is viewport-local and does not yet scroll beyond
the visible grid.

The GDI renderer supports terminal foreground/background colors, inverse and
faint text, underline, cursor shapes and blinking, wide-cell spacing, and
combining marks. It does not provide font shaping, ligatures, configurable
fonts, GPU rendering, or perfect grapheme placement. Advanced DPI behavior,
configuration, tabs, profiles, accessibility, shell integration, and session
persistence remain separate future work.
