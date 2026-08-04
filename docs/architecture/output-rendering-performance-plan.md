# Terminal output and glyph rendering performance

Keep sustained terminal output responsive by bounding work on the UI thread,
coalescing notifications and frames, retaining unchanged render state, and
avoiding per-cell DirectWrite layout and draw overhead for glyphs that do not
need shaping. Make the behavior measurable in Debug builds and opt-in
ReleaseFast runs, with an automated smoke threshold for the primary regression.

## Implemented design

- ConPTY readers enqueue owned chunks and notify the UI only when necessary.
  UI drains are bounded to 256 KiB and repost continuation work when a backlog
  remains, preserving ordering and final/error semantics.
- A terminal write batch performs one Ghostty refresh, preserves precise row
  damage, and schedules one frame for coalesced output.
- Retained rows filter unchanged damage. Text plans cache direct-glyph and
  shaped spans; glyph indices and shaped layouts use bounded caches.
- Contiguous direct glyphs with the same foreground are submitted as one
  DirectWrite glyph run. Joining scripts, combining text, emoji sequences, and
  other shaping-sensitive content remain on the shaped path.
- Frame tracing records queue, parse, render-state, cache, layout, draw, copy,
  present, and output-to-present timing plus backlog and cache counters. It is
  enabled by default in Debug and available in ReleaseFast with
  `-Dframe-trace=true`.
- The GPU smoke path sends a 180-line burst to a populated viewport, requires
  one coalesced presentation, and enforces a three-second completion limit.

## Implementation status

Complete. Unit coverage exercises bounded queue draining, notification and
error semantics, retained damage, text-plan classification and caching, and
direct-run boundaries. The GPU smoke path covers the end-to-end output burst.

Broader workload limits, stress matrices, and scroll-aware back-buffer pixel
copies remain separate roadmap work.
