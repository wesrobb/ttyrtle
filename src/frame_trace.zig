const builtin = @import("builtin");
const win32 = @import("win32");

const foundation = win32.foundation;
const kernel32 = win32.kernel32;

pub const enabled = builtin.mode == .Debug and !builtin.is_test;

pub const Stats = struct {
    samples: u64 = 0,
    total_ticks: i64 = 0,
    max_ticks: i64 = 0,

    pub fn averageTicks(self: Stats) i64 {
        if (self.samples == 0) return 0;
        return @divTrunc(self.total_ticks, @as(i64, @intCast(self.samples)));
    }
};

pub const Counter = struct {
    stats: if (enabled) Stats else void = if (enabled) .{} else {},

    pub fn recordSince(self: *Counter, start: i64) void {
        if (!enabled) return;
        const elapsed = @max(timestamp() - start, 0);
        self.stats.samples +|= 1;
        self.stats.total_ticks +|= elapsed;
        self.stats.max_ticks = @max(self.stats.max_ticks, elapsed);
    }

    pub fn snapshot(self: *const Counter) Stats {
        if (!enabled) return .{};
        return self.stats;
    }
};

pub fn timestamp() i64 {
    if (!enabled) return 0;
    var value: foundation.LARGE_INTEGER = undefined;
    if (kernel32.QueryPerformanceCounter(&value) == 0) return 0;
    return value.QuadPart;
}

pub fn ticksToMicroseconds(ticks: i64) i64 {
    if (!enabled or ticks <= 0) return 0;
    var frequency: foundation.LARGE_INTEGER = undefined;
    if (kernel32.QueryPerformanceFrequency(&frequency) == 0 or
        frequency.QuadPart <= 0)
        return 0;
    return @divTrunc(ticks * 1_000_000, frequency.QuadPart);
}
