# ConPTY Terminal Support Roadmap

This roadmap tracks the work required to turn the current terminal-state
demonstration into an interactive Windows terminal backed by ConPTY.

The implementation is divided into four vertical steps. Complete them in order:
each step assumes the behavior and module boundaries established by the earlier
steps.

## Target architecture

```text
Win32 input events
        |
        v
Ghostty input encoding
        |
        v
ConPTY input queue and writer
        |
        v
Shell and child processes
        |
        v
ConPTY output reader
        |
        v
UI-thread output queue
        |
        v
Ghostty terminal model
        |
        v
GDI renderer
```

ConPTY owns the pseudoconsole and hosted process environment. Ghostty owns VT
parsing, terminal modes, and grid state. This application owns process
lifecycle, I/O transport, Win32 input translation, and rendering.

## Progress

Update this table as steps move through the workflow.

| Step | Plan | Status | Outcome |
| --- | --- | --- | --- |
| 1 | [ConPTY process and output](conpty-step-1-process-and-output.md) | Complete | A real shell launches and its output is rendered |
| 2 | [Basic keyboard input](conpty-step-2-basic-input.md) | Complete | The shell accepts mode-aware Unicode, editing, navigation, and control input without blocking the UI |
| 3 | [Resize and lifecycle](conpty-step-3-resize-and-lifecycle.md) | Not started | Resize, exit, and shutdown are reliable |
| 4 | [Terminal completeness](conpty-step-4-terminal-completeness.md) | Not started | Queries and common terminal side effects work |

Allowed status values are `Not started`, `In progress`, `Blocked`, and
`Complete`. When marking a step complete, also check its exit criteria in the
step plan and record verification below.

## Cross-step decisions

- Keep the Ghostty terminal model owned by the UI thread. Worker threads may
  move bytes through queues but must not mutate or render the model.
- Use synchronous pipe handles for ConPTY. Service output and input
  independently so a blocking operation on one channel cannot stop the other.
- Keep Win32 callbacks small. Put pseudoconsole lifecycle and transport in
  `src/conpty.zig`, and put growing input translation in `src/input.zig`.
- Treat terminal dimensions as cells. Derive them from DPI-scaled cell geometry
  and the usable client area.
- Preserve the existing smoke mode. Automated tests must not depend on an
  interactive shell remaining open.
- Release every Win32 handle and allocated process attribute list on both
  successful and failed startup paths.

## Global checklist

- [x] `src/conpty.zig` owns `HPCON`, pipes, process handles, and I/O workers.
- [x] Output crosses to the UI thread through an owned, synchronized queue.
- [x] All visible terminal rows render from Ghostty state.
- [x] Keyboard input is encoded using Ghostty terminal modes.
- [ ] Ghostty-generated replies share the ConPTY input queue.
- [ ] Window and pseudoconsole dimensions remain synchronized.
- [x] Child exit and user-initiated close both terminate cleanly.
- [x] Shutdown continues draining ConPTY output and cannot deadlock.
- [x] Unit tests cover the deterministic transport and rendering logic added so far.
- [x] Integration tests cover a finite real ConPTY child process.
- [x] `zig build verify` passes.
- [x] README describes the implemented terminal capability and limitations.

## Verification record

Add one entry when a step is completed.

| Date | Step | Commit/branch | Commands | Notes |
| --- | --- | --- | --- | --- |
| 2026-07-29 | 1 | `master` (working tree) | `zig fmt build.zig src test`; `zig build test`; `zig build test-integration`; `zig build smoke`; `zig build verify` | Finite child writes known truecolor VT text and exits cleanly. |
| 2026-07-29 | 2 | `master` (working tree) | `zig fmt build.zig src test`; `zig build test`; `zig build test-integration`; `zig build smoke`; `zig build verify` | Scan-code-aware input is Ghostty-encoded and queued to a dedicated writer; a finite child gates its output on received Unicode input. |

## Deferred beyond this roadmap

These four steps establish real terminal support, but they do not require a GPU
renderer, font shaping, tabs, profiles, configuration UI, shell integration,
accessibility, or session persistence. Track those separately rather than
expanding a ConPTY step indefinitely.
