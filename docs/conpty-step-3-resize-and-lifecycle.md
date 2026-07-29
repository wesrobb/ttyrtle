# Step 3: Resize and Lifecycle

## Outcome

The terminal grid follows the Win32 client area, hosted applications observe
the correct terminal dimensions, and every exit path shuts down without leaks,
hangs, orphaned processes, or lost final output.

## Scope

- Derive rows and columns from the DPI-scaled client area and cell geometry.
- Resize both Ghostty and ConPTY to identical dimensions.
- Observe the child process exiting.
- Distinguish child exit, pipe failure, startup failure, and user close.
- Implement deadlock-safe ConPTY shutdown.
- Define session state transitions and make teardown idempotent.

Dynamic font selection and advanced DPI behavior may be deferred, but resize
logic must carry real cell pixel dimensions into Ghostty.

## Dimension model

Maintain one authoritative geometry value:

```text
client pixels - margins
          |
          v
floor(width / cell_width), floor(height / cell_height)
          |
          v
clamped non-zero columns and rows
          |
          +----> Ghostty handler resize
          |
          +----> ResizePseudoConsole
```

Ignore duplicate cell sizes produced by repeated `WM_SIZE` messages. Validate
that dimensions fit Win32 `COORD` fields before converting them.

Resize Ghostty through its stream handler rather than only mutating
`Terminal.core`. The handler can generate in-band size reports when a hosted
application has enabled them. Those generated replies will be wired into the
input path in Step 4.

During minimized or zero-sized client states, retain the last valid dimensions
instead of attempting a zero-cell resize.

## Session states

Use explicit states similar to:

```text
starting -> running -> closing -> closed
     |          |
     +--------> failed
```

Only one owner may initiate teardown. Repeated window messages, worker
notifications, and error callbacks must be able to observe or request closure
without closing the same handle twice.

Record the child exit code when it is available. A shell that exits normally
should either close the window or leave a clear exited-session state according
to a single documented policy.

## Child observation

Wait for the process handle outside the UI thread. On exit:

1. Capture the exit code.
2. Notify the UI thread.
3. Stop accepting new input.
4. Allow the output reader to reach EOF and deliver remaining bytes.
5. Complete session cleanup.

Do not infer process exit only from a quiet or temporarily empty output pipe.

## Deadlock-safe shutdown

Closing an `HPCON` can cause connected applications to write a final frame.
Older Windows versions may block in `ClosePseudoConsole` while that output is
not being drained.

The shutdown path must therefore:

1. Mark the session as closing and reject new user input.
2. Keep the output reader active.
3. Call `ClosePseudoConsole` from a thread other than the output reader.
4. Continue delivering output until EOF or broken pipe.
5. Wake and finish the writer without racing a closed handle.
6. Join all workers.
7. Close pipe, child thread, and child process handles.
8. Delete the process/thread attribute list and free its storage.

Define and document the ownership order so `WM_CLOSE`, `WM_DESTROY`, startup
failure, and child exit all converge on the same cleanup mechanism.

## Tasks

- [ ] Define terminal cell geometry, margins, and DPI scaling in one place.
- [ ] Convert client pixels to validated non-zero cell dimensions.
- [ ] Handle `WM_SIZE` and relevant DPI-change messages.
- [ ] Add a resize method to `TerminalModel` using the Ghostty handler.
- [ ] Call `ResizePseudoConsole` with matching dimensions.
- [ ] Avoid redundant resize work.
- [ ] Add an independent child-process waiter.
- [ ] Capture and surface the child exit code.
- [ ] Define explicit session states and legal transitions.
- [ ] Make session teardown idempotent.
- [ ] Keep output draining while `ClosePseudoConsole` runs.
- [ ] Join every worker and close every owned handle.
- [ ] Add unit tests for pixel-to-cell sizing and state transitions.
- [ ] Add integration tests for child-driven exit and host-driven close.
- [ ] Exercise repeated create/close cycles to catch leaks and races.

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

- Resizing the window changes shell wrapping at the correct column.
- Full-screen console applications observe updated rows and columns.
- Minimizing and restoring does not produce a zero-size error.
- Typing `exit` completes the configured child-exit behavior.
- Closing the window while output is busy does not hang.
- Repeated launch and close cycles do not leave shell processes behind.
- Final output produced during shell shutdown is displayed or intentionally
  accounted for.

## Exit criteria

- [ ] Ghostty and ConPTY always share the same valid cell dimensions.
- [ ] Hosted applications react correctly to window resizing.
- [ ] Child exit is detected independently of output traffic.
- [ ] All shutdown initiators converge on one idempotent path.
- [ ] Output remains drained while the pseudoconsole closes.
- [ ] No process, thread, pipe, or pseudoconsole handles leak.
- [ ] Automated verification passes.
