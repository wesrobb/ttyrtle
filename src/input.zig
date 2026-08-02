const std = @import("std");
const ghostty = @import("ghostty-vt");

pub const Key = ghostty.input.Key;
pub const Action = ghostty.input.KeyAction;
pub const Mods = ghostty.input.KeyMods;
pub const FocusEvent = ghostty.input.FocusEvent;
pub const MouseAction = ghostty.input.MouseAction;
pub const MouseButton = ghostty.input.MouseButton;

pub const NormalizedKey = struct {
    key: Key,
    action: Action,
    mods: Mods = .{},
    repeat_count: u16 = 1,
    unshifted_codepoint: u21 = 0,
    utf8: []const u8 = "",
    composing: bool = false,

    fn ghosttyEvent(self: NormalizedKey) ghostty.input.KeyEvent {
        return .{
            .key = self.key,
            .action = self.action,
            .mods = self.mods,
            .unshifted_codepoint = self.unshifted_codepoint,
            .utf8 = self.utf8,
            .composing = self.composing,
        };
    }
};

pub const KeyDisposition = enum {
    /// Encode the key message itself (special keys and key releases).
    encode,
    /// Wait for the composed WM_CHAR/WM_SYSCHAR text.
    wait_for_text,
    /// Modifier state is carried on other events and needs no legacy output.
    modifier,
};

pub const Translator = struct {
    pending: ?NormalizedKey = null,
    pending_high_surrogate: ?u16 = null,
    suppress_character: bool = false,
    utf8_buffer: [4]u8 = undefined,

    pub fn keyEvent(
        self: *Translator,
        virtual_key: u16,
        scan_code: u8,
        action: Action,
        mods: Mods,
        extended: bool,
        repeat_count: u16,
    ) ?NormalizedKey {
        const key = keyFromWindows(virtual_key, scan_code, extended);
        const event: NormalizedKey = .{
            .key = key,
            .action = action,
            .mods = mods,
            .repeat_count = @max(repeat_count, 1),
            .unshifted_codepoint = unshiftedCodepoint(virtual_key),
        };

        if (isModifier(key)) return event;
        if (action == .release) return event;
        if (isTextKey(virtual_key)) {
            self.pending = event;
            return null;
        }

        self.suppress_character = key == .enter or key == .tab or
            key == .backspace or key == .escape;
        return event;
    }

    /// Converts one UTF-16 character message to a normalized event. A high
    /// surrogate is retained until its matching low surrogate arrives.
    pub fn characterEvent(
        self: *Translator,
        code_unit: u16,
        fallback_mods: Mods,
    ) ?NormalizedKey {
        if (self.suppress_character) {
            self.suppress_character = false;
            return null;
        }

        if (std.unicode.utf16IsHighSurrogate(code_unit)) {
            self.pending_high_surrogate = code_unit;
            return null;
        }

        const codepoint: u21 = if (std.unicode.utf16IsLowSurrogate(code_unit)) cp: {
            const high = self.pending_high_surrogate orelse return null;
            self.pending_high_surrogate = null;
            break :cp std.unicode.utf16DecodeSurrogatePair(&.{ high, code_unit }) catch
                return null;
        } else cp: {
            self.pending_high_surrogate = null;
            break :cp code_unit;
        };

        const length = std.unicode.utf8Encode(codepoint, &self.utf8_buffer) catch return null;
        var event = self.pending orelse NormalizedKey{
            .key = .unidentified,
            .action = .press,
            .mods = fallback_mods,
        };
        self.pending = null;
        event.utf8 = self.utf8_buffer[0..length];
        return event;
    }

    pub fn deadCharacter(self: *Translator) void {
        self.pending = null;
        self.pending_high_surrogate = null;
    }
};

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    event: NormalizedKey,
    terminal: *const ghostty.Terminal,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (0..event.repeat_count) |_|
        try ghostty.input.encodeKey(
            &output.writer,
            event.ghosttyEvent(),
            .fromTerminal(terminal),
        );
    return output.toOwnedSlice();
}

pub fn encodeFocusAlloc(
    allocator: std.mem.Allocator,
    event: ghostty.input.FocusEvent,
    terminal: *const ghostty.Terminal,
) ![]u8 {
    if (!terminal.modes.get(.focus_event)) return allocator.alloc(u8, 0);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try ghostty.input.encodeFocus(&output.writer, event);
    return output.toOwnedSlice();
}

