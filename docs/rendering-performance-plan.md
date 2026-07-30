# Rendering Performance and DirectWrite Plan

## Objective

Make full-screen terminal updates stay responsive in Debug and Release builds,
then replace the prototype GDI renderer with a retained, GPU-accelerated
Direct2D/DirectWrite renderer on a DXGI swap chain. The final renderer must:

- parse every drained ConPTY batch before refreshing Ghostty's render state;
- rebuild only rows reported dirty by Ghostty;
- retain CPU-side row data between frames;
- keep expensive font and brush resources alive across frames;
- shape Unicode text and use system font fallback without losing terminal-cell
  positioning;
- present one frame for one coalesced terminal update;
- recover cleanly from resize, DPI changes, and graphics-device loss.

Scroll-aware copying of already-rendered pixels is deliberately deferred to
`todo.md`. Dirty-row redraw is the first scrolling implementation.

## Target architecture

```text
ConPTY reader thread
        |
        v
owned output queue
        |
        v
UI thread drains every queued chunk
        |
        v
TerminalModel parses all chunks
        |
        v
one Ghostty RenderState update
        |
        v
RenderDamage (none / dirty rows / full)
        |
        v
retained CPU row cache
        |
        v
DirectWrite row layouts + Direct2D drawing
        |
        v
one DXGI Present
```

Ghostty remains the source of terminal semantics and viewport cell data. The
application owns damage consumption, retained render data, font policy, GPU
resources, and presentation.

## Phase 1: Batch ConPTY output into one model refresh

**Status:** Complete (`d1fc296`). Phase 2 is the next implementation phase.

### Changes

- Split `TerminalModel.write` into parsing and refresh operations, or add a
  `writeBatch` API which accepts all drained chunks.
- Feed every chunk to the existing `TerminalStream` in order. Do not concatenate
  solely to batch: the stream already preserves partial UTF-8 and VT sequences
  across calls.
- Check Ghostty reply failures after parsing the complete batch, then call
  `RenderState.update` exactly once.
- Change `handleConptyOutput` to pass the complete drained batch to the model,
  apply terminal effects after the refresh, and schedule at most one render.
- Preserve the current queue notification invariant: output arriving during a
  drain must cause a later UI-thread notification.

### Tests

- Multiple chunks produce the same terminal state as one combined byte slice.
- UTF-8 code points and CSI/OSC sequences split across chunk boundaries remain
  correct.
- A multi-chunk drain performs one render-state refresh.
- Ghostty replies retain their byte ordering relative to keyboard input.
- Existing finite-child integration and shutdown tests continue to pass.

### Exit criteria

- One drained output batch causes one Ghostty render-state refresh and no more
  than one requested frame.

## Phase 2: Expose and consume Ghostty damage

**Status:** Complete. Ghostty full/partial damage is copied into an
application-owned, coalescing row-damage queue. Cursor movement and blinking,
selection changes, resize, DPI changes, and global terminal visual changes feed
the same queue. The Win32 path invalidates damaged row bands, and model damage
is acknowledged only after the retained cache has accepted it.

### Changes

- Add a small application-facing damage type in `terminal.zig`:
  `none`, `partial` with dirty row indices, or `full`.
- After `RenderState.update`, read `RenderState.dirty` and each
  `RenderState.Row.dirty` flag. Copy the result into application-owned damage
  before clearing the Ghostty flags.
- Treat dimension, default-color, palette, active-screen, font, DPI, renderer
  recreation, and device-loss changes as full damage.
- Track the old and new cursor rows separately so cursor movement dirties both
  rows without requiring a full redraw.
- Keep selection damage row-scoped and merge it with terminal damage.
- Coalesce repeated row indices and promote to full damage when every row is
  dirty.

### Tests

- A one-line terminal update reports only that row.
- A full-screen mode or palette change reports full damage.
- Cursor movement damages the old and new rows.
- Cursor blinking damages only the cursor row.
- Selection changes damage only affected rows.
- Damage is cleared only after the retained cache has accepted it.

### Exit criteria

- Clean frames do not scan the grid, partial updates enumerate only dirty rows,
  and all global visual changes force a full rebuild.

