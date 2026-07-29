# win32-terminal

A deliberately small native Windows terminal prototype:

- Zig application and build
- native Win32 window/message loop via zigwin32
- terminal state and VT parsing via libghostty-vt
- a real shell hosted by ConPTY
- asynchronous, UI-thread-safe terminal output delivery
- direct, minimal rendering inspired by Nvy's native approach

Normal mode launches `%COMSPEC%` (falling back to `cmd.exe`), feeds its
UTF-8/VT output through the Ghostty terminal model, and paints all 80 by 24
cells with GDI. The UI remains responsive while the output reader blocks on an
idle shell.

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
interaction. The integration path launches a finite ConPTY child, verifies
known truecolor VT output in the Ghostty model, and confirms reader teardown.
GitHub Actions runs `zig build verify` on Windows with pinned Ghostty and
zigwin32 revisions.

ConPTY startup failures are recoverable errors. The failing API and its Win32
error code (or HRESULT for `CreatePseudoConsole`) are written to diagnostics
before the application exits.

## Deliberately not included yet

This milestone is intentionally one-way: there is no keyboard input yet.
ConPTY and the Ghostty grid remain fixed at 80 by 24 cells, and cursor
appearance, background colors, font shaping, selection, and GPU rendering are
also deferred.
