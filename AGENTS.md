# Repository Guidelines

## Project Structure & Module Organization

This repository is intentionally small:

- `src/main.zig` is the thin entry point; `src/app.zig` owns Win32 lifecycle.
- `src/terminal.zig` wraps Ghostty; `src/render_commands.zig` creates
  deterministic drawing commands consumed by GDI.
- `src/test_root.zig` collects unit tests; `test/integration.zig` exercises a
  hidden real window.
- `build.zig` defines the executable, dependencies, run step, and Windows
  subsystem configuration.
- `build.zig.zon` references the sibling `../ghostty` and `../zigwin32`
  checkouts.
- `README.md` describes the current milestone and expected local layout.

Add unit tests beside the module they exercise and Win32 integration tests under
`test/`. Put future icons, shaders, or fonts under `assets/`.

## Architecture Overview

Keep platform integration native and direct, following Nvy's general approach.
zigwin32 owns Win32 API bindings; `libghostty-vt` owns VT parsing and terminal
grid state. Rendering, ConPTY lifecycle, and input translation belong to this
application. Avoid duplicating terminal semantics already provided by Ghostty.

## Build, Test, and Development Commands

Use Zig 0.16 on Windows:

```powershell
zig build                         # Debug build
zig build run                     # Build and launch
zig build -Doptimize=ReleaseFast  # Optimized build
zig build test                    # Fast unit tests
zig build test-integration        # Hidden Win32 lifecycle tests
zig build smoke                   # Self-closing executable smoke test
zig build verify                  # Required full verification
zig fmt build.zig src             # Format Zig sources
```

The expected sibling directories are `../ghostty`, `../zigwin32`, and `../Nvy`.
Ghostty SIMD is currently disabled in `build.zig` for compatibility with the
local Zig/MSVC toolchain.

## Coding Style & Naming Conventions

Run `zig fmt` before committing. Use four-space indentation and standard Zig
conventions: `snake_case` for functions and variables, `TitleCase` for types,
and descriptive lowercase filenames. Keep Win32 callbacks small; move growing
PTY, rendering, and input responsibilities into focused modules. Handle Win32
failure returns explicitly and release every acquired OS or GDI resource.

## Testing Guidelines

Run `zig build verify` before reporting work complete. New non-UI logic must
include Zig `test` blocks; name tests by behavior, such as
`test "SGR output updates foreground color"`. Keep logic deterministic and
outside Win32 callbacks so `zig build test` remains fast. Extend the integration
suite for lifecycle behavior. Avoid screenshot goldens unless rendering uses a
bundled font and fixed DPI.

## Commit & Pull Request Guidelines

History currently uses concise, imperative summaries such as
`Initial Win32 terminal prototype`. Keep each commit focused and explain
non-obvious compatibility choices in its body. Pull requests should summarize
behavior, list verification commands, link relevant issues, and include a
screenshot or short recording for visible UI changes. Do not commit
`.zig-cache/`, `zig-out/`, or `zig-pkg/`.
