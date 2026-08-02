# Scrollback history

Each terminal session owns a Ghostty primary-screen history limited by the
named 10 MiB application default. The alternate screen retains no history.
Ghostty owns viewport movement and pinned selections, allowing copy and visual
selection to cross historical and live rows while correctly preserving wraps
and Unicode graphemes.

The mouse wheel scrolls local history unless the active terminal requests mouse
reporting; in that mode Shift+wheel stays local. Shift+Page Up/Down page by one
viewport less one row, while Ctrl+Home and Ctrl+End jump to history top and the
live bottom. Any user input sent to ConPTY returns the current tab to live.

Viewport movement reports full model damage, but the retained renderer compares
row fingerprints in both directions. A physical scroll rotates matching cached
rows and DirectWrite layouts, rebases their absolute drawing geometry, and
rebuilds only newly exposed rows plus any row affected by cursor movement.
Non-scroll full damage still rebuilds the viewport.

Selection updates compare Ghostty's old and new visible per-row ranges and
damage only rows whose selection changed. Selection, cursor, and color-only
updates retain shaped DirectWrite layouts and update their drawing effects in
place. Resize and DPI changes invalidate geometry and text resources normally.

A native scrollbar and configuration surface are deliberately out of scope for
this milestone. Configuration work will replace the named application history
limit with a user setting.

## Implementation status

Complete. Unit tests cover history retention, navigation clamping, pinned
selection, one-line and multi-line cache reuse in both directions, geometry
rebasing, and proportional damage. Hidden Win32 integration tests exercise GPU
layout retention, sustained output, resize/DPI changes, and device recovery.
The required `zig build verify` suite passes.
