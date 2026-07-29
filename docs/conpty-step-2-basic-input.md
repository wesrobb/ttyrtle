# Step 2: Basic Keyboard Input

## Outcome

The ConPTY-hosted shell can be used interactively with Unicode text, editing
keys, navigation keys, and common control combinations. Input encoding follows
the terminal modes maintained by Ghostty rather than a fixed escape-sequence
table.

## Scope

- Add a focused `src/input.zig` translation layer.
- Translate Win32 keyboard messages into Ghostty input events.
- Use `ghostty.input.encodeKey` and options derived from the active terminal.
- Queue encoded bytes for a dedicated ConPTY input writer.
- Support Unicode text, including UTF-16 surrogate pairs.
- Support key press, repeat, and release information where the active protocol
  requires it.
- Preserve the output reader’s ability to drain while input is blocked.

Mouse input, paste, IME candidate UI, keybindings, and terminal-generated query
responses are not required here.

## Input pipeline

```text
WM_KEYDOWN / WM_KEYUP / WM_CHAR
                |
                v
Win32 key and text normalization
                |
                v
ghostty.input.KeyEvent
                |
                v
ghostty.input.encodeKey
                |
                v
Owned input queue
                |
                v
Writer thread -> WriteFile -> ConPTY
```

The UI thread creates and encodes events because the encoder depends on current
Ghostty terminal modes. It then copies the resulting bytes into the input
queue. The writer thread is the only thread that calls blocking `WriteFile`.

## Win32 translation

Track enough state to combine the split Win32 message streams:

- Physical key identity from virtual keys and scan codes.
- Press, repeat, and release action.
- Shift, Ctrl, and Alt modifier state.
- Layout-dependent text from character messages.
- UTF-16 high and low surrogates.
- Dead-key or composing state where Win32 exposes it.

Avoid sending the same printable key once from `WM_KEYDOWN` and again from
`WM_CHAR`. Define and test a clear ownership rule: key messages provide
physical/special-key events, while character messages provide composed text
for printable input.

The minimum supported key set is:

- Printable Unicode text.
- Enter, Tab, Backspace, and Escape.
- Arrow keys, Home, End, Page Up, Page Down, Insert, and Delete.
- Function keys F1 through F12.
- Ctrl+C, Ctrl+D, Ctrl+Z, Ctrl+L, and similar letter combinations.
- Alt-modified printable keys.
- Key repeat.

## Mode-aware encoding

Construct `ghostty.input.KeyEncodeOptions` from `model.core` for every event or
whenever relevant terminal modes change. This allows Ghostty to account for:

- Normal versus application cursor keys.
- Normal versus application keypad.
- Backarrow mode.
- Alt escape-prefix behavior.
- Modified-key modes.
- Kitty keyboard protocol flags.

Do not maintain an independent copy of these modes in the Win32 layer.

## Writer behavior

The input queue must preserve byte ordering across keyboard events. The writer
must handle partial writes even if they are uncommon for a pipe. A write error
must transition the session into a closed/error state and notify the UI rather
than blocking shutdown.

Do not paint typed characters locally. Echo, password hiding, command-line
editing, and cursor movement are controlled by the hosted application and will
arrive through the output pipe.

## Tasks

- [x] Add `src/input.zig`.
- [x] Define a testable Win32-independent normalized key representation.
- [x] Map required virtual keys and scan codes to Ghostty physical keys.
- [x] Track modifier, repeat, and release state.
- [x] Convert composed UTF-16 text to UTF-8 without losing surrogate pairs.
- [x] Prevent duplicate delivery between key and character messages.
- [x] Derive encoding options from the active Ghostty terminal.
- [x] Encode input with `ghostty.input.encodeKey`.
- [x] Add an owned, synchronized ConPTY input queue.
- [x] Add a dedicated blocking writer thread.
- [x] Handle partial writes, broken pipes, and child exit.
- [x] Add unit tests for printable, Unicode, navigation, modifier, and
      application-cursor-mode cases.
- [x] Add an integration test that sends input to a finite child and verifies
      its output.

## Verification

Run:

```powershell
zig fmt build.zig src test
zig build test
zig build test-integration
zig build smoke
zig build verify
```

Manually confirm in both `cmd.exe` and PowerShell where available:

- ASCII and non-ASCII text can be entered.
- Backspace and command-line editing behave normally.
- Arrow-key history navigation works.
- Home, End, Delete, and function keys do not print literal garbage.
- Ctrl+C interrupts a running command.
- Alt-modified input does not freeze the UI.
- Holding a key produces controlled repeats.

## Exit criteria

- [x] The shell is usable for ordinary command entry and editing.
- [x] Unicode text reaches the child as UTF-8.
- [x] Special-key sequences follow Ghostty’s current terminal modes.
- [x] Input never blocks the UI or output reader.
- [x] Input is not locally echoed by the renderer.
- [x] Automated verification passes.
