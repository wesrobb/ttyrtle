# Feature work

This is ttyrtle's single source of truth for feature-work status and planning.

## Statuses

- **Needs planning**: the feature has a defined outcome but no approved plan.
- **Planned**: implementation has not started; the entry links to its plan.
- **In progress**: implementation is underway; the entry links to its plan.
- **Done**: implementation and its required verification are complete; the
  entry links to the plan that records that work.

Every entry except **Needs planning** must link to its plan. Create that plan
under `docs/architecture/` before changing an entry to **Planned**; update this
file as the work advances. Architecture documents may describe designs and
constraints, but they do not replace this tracker.

## Done

- **Done** — [Same-window runtime tabs](docs/architecture/runtime-tabs-plan.md):
  independent terminal and ConPTY sessions; create, close, switch, rename,
  context menu, middle-click close, shortcuts, drag reordering, inactive output
  processing, dynamic OSC labels, and multi-session resize/DPI/teardown tests.
- **Done** — [Multi-session workspace foundation](docs/architecture/runtime-tabs-plan.md):
  stable tab/session identities, workspace ownership, notification routing, and
  safe per-session lifecycle handling for one top-level window.
- **Done** — [Scrollback history](docs/architecture/scrollback-plan.md):
  per-session Ghostty history with a 10 MiB application limit, keyboard and
  mouse navigation, selection across historical and live rows, and
  bidirectional retained-renderer scroll reuse.
- **Done** — [Pixel-correct live resizing](docs/architecture/interactive-resize-plan.md):
  synchronous Direct2D target changes, terminal/ConPTY updates only at cell
  boundaries, and retained-scene reuse for pixel-only resizes.
- **Done** — [Multiple top-level windows and tab transfer](docs/architecture/multi-window-tab-transfer-plan.md):
  independent windows, command-driven transfer, lifecycle routing, asynchronous
  retirement, automated `zig build verify` coverage, and the required manual
  mixed-DPI, accessibility, Windows-behavior, and renderer-fallback QA.
- **Done** — [Bundled Nerd Font symbol fallback](docs/architecture/font-fallback-plan.md):
  application-local Symbols Nerd Font Mono fallback for Private Use Area
  glyphs, installed with the executable and covered by license attribution.
- **Done** — [Terminal output and glyph rendering performance pass](docs/architecture/output-rendering-performance-plan.md):
  bounded/coalesced ConPTY output delivery, retained damage and text-plan
  caching, batched direct-glyph runs, detailed frame tracing, and an automated
  live-output GPU smoke benchmark.

## In progress

- **In progress** — [Cross-window tab dragging and tear-out](docs/architecture/cross-window-tab-dragging-plan.md):
  native tab-control capture, cross-HWND and mixed-DPI target discovery, indexed
  transfer through the existing command-driven transaction, cancellation and
  rollback, and new-window tear-out placement. Implementation and automated
  coverage are complete; the required real-monitor/accessibility QA remains.

## Needs planning

### Windows, tabs, and panes

- Pane splits: horizontal/vertical splits, focus movement, resizing, closing,
  and tab/pane ownership rules.
- Tab process or working-directory status.
- Owner-drawn tab affordances such as visible close buttons, pins, and activity
  indicators.

### Configuration and appearance

- A configuration system, including evaluation of embedded Lua versus a
  declarative format, diagnostics, reload behavior, API stability, and
  execution security.
- Profiles for shell, arguments, starting directory, environment, icon, theme,
  font, and initial tab/pane layout.
- Customizable Windows-appropriate hotkeys, conflict detection, and a way to
  send bound keys through to the terminal.
- A command palette backed by the hotkey action registry.
- Terminal and application-chrome themes with built-in light/dark themes.
- A better default primary terminal font. Nerd Font Private Use Area coverage
  and its licensing decision are complete through the bundled symbol fallback.
- Font zoom and reset behavior that remains correct across DPI changes.
- Configurable visual and audible bells, including background-tab attention.

### Terminal interaction

- OSC 8 hyperlinks with safe modifier-click opening and an untrusted-target
  confirmation policy.
- Full IME support, including pre-edit composition rendering and candidate-window
  positioning.
- Word/line selection, keyboard selection, and selection auto-scroll.
- Configurable double- and triple-click selection after configuration exists.
- Shell integration for current-directory tracking, command boundaries, command
  status, and smarter tab titles.
- Windows UI Automation accessibility and high-contrast behavior.

### Reliability, distribution, and performance

- User-facing diagnostics for invalid configuration, missing fonts, renderer
  fallback, and shell or ConPTY startup failures.
- Crash recovery and opt-in diagnostic bundle generation without automatic
  session restoration or terminal-content disclosure.
- Application icons, version metadata, release packaging, installer support,
  Scoop, and WinGet distribution.
- Broader performance and stress tests for large scrollback, rapid resizing,
  sustained output, many tabs/panes, device loss, and repeated session
  lifecycle; expand the existing live-output smoke threshold into defined
  resource/responsiveness limits and CI regression checks.
- Scroll-aware retained-renderer back-buffer updates, including damage tracking,
  copy-versus-redraw decisions, resize/DPI invalidation, and benchmarks.
