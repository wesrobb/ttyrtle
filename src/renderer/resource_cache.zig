const std = @import("std");

pub const FontKey = struct {
    dpi: u32,
    cell_width: u32,
    cell_height: u32,
    family_generation: u32 = 1,
    size_generation: u32 = 1,
    fallback_generation: u32 = 1,
    typography_generation: u32 = 1,
};

pub const FontState = struct {
    key: ?FontKey = null,

    pub fn matches(self: FontState, key: FontKey) bool {
        return self.key != null and std.meta.eql(self.key.?, key);
    }

    pub fn commit(self: *FontState, key: FontKey) void {
        self.key = key;
    }
};

pub fn KeySlots(comptime capacity: usize) type {
    if (capacity == 0) @compileError("a resource cache needs at least one slot");
    return struct {
        const Self = @This();

        keys: [capacity]u32 = undefined,
        count: usize = 0,
        next_eviction: usize = 0,

        pub const Insertion = struct {
            index: usize,
            occupied: bool,
        };

        pub fn find(self: *const Self, key: u32) ?usize {
            for (self.keys[0..self.count], 0..) |existing, index|
                if (existing == key) return index;
            return null;
        }

        pub fn insertion(self: *const Self) Insertion {
            if (self.count < capacity)
                return .{ .index = self.count, .occupied = false };
            return .{ .index = self.next_eviction, .occupied = true };
        }

        pub fn commit(self: *Self, insertion_value: Insertion, key: u32) void {
            self.keys[insertion_value.index] = key;
            if (!insertion_value.occupied) {
                self.count += 1;
            } else {
                self.next_eviction = (insertion_value.index + 1) % capacity;
            }
        }
    };
}

test "font state reuses a matching key and changes once for DPI" {
    var state: FontState = .{};
    const initial: FontKey = .{ .dpi = 96, .cell_width = 8, .cell_height = 16 };
    try std.testing.expect(!state.matches(initial));
    state.commit(initial);
    try std.testing.expect(state.matches(initial));

    const scaled: FontKey = .{ .dpi = 144, .cell_width = 12, .cell_height = 24 };
    try std.testing.expect(!state.matches(scaled));
    state.commit(scaled);
    try std.testing.expect(state.matches(scaled));
}

test "font state invalidates every shaping policy input" {
    const initial: FontKey = .{ .dpi = 96, .cell_width = 8, .cell_height = 16 };
    var state: FontState = .{};
    state.commit(initial);
    inline for (.{
        FontKey{ .dpi = 144, .cell_width = 8, .cell_height = 16 },
        FontKey{ .dpi = 96, .cell_width = 8, .cell_height = 16, .family_generation = 2 },
        FontKey{ .dpi = 96, .cell_width = 8, .cell_height = 16, .size_generation = 2 },
        FontKey{ .dpi = 96, .cell_width = 8, .cell_height = 16, .fallback_generation = 2 },
        FontKey{ .dpi = 96, .cell_width = 8, .cell_height = 16, .typography_generation = 2 },
    }) |changed| try std.testing.expect(!state.matches(changed));
}
test "key slots reuse hits and evict within their bound" {
    var slots: KeySlots(2) = .{};
    const first = slots.insertion();
    slots.commit(first, 0x010203);
    const second = slots.insertion();
    slots.commit(second, 0x040506);

    try std.testing.expectEqual(@as(?usize, 0), slots.find(0x010203));
    try std.testing.expectEqual(@as(?usize, 1), slots.find(0x040506));
    try std.testing.expectEqual(@as(usize, 2), slots.count);

    const replacement = slots.insertion();
    try std.testing.expect(replacement.occupied);
    slots.commit(replacement, 0x070809);
    try std.testing.expectEqual(@as(?usize, null), slots.find(0x010203));
    try std.testing.expectEqual(@as(?usize, 0), slots.find(0x070809));
    try std.testing.expectEqual(@as(usize, 2), slots.count);
}
