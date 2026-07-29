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

## Deliberately not included yet

There is no PTY, shell process, keyboard input, resizing, font shaping, or GPU
renderer yet. The next useful vertical slice is a ConPTY-backed shell whose
output is fed into the existing Ghostty terminal state.
