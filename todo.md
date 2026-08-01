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

## Needs planning

### Windows, tabs, and panes

- Multiple top-level windows and moving running tabs between them while
  preserving pane layouts and sessions.
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
- A better default terminal font with Nerd Font glyph coverage and a licensing
  decision.
- Font zoom and reset behavior that remains correct across DPI changes.
- Configurable visual and audible bells, including background-tab attention.

### Terminal interaction

- Scrollback history with configurable limits, keyboard/mouse navigation, and
  selection beyond the visible viewport.
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
- Performance and stress tests for large scrollback, rapid resizing, sustained
  output, many tabs/panes, device loss, and repeated session lifecycle; define
  resource/responsiveness limits and CI regression checks.
- Scroll-aware retained-renderer back-buffer updates, including damage tracking,
  copy-versus-redraw decisions, resize/DPI invalidation, and benchmarks.
