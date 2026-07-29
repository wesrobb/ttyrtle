# win32-terminal

A deliberately small first step toward a fast, native Windows terminal:

- Zig application and build
- native Win32 window/message loop via zigwin32
- terminal state and VT parsing via libghostty-vt
- direct, minimal rendering inspired by Nvy's native approach

The current program feeds `Hello from libghostty.` through a real Ghostty
terminal grid and paints the resulting first row with GDI.

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
interaction. GitHub Actions runs `zig build verify` on Windows with pinned
Ghostty and zigwin32 revisions.

## Deliberately not included yet

There is no PTY, shell process, keyboard input, resizing, font shaping, or GPU
renderer yet. The next useful vertical slice is a ConPTY-backed shell whose
output is fed into the existing Ghostty terminal state.