## Phase 3: Introduce a retained row cache

**Status:** Complete. `RenderCache` retains UTF-16 text, UTF-16-to-cell mapping,
cell metadata, drawing runs, and per-row generations. It rebuilds only damaged
rows, reuses row storage, resizes without stale entries, and supplies cached
commands to expose paints without reading clean terminal rows. Phase 4 is the
next implementation phase.

### Changes

- Replace the transient whole-screen `render_commands.Frame` with a
  `RenderCache` sized to the current terminal rows and columns.
- Give each cached row reusable storage for:
  - UTF-16 text;
  - UTF-16-to-cell mapping;
  - foreground/background and decoration runs;
  - wide-cell, spacer, selection, and cursor metadata.
- Rebuild only rows named by `RenderDamage`; preserve clean rows unchanged.
- Use retained capacities so normal redraws do not allocate.
- Keep the cache independent of GDI, Direct2D, and DirectWrite objects. Backend
  resources derived from a row may be cached separately and invalidated by the
  row generation.
- Remove per-paint calls to `model.cell` for clean rows.

### Tests

- Partial updates preserve unchanged row generations and buffers.
- Resize grows and shrinks the cache without stale rows.
- Non-BMP characters, combining graphemes, wide characters, inverse video,
  faint text, underline, selection, and cursor geometry survive conversion.
- Allocation-count or capacity tests show that steady-state cursor blinking and
  repeated updates reuse storage.

### Exit criteria

- A partial update performs work proportional to its dirty rows rather than the
  entire viewport.

## Phase 4: Cache resources in the GDI bridge

**Status:** Complete. GDI rendering now lives behind a renderer interface which
owns a retained compatible DC and grow-only bitmap, a font keyed by DPI and
cell metrics, and a bounded 64-entry RGB brush cache. Terminal damage redraws
only named row bands, while new buffers, full damage, and expose paints retain
full-redraw paths. Resource-key policy tests cover font reuse and bounded brush
eviction, and the hidden-window lifecycle suites exercise renderer teardown.
Phase 5 is the next implementation phase.

This is an interim step that keeps the application responsive while the GPU
backend is developed and establishes explicit resource ownership.

### Changes

- Move GDI rendering out of `app.zig` behind a renderer interface.
- Create one `HFONT` per font/DPI/metrics key and reuse it until that key
  changes.
- Keep a bounded RGB-keyed solid-brush cache, with explicit eviction, teardown,
  and cache reset when appropriate. This must not grow without limit when an
  application cycles through truecolor values.
- Reuse the compatible DC and bitmap, resizing only when the client area
  outgrows them.
- Draw only dirty row rectangles from the retained row cache, then copy only
  those rectangles to the window.
- Keep a full-redraw path for expose, resize, and renderer invalidation.

### Tests

- Repeated paints do not create new fonts or brushes.
- DPI/font changes replace the font exactly once.
- All GDI objects are released during normal shutdown and initialization
  failure.
- Hidden-window smoke and integration modes retain their current behavior.

### Exit criteria

- GDI no longer allocates a frame, font, or brush set for each `WM_PAINT`.

## Phase 5: Add the Direct2D/DirectWrite/DXGI backend

**Status:** Complete. Direct2D/DirectWrite is the primary renderer, with a
hardware D3D11 device and WARP fallback, a frame-latency-capped two-buffer
flip-model swap chain, retained scene bitmap, bounded brush cache, and
DPI-keyed text format. Retained DirectWrite layouts are cached per row, keyed
by retained-row and font generations, and released on row removal,
font changes, device recreation, and shutdown. Resize and DPI changes recreate
target resources and force full scene redraw; device loss rebuilds the GPU stack
and retries once before falling back to GDI.

