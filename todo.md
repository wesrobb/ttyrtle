# TODO

## High priority

- [ ] Add performance and stress tests covering large scrollback histories,
  rapid resize, sustained high-output commands, many tabs and panes, device
  loss, and repeated session creation and teardown. Define useful resource and
  responsiveness limits and detect regressions in CI where practical.

## Architecture

- [ ] Refactor the single-session application into a multi-session workspace
  model with clear ownership between windows, tabs, pane layout trees, and
  terminal sessions.
  - [x] Introduce stable tab/session IDs and explicit workspace, tab, pane-root,
    terminal-model, and ConPTY ownership while retaining one window and one tab.
  - [x] Add a native Win32 tab control synchronized from stable workspace tab
    identities and reserve its strip within the terminal's existing top margin.
- [ ] Support multiple top-level windows and moving tabs between windows,
  preserving their pane layouts and running terminal sessions.

## User-facing features

- [ ] Add tabs following the [tab architecture](docs/architecture/tabs.md):
  support creating, closing, switching, reordering, and naming tabs, with each
  tab owning its pane layout and displaying useful process or
  working-directory status.
- [ ] Add panes: support horizontal and vertical splits, focus movement,
  resizing, closing, and a clear ownership model for the terminal sessions in
  each pane. Define how pane layouts interact with tabs.
- [ ] Add a configuration system for startup and runtime settings. Evaluate an
  embedded Lua configuration against a simpler declarative format, including
  startup cost, diagnostics, reload behavior, API stability, and the security
  implications of executing user code.
- [ ] After the configuration system is established, add profiles for shell,
  arguments, starting directory, environment variables, icon, theme, font, and
  initial tab or pane layout.
- [ ] Add customizable hotkeys with sane Windows-specific defaults. Cover tab
  and pane management, clipboard operations, font sizing, command dispatch,
  conflict detection, and an escape mechanism for sending bound keys through
  to the terminal.
- [ ] Add a command palette backed by the same action registry as hotkeys so
  terminal, tab, pane, and window commands remain discoverable.
- [ ] Add theme support for terminal palettes and application chrome. Ship a
  small set of built-in light and dark themes and allow configuration to
  override individual colors.
- [ ] Choose a better default terminal font with Nerd Font glyph coverage.
  Confirm redistribution licensing and bundle the selected font if practical;
  retain DirectWrite fallback and allow users to configure the family, size,
  weight, and style.
- [ ] Add font zoom and reset actions with correct sizing when windows move
  between monitors with different DPI settings.
- [ ] Add configurable visual and audible bell behavior after the configuration
  system is established, including taskbar attention for background tabs.

## Terminal interaction

- [ ] Add scrollback history with configurable limits, keyboard and mouse
  navigation, and selection that can extend beyond the visible viewport.
- [ ] Add OSC 8 hyperlinks with safe modifier-click opening and an appropriate
  confirmation policy for untrusted targets.
- [ ] Complete IME support with pre-edit composition rendering and correctly
  positioned candidate windows.
- [ ] Add word and line selection, keyboard-driven selection, and selection
  auto-scroll beyond the viewport.
- [ ] After the configuration system is established, make double- and
  triple-click selection behavior customizable.
- [ ] Add shell integration for current-directory tracking, command boundaries,
  command status, and smarter tab titles.
- [ ] Add accessibility support through Windows UI Automation, including screen
  reader access and Windows high-contrast behavior.

## Reliability and distribution

- [ ] Add clear user-facing diagnostics for invalid configuration, missing
  fonts, renderer fallback, and shell or ConPTY startup failures.
- [ ] Add crash recovery and diagnostic bundle generation. On the next launch,
  offer recovery and diagnostic submission/export only with explicit manual
  approval; never restore sessions or send diagnostics automatically, and
  exclude terminal contents by default.
- [ ] Add application icons, version metadata, release packaging, and installer
  support, including Scoop and WinGet package distribution.

## Rendering performance

- [ ] Add scroll-aware back-buffer updates after the retained Direct2D renderer
  is established: detect terminal scroll damage, shift reusable rendered pixels
  within the affected region, and redraw only newly exposed rows. Handle
  multiple scroll operations in one terminal batch, partial scroll regions,
  cursor and selection overlays, resize/DPI invalidation, and cases where a
  dirty-row redraw is cheaper than copying. Benchmark the result before making
  it the default path.
