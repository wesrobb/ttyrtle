# Interactive resize

Interactive window sizing has two independent effects. The presentation target
is resized synchronously on every non-minimized `WM_SIZE`, so each following
paint uses the current client pixels. Terminal dimensions are also calculated
synchronously, but a terminal and ConPTY resize occurs only when a cell
boundary is crossed.

The Direct2D swap-chain target and retained terminal scene have separate
lifetimes. `ResizeBuffers` releases only the target bitmap. The scene bitmap is
keyed by grid geometry and DPI, so same-grid pixel resizes keep the render
command cache, DirectWrite layouts, and scene pixels. Presentation clears the
new target to the terminal background and copies that retained scene, leaving
new slack space as background.

Every nonzero client update invalidates the complete client area, even with no
terminal-model damage. The next `WM_PAINT` clears new slack to the terminal
background and copies the retained scene at its natural size. DPI changes use
the same synchronous path.

Debug diagnostics record raw `WM_SIZE` messages, applied target resizes,
retained-scene recreations and redraws, and target-resize duration alongside
existing renderer frame traces. Hidden lifecycle coverage proves each
same-grid client size is applied and presented while preserving the scene,
layouts, and render cache, and continues to exercise resize, DPI, and GPU
recovery.