/// Encodes clipboard text using Ghostty's paste rules. Multiline text is
/// rejected outside bracketed-paste mode so an ordinary shell cannot execute
/// pasted commands without an application explicitly opting into paste fences.
pub fn encodePasteAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    terminal: *const ghostty.Terminal,
) ![]u8 {
    const options = ghostty.input.PasteOptions.fromTerminal(terminal);
    if (!options.bracketed and !ghostty.input.isSafePaste(text))
        return error.UnsafePaste;

    const mutable = try allocator.dupe(u8, text);
    defer allocator.free(mutable);
    const slices = ghostty.input.encodePaste(mutable, options);
    const length = slices[0].len + slices[1].len + slices[2].len;
    const result = try allocator.alloc(u8, length);
    var offset: usize = 0;
    for (slices) |slice| {
        @memcpy(result[offset..][0..slice.len], slice);
        offset += slice.len;
    }
    return result;
}

pub fn encodeMouseAlloc(
    allocator: std.mem.Allocator,
    event: ghostty.input.MouseEncodeEvent,
    terminal: *const ghostty.Terminal,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
    margin_x: u32,
    margin_y: u32,
    any_button_pressed: bool,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var options = ghostty.input.MouseEncodeOptions.fromTerminal(terminal, .{
        .screen = .{ .width = screen_width, .height = screen_height },
        .cell = .{ .width = cell_width, .height = cell_height },
        .padding = .{
            .left = margin_x,
            .right = margin_x,
            .top = margin_y,
            .bottom = margin_y,
        },
    });
    options.any_button_pressed = any_button_pressed;
    try ghostty.input.encodeMouse(&output.writer, event, options);
    return output.toOwnedSlice();
}

/// Maps the hardware scan code to a layout-independent physical key, using
/// the virtual key for functional keys whose scan codes are ambiguous.
pub fn keyFromWindows(virtual_key: u16, scan_code: u8, extended: bool) Key {
    if (scanCodeKey(scan_code, extended)) |key| return key;
    if (virtual_key >= 0x70 and virtual_key <= 0x7b)
        return @enumFromInt(@intFromEnum(Key.f1) + virtual_key - 0x70);
    if (virtual_key >= 0x60 and virtual_key <= 0x69)
        return @enumFromInt(@intFromEnum(Key.numpad_0) + virtual_key - 0x60);

    return switch (virtual_key) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0d => if (extended) .numpad_enter else .enter,
        0x10 => if (scan_code == 0x36) .shift_right else .shift_left,
        0x11 => if (extended) .control_right else .control_left,
        0x12 => if (extended) .alt_right else .alt_left,
        0x1b => .escape,
        0x20 => .space,
        0x21 => if (extended) .page_up else .numpad_page_up,
        0x22 => if (extended) .page_down else .numpad_page_down,
        0x23 => if (extended) .end else .numpad_end,
        0x24 => if (extended) .home else .numpad_home,
        0x25 => if (extended) .arrow_left else .numpad_left,
        0x26 => if (extended) .arrow_up else .numpad_up,
        0x27 => if (extended) .arrow_right else .numpad_right,
        0x28 => if (extended) .arrow_down else .numpad_down,
        0x2d => if (extended) .insert else .numpad_insert,
        0x2e => if (extended) .delete else .numpad_delete,
        0x5b => .meta_left,
        0x5c => .meta_right,
        0x5d => .context_menu,
        0x6a => .numpad_multiply,
        0x6b => .numpad_add,
        0x6c => .numpad_separator,
        0x6d => .numpad_subtract,
        0x6e => .numpad_decimal,
        0x6f => .numpad_divide,
        0x90 => .num_lock,
        else => .unidentified,
    };
}

