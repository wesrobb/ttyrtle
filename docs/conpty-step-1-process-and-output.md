# Step 1: ConPTY Process and Output

## Outcome

The normal application launches a real shell inside ConPTY, continuously reads
its UTF-8/VT output, feeds that output into the existing Ghostty terminal model,
and paints every visible grid row. The UI message loop must remain responsive
while the shell is idle.

This step establishes one-way data flow. Interactive keyboard input belongs to
Step 2.

## Scope

- Add a focused `src/conpty.zig` session abstraction.
- Create the two synchronous pipe pairs required by ConPTY.
- Create an `HPCON` with an initial size of 80 columns by 24 rows.
- Launch an initial shell, using `%COMSPEC%` with `cmd.exe` as a documented
  fallback.
- Drain ConPTY output on a worker thread.
- Transfer owned output chunks to the UI thread.
- Feed chunks into `TerminalModel.write` on the UI thread.
- Invalidate the window after terminal state changes.
- Render all visible Ghostty rows rather than only row zero.
- Keep smoke mode deterministic and independent of a long-running shell.

## Session ownership

`conpty.Session` should own at least:

- The pseudoconsole handle.
- The host-side input write handle.
- The host-side output read handle.
- The child process and primary thread handles.
- The output reader thread and its termination state.
- The synchronized output queue.

Startup should either return a fully initialized session or release every
partially created resource. Prefer a single `deinit` path supported by
`errdefer` during construction.

## Startup sequence

1. Create the input pipe. Retain its write side and give its read side to
   ConPTY.
2. Create the output pipe. Retain its read side and give its write side to
   ConPTY.
3. Call `CreatePseudoConsole` with a cell-based `COORD`.
4. Allocate and initialize a one-entry process/thread attribute list.
5. Add `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
6. Launch the mutable UTF-16 shell command line with `CreateProcessW` and
   `EXTENDED_STARTUPINFO_PRESENT`.
7. Close the local copies of the pipe ends given to ConPTY. This is required so
   EOF and broken-pipe detection work later.
8. Start the output reader.

Do not request `PSEUDOCONSOLE_INHERIT_CURSOR`; this app does not inherit a
cursor from another console.

## UI-thread handoff

The reader blocks in `ReadFile`, copies each non-empty result into an owned
queue item, and posts one custom `WM_APP` message. The window procedure handles
that message by:

1. Draining all currently queued chunks.
2. Calling `TerminalModel.write` for each chunk in byte order.
3. Releasing the chunks.
4. Calling `InvalidateRect` once.

Posting may be coalesced so the message queue does not grow once per read. The
queue must remain correct if output arrives between draining it and clearing
the posted-message flag.

Normal reader termination includes EOF and `ERROR_BROKEN_PIPE`. Other errors
should be captured for diagnostics and reported to the UI thread without
panicking in the worker.

## Rendering work

Replace the current fixed first-row frame with commands for the full visible
grid. The initial renderer may retain fixed cell geometry, but it must:

- Visit every visible row and column.
- Preserve row and column positions even across blank cells.
- Draw foreground text at the correct cell location.
- Fill the complete client background.
- Avoid fixed limits sized only for 80 columns or one row.

Background colors, cursor appearance, selection, shaping, and advanced glyph
handling may remain for later steps, but the data structures introduced here
should not assume one row.

## Tasks

- [x] Add `src/conpty.zig` and include it only in Win32 builds.
- [x] Implement failure-safe pipe and pseudoconsole creation.
- [x] Implement process attribute-list allocation and cleanup.
- [x] Launch `%COMSPEC%` in normal mode.
- [x] Close temporary pipe handles immediately after process creation.
- [x] Implement the blocking output reader.
- [x] Implement the synchronized output queue and custom window message.
- [x] Keep all `TerminalModel` access on the UI thread.
- [x] Generalize render commands and painting to all rows.
- [x] Preserve the existing deterministic smoke behavior.
- [x] Add unit tests for queue ordering and render command generation.
- [x] Add an integration path using a finite command that prints known VT text
      and exits.
- [x] Document recoverable startup errors with useful Win32 error context.

## Verification

Run:

```powershell
zig fmt build.zig src test
zig build test
zig build test-integration
zig build smoke
zig build verify
```

Manually confirm:

- The window shows a real shell prompt.
- Output from the shell includes its startup text and prompt colors.
- The window remains responsive while the shell waits for input.
- Closing the test child does not leave a reader thread running.
- At least 24 rows can be painted without truncating the frame representation.

## Exit criteria

- [x] Normal mode launches a real ConPTY-hosted shell.
- [x] Shell output reaches Ghostty in original byte order.
- [x] Ghostty is never mutated from the reader thread.
- [x] Every visible row can be rendered.
- [x] Startup failures and finite child exit release all resources.
- [x] Smoke and full verification pass.
