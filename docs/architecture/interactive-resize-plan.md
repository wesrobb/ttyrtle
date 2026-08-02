# Interactive resize

Interactive window sizing has two independent effects. Terminal dimensions are
calculated and applied synchronously on every `WM_SIZE`, including a ConPTY
resize when a cell boundary is crossed. Pixel surface changes are coalesced
during `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` to one swap-chain resize per 8 ms,
with the last client size synchronously committed on exit. A missing timer
falls back to an immediate commit.

The Direct2D swap-chain target and retained terminal scene have separate
lifetimes. `ResizeBuffers` releases only the target bitmap. The scene bitmap is
keyed by grid geometry and DPI, so same-grid pixel resizes keep the render
command cache, DirectWrite layouts, and scene pixels. Presentation clears the
new target to the terminal background and copies that retained scene, leaving
new slack space as background.

While a coalesced target resize is pending, paint invalidations from
`HREDRAW`/`VREDRAW` are acknowledged without rendering. The committed resize
invalidates the whole window, where pending terminal damage is rendered with
the new target. DPI changes cancel queued work and commit synchronously.

Debug diagnostics record raw `WM_SIZE` messages, committed target resizes,
retained-scene recreations and redraws, and target-resize duration alongside
existing renderer frame traces. Scheduler unit tests cover coalescing, final
flushing, and cancellation; hidden lifecycle coverage proves same-grid resize
preserves the scene, layouts, and render cache, while continuing to exercise
resize, DPI, and GPU recovery.
