# Step 4: Terminal Completeness

## Outcome

The terminal handles common bidirectional VT behavior and desktop side effects,
not just output parsing and user keystrokes. Interactive applications can query
terminal capabilities and size, update the title, ring the bell, paste text,
and use the cursor and mouse behaviors required for practical terminal use.

This step makes the earlier transport suitable for applications beyond a
simple command prompt.

## Scope

- Replace Ghostty’s read-only convenience stream with a handler whose effects
  are connected to the application.
- Send Ghostty-generated terminal replies through the existing ConPTY input
  queue.
- Handle title and bell side effects.
- Render the active cursor and cell backgrounds.
- Add safe paste and bracketed-paste handling.
- Add basic selection and clipboard integration.
- Add focus and mouse reporting when requested by terminal modes.
- Complete practical IME/composition behavior.

Individual features should be independently testable and may be delivered in
small commits within this step.

## Ghostty effect wiring

The current `Terminal.vtStream()` convenience path intentionally ignores
queries and external side effects. Build the stream from `vtHandler()` and
populate only the effects the app actually supports.

The highest-priority callback is `write_pty`. It is used for responses such as:

- Primary, secondary, and tertiary device attributes.
- Device status and cursor position reports.
- Mode reports.
- Terminal size and pixel-size reports.
- Color and capability queries.

Callback data is borrowed for the duration of the call. Copy it into an owned
input-queue item before returning. Never call blocking `WriteFile` from inside
the parser callback.

Other effect callbacks can notify the window layer to:

- Change the window title.
- Ring or visually represent the bell.
- Answer size and color-scheme queries.
- Track the working directory.
- Handle desktop notification requests according to an explicit policy.
- Handle clipboard requests only with appropriate validation and user-safety
  constraints.

## Rendering completeness

Extend rendering based on Ghostty’s render state:

- Per-cell foreground and background colors.
- Cursor position, shape, visibility, and blink mode.
- Bold, faint, underline, inverse, and other supported attributes.
- Wide characters and spacer cells.
- Combining marks and grapheme clusters.
- Selection highlighting.
- Alternate-screen behavior.

Font shaping and a GPU renderer are still separate projects, but GDI rendering
must degrade predictably when it cannot represent a sequence perfectly.

## Paste and clipboard

Use Ghostty’s paste APIs to:

- Normalize or reject unsafe control content according to an explicit policy.
- Wrap paste in bracketed-paste markers when the active application requests
  that mode.
- Queue paste bytes through the same ordered ConPTY input writer.

Do not insert clipboard text directly into the terminal grid. OSC clipboard
reads and writes require a conservative security policy and must not silently
expose clipboard contents to an untrusted remote process.

## Focus, mouse, and IME

When the corresponding terminal modes are enabled:

- Encode focus-in and focus-out events.
- Convert mouse buttons, motion, and wheel events into Ghostty mouse events.
- Respect application mouse tracking without permanently taking away normal
  text selection; define a modifier override for local selection.
- Supply cell and pixel coordinates consistently with the resize geometry.
- Complete IME composition so committed text is delivered once and pre-edit
  text is represented without entering the terminal stream prematurely.

Use Ghostty’s exported focus, mouse, key, and paste encoders rather than
maintaining independent escape-sequence tables.

## Tasks

- [x] Construct a persistent Ghostty stream from a configurable handler.
- [x] Wire `write_pty` to an owned item in the ConPTY input queue.
- [x] Provide device attributes and size-query responses.
- [x] Handle terminal title changes on the UI thread.
- [x] Implement audible or visual bell behavior.
- [x] Render cell background colors and inverse video.
- [x] Render cursor position, shape, visibility, and blink state.
- [x] Improve wide-character and combining-mark rendering.
- [x] Add selection state and clipboard copy.
- [x] Add safe paste and bracketed paste.
- [x] Define a policy for OSC clipboard access.
- [x] Encode focus events when requested.
- [x] Encode mouse tracking events with correct coordinates.
- [x] Preserve a local-selection modifier while mouse tracking is active.
- [ ] Complete IME composition handling.
- [x] Add unit tests for generated replies, paste, focus, and mouse encoding.
- [ ] Add integration coverage using finite programs that issue terminal
      queries and validate the replies.
- [x] Update README with supported features and remaining limitations.

## Verification

Run:

```powershell
zig fmt build.zig src test
zig build test
zig build test-integration
zig build smoke
zig build verify
```

Manually exercise representative applications:

- Shell line editing and colored prompts.
- A full-screen editor such as Vim or Neovim.
- A pager such as `less`.
- An SSH session.
- Alternate-screen entry and exit.
- Cursor-shape changes.
- Bracketed paste.
- Mouse tracking and the local-selection override.
- Unicode, combining characters, and wide characters.
- Window title and bell requests.

## Exit criteria

- [x] Common terminal queries receive correct, non-blocking replies.
- [x] Title and bell effects reach the Win32 UI safely.
- [x] Cursor and cell backgrounds render from Ghostty state.
- [ ] Paste, focus, mouse, and IME paths respect active terminal modes.
- [x] Clipboard access follows a documented conservative policy.
- [ ] Full-screen terminal applications are practically usable.
- [x] README accurately records supported behavior and limitations.
- [x] Automated verification passes.