fn scanCodeKey(scan_code: u8, extended: bool) ?Key {
    if (extended) {
        return switch (scan_code) {
            0x1c => .numpad_enter,
            0x1d => .control_right,
            0x35 => .numpad_divide,
            0x38 => .alt_right,
            0x5b => .meta_left,
            0x5c => .meta_right,
            0x5d => .context_menu,
            else => null,
        };
    }

    return switch (scan_code) {
        0x02...0x0a => @enumFromInt(@intFromEnum(Key.digit_1) + scan_code - 0x02),
        0x0b => .digit_0,
        0x0c => .minus,
        0x0d => .equal,
        0x10 => .key_q,
        0x11 => .key_w,
        0x12 => .key_e,
        0x13 => .key_r,
        0x14 => .key_t,
        0x15 => .key_y,
        0x16 => .key_u,
        0x17 => .key_i,
        0x18 => .key_o,
        0x19 => .key_p,
        0x1a => .bracket_left,
        0x1b => .bracket_right,
        0x1d => .control_left,
        0x1e => .key_a,
        0x1f => .key_s,
        0x20 => .key_d,
        0x21 => .key_f,
        0x22 => .key_g,
        0x23 => .key_h,
        0x24 => .key_j,
        0x25 => .key_k,
        0x26 => .key_l,
        0x27 => .semicolon,
        0x28 => .quote,
        0x29 => .backquote,
        0x2a => .shift_left,
        0x2b => .backslash,
        0x2c => .key_z,
        0x2d => .key_x,
        0x2e => .key_c,
        0x2f => .key_v,
        0x30 => .key_b,
        0x31 => .key_n,
        0x32 => .key_m,
        0x33 => .comma,
        0x34 => .period,
        0x35 => .slash,
        0x36 => .shift_right,
        0x37 => .numpad_multiply,
        0x38 => .alt_left,
        0x39 => .space,
        0x56 => .intl_backslash,
        else => null,
    };
}

fn unshiftedCodepoint(virtual_key: u16) u21 {
    if (virtual_key >= 'A' and virtual_key <= 'Z')
        return @intCast(virtual_key + ('a' - 'A'));
    if (virtual_key >= '0' and virtual_key <= '9') return @intCast(virtual_key);
    if (virtual_key == 0x20) return ' ';
    return 0;
}

fn isTextKey(virtual_key: u16) bool {
    if (virtual_key >= 'A' and virtual_key <= 'Z') return true;
    if (virtual_key >= '0' and virtual_key <= '9') return true;
    // Space and layout-dependent OEM keys produce character messages.
    return virtual_key == 0x20 or
        (virtual_key >= 0x60 and virtual_key <= 0x6f) or
        (virtual_key >= 0xba and virtual_key <= 0xe2);
}

fn isModifier(key: Key) bool {
    return switch (key) {
        .shift_left,
        .shift_right,
        .control_left,
        .control_right,
        .alt_left,
        .alt_right,
        .meta_left,
        .meta_right,
        => true,
        else => false,
    };
}

test "virtual keys map to physical letters navigation and function keys" {
    try std.testing.expectEqual(Key.key_a, keyFromWindows('A', 0x1e, false));
    try std.testing.expectEqual(Key.key_z, keyFromWindows('Z', 0x2c, false));
    try std.testing.expectEqual(Key.arrow_left, keyFromWindows(0x25, 0x4b, true));
    try std.testing.expectEqual(Key.f12, keyFromWindows(0x7b, 0x58, false));
}

test "scan codes preserve physical identity across keyboard layouts" {
    try std.testing.expectEqual(Key.key_q, keyFromWindows('A', 0x10, false));
    try std.testing.expectEqual(Key.semicolon, keyFromWindows(0xba, 0x27, false));
    try std.testing.expectEqual(Key.shift_right, keyFromWindows(0x10, 0x36, false));
    try std.testing.expectEqual(Key.control_right, keyFromWindows(0x11, 0x1d, true));
}

test "extended flag distinguishes navigation and keypad keys" {
    try std.testing.expectEqual(Key.arrow_left, keyFromWindows(0x25, 0x4b, true));
    try std.testing.expectEqual(Key.numpad_left, keyFromWindows(0x25, 0x4b, false));
    try std.testing.expectEqual(Key.enter, keyFromWindows(0x0d, 0x1c, false));
    try std.testing.expectEqual(Key.numpad_enter, keyFromWindows(0x0d, 0x1c, true));
}

test "printable key waits for character message and is not duplicated" {
    var translator: Translator = .{};
    try std.testing.expect(translator.keyEvent('A', 0x1e, .press, .{}, false, 1) == null);
    const event = translator.characterEvent('a', .{}).?;
    try std.testing.expectEqual(Key.key_a, event.key);
    try std.testing.expectEqualStrings("a", event.utf8);
}

