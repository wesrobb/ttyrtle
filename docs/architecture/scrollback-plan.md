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

Viewport movement, selection changes, resize, and DPI changes invalidate the
full render cache. A native scrollbar and configuration surface are deliberately
out of scope for this milestone.