The hidden Phase 5 integration scenario verifies clean-paint layout reuse,
dirty-row layout rebuilding, exactly one successful `Present` for a multi-chunk
output batch, repeated minimize/restore and resize lifecycles, full scene
invalidation, DPI layout invalidation, injected device-loss recovery, and 180
sequential Debug scrolling updates with exact presentation accounting and a
12-second responsiveness ceiling. The full required verification suite passed
on 2026-07-30. Phase 6 subsequently replaced per-run layouts with complete-row`nshaping while preserving these lifecycle invariants.
### Resource model

Create a focused module such as `src/renderer/d2d.zig` which owns:

- a hardware D3D11 device and immediate context, created with BGRA support;
- the corresponding DXGI device, adapter, and factory;
- a two-buffer flip-model swap chain for the HWND;
- frame-latency control so the UI cannot queue an unbounded number of frames;
- an `ID2D1Factory`, device, device context, and swap-chain target bitmap;
- a persistent device-local scene bitmap containing the latest terminal frame,
  so clean rows do not depend on which flip-model buffer is current;
- an `IDWriteFactory`, text format, system font fallback, and typography
  settings;
- reusable Direct2D solid-color brushes or a bounded color-keyed brush cache;
- per-row DirectWrite layouts keyed by retained-row generation and font
  generation.

Use zigwin32 bindings directly. Nvy's initialization and device-loss paths are
the behavioral reference, but ttyrtle should keep the renderer isolated from
the window procedure and terminal model.

### Frame lifecycle

- Begin drawing only when damage or an expose event requires a frame.
- Recreate row layouts only for dirty rows or after a font-generation change.
- Draw dirty rows into the persistent scene bitmap; leave clean rows untouched.
- Set the swap-chain bitmap as the target, composite the scene bitmap, and draw
  transient overlays such as the cursor.
- End the Direct2D draw and call `Present` once per coalesced update.
- Do not make `WM_PAINT` rebuild terminal state. It should validate the paint
  region and request renderer presentation/redraw as necessary.

### Resize and failure handling

- Release target-dependent resources before `ResizeBuffers`, then recreate the
  Direct2D target and scene bitmaps and mark the scene fully dirty.
- Recompute DPI-scaled font metrics and terminal dimensions on `WM_DPICHANGED`.
- On `D2DERR_RECREATE_TARGET`, `DXGI_ERROR_DEVICE_REMOVED`, or
  `DXGI_ERROR_DEVICE_RESET`, release GPU-dependent COM objects, recreate the
  device stack, and mark all rows dirty.
- Release COM objects in reverse dependency order on shutdown and every partial
  initialization failure.
- Define a software/WARP or temporary GDI fallback policy so lack of a hardware
  device produces a usable error path rather than a blank window.

### Tests

- Put device-independent row conversion and damage logic under unit tests.
- Keep GPU lifecycle coverage in hidden-window integration tests.
- Exercise repeated resize/minimize/restore and simulated full invalidation.
- Verify that one output batch produces no more than one `Present`.
- Run the smoke path with the GPU renderer and retain a fallback smoke path if
  CI lacks a usable hardware adapter.

### Exit criteria

- Direct2D/DirectWrite is the normal renderer, GDI is no longer the primary
  paint path, and full-screen scrolling remains responsive in a Debug build.

## Phase 6: Font fallback, shaping, and terminal-cell correctness

**Status:** Complete. The GPU backend now creates one DirectWrite layout for each
complete retained row, preserving the row's UTF-16-to-cell mapping and explicit
grapheme spans. System font fallback is attached persistently to the primary
Consolas text format. Each shaped cluster is measured and receives positive or
negative trailing spacing so its total advance is exactly the one- or two-cell
advance supplied by Ghostty; combining sequences remain in their base cluster,
and fallback or missing glyphs cannot move later columns.

The default typography policy is terminal-safe: standard, contextual,
discretionary, and historical ligatures are disabled, as is pair kerning. Text
colors are DirectWrite drawing-effect ranges on the single row layout, while
backgrounds, inverse video, underline, selection, and cursor geometry remain
cell-aligned Direct2D commands. Color-font drawing is requested on every row;
DirectWrite retains its normal monochrome glyph path where color layers are not
available.

Cell width, height, baseline, ascent, descent, underline position, and underline
thickness are calculated from the selected DirectWrite font face and its `0`
glyph metrics at the active DPI. GDI-style fixed metrics are used only when the
GPU/DirectWrite backend is unavailable. Font cache keys include family, size,
fallback, typography, cell geometry, and DPI generations, and any change clears
all row layouts.

The Phase 6 corpus covers ASCII and PowerShell prompts, decomposed and
precomposed Latin, CJK, supplementary-plane surrogate pairs, emoji variation
selectors and ZWJ sequences, mixed scripts, box drawing, block elements,
colored/inverse/underlined cells, stable missing-glyph advances, and clean-row
layout-generation retention across partial updates. The full required
verification suite passed on 2026-07-30. Phase 7 subsequently added the
Debug-only counters; its manual performance measurements remain outstanding.

### Changes

- Create a persistent primary `IDWriteTextFormat` from the configured
  monospaced font and attach DirectWrite's system `IDWriteFontFallback`.
- Shape complete grapheme clusters, not isolated code points. Preserve the
  UTF-16-to-cell map so style ranges and terminal columns remain exact.
- Apply style and color ranges to one row layout, while keeping backgrounds and
  terminal decorations aligned to cell rectangles.
- Constrain shaped output to terminal advances:
  - ordinary cells occupy one cell;
  - wide graphemes occupy two cells;
  - combining marks remain attached to their base grapheme;
  - fallback glyph choice must not change terminal column positions.
- Decide ligature policy explicitly. Default to terminal-safe shaping, with
  discretionary ligatures disabled unless a later setting enables them.
- Enable DirectWrite color-font rendering where supported and provide a
  monochrome fallback.
- Derive cell width, ascent, descent, underline, and baseline from DirectWrite
  font metrics rather than GDI `CreateFontW` dimensions.
- Invalidate every row layout when the font family, size, fallback policy,
  typography, or DPI changes.

### Verification corpus

- ASCII and PowerShell prompt text.
- Latin combining marks and precomposed equivalents.
- CJK wide characters.
- Supplementary-plane characters represented by UTF-16 surrogate pairs.
- Emoji with variation selectors and zero-width joiners.
- Mixed-script rows which require more than one fallback font.
- Box drawing, block elements, underline, inverse video, and colored runs.
- Missing-glyph behavior with stable cell advances.

### Exit criteria

- Representative Unicode text uses system fallback, grapheme clusters remain
  intact, and every glyph stays aligned to Ghostty's cell grid.

## Phase 7: Remove the prototype path and measure

**Status:** In progress. The obsolete transient frame path is already gone and
the retained-renderer architecture is documented. Lightweight counters now
track output batches and chunks, Ghostty refreshes, accepted dirty rows, rebuilt
rows, row-layout rebuilds, logical frame requests, successful GPU/GDI
presentations, GPU presentations, and successful device recreations. Counter
fields and increments are compile-time-elided outside Debug and tests. A normal
Debug session writes one aggregated counter line to diagnostics during clean
shutdown. The manual performance acceptance checks remain outstanding.

### Changes

- Remove transient `Frame.build` and the per-paint GDI object lifecycle after
  the Direct2D backend and fallback policy are proven.
- Update the architecture documentation and README to describe the retained
  Direct2D renderer accurately.
- Add lightweight Debug-only counters for:
  - ConPTY chunks parsed per batch;
  - Ghostty refreshes;
  - dirty and rebuilt rows;
  - row-layout rebuilds;
  - frames requested and presented;
  - device recreations.
- Keep counters out of the hot path in optimized builds.

### Performance acceptance checks

- Hold a scrolling key in Neovim and compare Debug and ReleaseFast behavior.
- Confirm that multiple ConPTY chunks commonly collapse into one refresh and
  one presentation.
- Confirm that cursor blink performs no terminal refresh and rebuilds at most
  one row.
- Confirm that a single-row update does not rebuild clean row layouts.
- Compare CPU use and input latency against the current GDI baseline and Nvy on
  the same window size, font size, and monitor.

## Required verification

Run after each phase:

```powershell
zig fmt build.zig src test
zig build test
zig build test-integration
zig build smoke
zig build verify
```

For visible renderer phases, also record a short manual test of Neovim
full-screen scrolling, Unicode fallback, DPI changes, resize, minimize/restore,
and device recovery where it can be induced.