test "UTF-16 surrogate pairs become one UTF-8 input event" {
    var translator: Translator = .{};
    _ = translator.keyEvent('A', 0x1e, .press, .{}, false, 1);
    try std.testing.expect(translator.characterEvent(0xd83d, .{}) == null);
    const event = translator.characterEvent(0xde42, .{}).?;
    try std.testing.expectEqualStrings("🙂", event.utf8);
}

test "Ghostty encoding follows application cursor mode" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const event: NormalizedKey = .{ .key = .arrow_up, .action = .press };
    const normal = try encodeAlloc(std.testing.allocator, event, &terminal);
    defer std.testing.allocator.free(normal);
    try std.testing.expectEqualStrings("\x1b[A", normal);

    terminal.modes.set(.cursor_keys, true);
    const application = try encodeAlloc(std.testing.allocator, event, &terminal);
    defer std.testing.allocator.free(application);
    try std.testing.expectEqualStrings("\x1bOA", application);
}

test "F10 is encoded for the hosted terminal" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const encoded = try encodeAlloc(std.testing.allocator, .{
        .key = .f10,
        .action = .press,
    }, &terminal);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\x1b[21~", encoded);
}

test "control letter is encoded as a C0 byte" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const encoded = try encodeAlloc(std.testing.allocator, .{
        .key = .key_c,
        .action = .press,
        .mods = .{ .ctrl = true },
        .unshifted_codepoint = 'c',
        .utf8 = "c",
    }, &terminal);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{3}, encoded);
}

test "Unicode text is encoded as UTF-8 without loss" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const encoded = try encodeAlloc(std.testing.allocator, .{
        .key = .unidentified,
        .action = .press,
        .utf8 = "\xc3\xa9",
    }, &terminal);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\xc3\xa9", encoded);
}

test "repeat count emits one encoded sequence per Windows repeat" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const encoded = try encodeAlloc(std.testing.allocator, .{
        .key = .arrow_left,
        .action = .repeat,
        .repeat_count = 3,
    }, &terminal);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\x1b[D\x1b[D\x1b[D", encoded);
}

test "paste sanitizes controls and follows bracketed paste mode" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const plain = try encodePasteAlloc(
        std.testing.allocator,
        "hello\x03world",
        &terminal,
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("hello world", plain);
    try std.testing.expectError(
        error.UnsafePaste,
        encodePasteAlloc(std.testing.allocator, "one\ntwo", &terminal),
    );

    terminal.modes.set(.bracketed_paste, true);
    const bracketed = try encodePasteAlloc(
        std.testing.allocator,
        "one\ntwo",
        &terminal,
    );
    defer std.testing.allocator.free(bracketed);
    try std.testing.expectEqualStrings(
        "\x1b[200~one\ntwo\x1b[201~",
        bracketed,
    );
}

test "focus reports only when requested by terminal mode" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 2, .cols = 2 },
    );
    defer terminal.deinit(std.testing.allocator);

    const disabled = try encodeFocusAlloc(
        std.testing.allocator,
        .gained,
        &terminal,
    );
    defer std.testing.allocator.free(disabled);
    try std.testing.expectEqual(@as(usize, 0), disabled.len);

    terminal.modes.set(.focus_event, true);
    const enabled = try encodeFocusAlloc(
        std.testing.allocator,
        .lost,
        &terminal,
    );
    defer std.testing.allocator.free(enabled);
    try std.testing.expectEqualStrings("\x1b[O", enabled);
}

test "mouse encoding uses terminal modes and cell geometry" {
    var terminal: ghostty.Terminal = try .init(
        std.testing.io,
        std.testing.allocator,
        .{ .rows = 10, .cols = 10 },
    );
    defer terminal.deinit(std.testing.allocator);
    terminal.flags.mouse_event = .normal;
    terminal.flags.mouse_format = .sgr;

    const encoded = try encodeMouseAlloc(
        std.testing.allocator,
        .{
            .action = .press,
            .button = .left,
            .pos = .{ .x = 25, .y = 45 },
        },
        &terminal,
        100,
        200,
        10,
        20,
        5,
        5,
        true,
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\x1b[<0;3;3M", encoded);
}
