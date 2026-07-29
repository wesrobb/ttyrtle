const std = @import("std");

pub const base_dpi: u32 = 96;
pub const logical_cell_width: u32 = 8;
pub const logical_cell_height: u32 = 16;
pub const logical_margin_x: u32 = 24;
pub const logical_margin_y: u32 = 24;

pub const Dimensions = struct {
    columns: u16,
    rows: u16,
};

pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    margin_x: u32,
    margin_y: u32,

    pub fn forDpi(dpi: u32) Metrics {
        const effective_dpi = if (dpi == 0) base_dpi else dpi;
        return .{
            .cell_width = scale(logical_cell_width, effective_dpi),
            .cell_height = scale(logical_cell_height, effective_dpi),
            .margin_x = scale(logical_margin_x, effective_dpi),
            .margin_y = scale(logical_margin_y, effective_dpi),
        };
    }

    /// A zero-sized client represents a minimized window and has no new
    /// terminal dimensions. Non-zero clients always produce at least 1x1,
    /// capped to the signed 16-bit range required by Win32 COORD.
    pub fn dimensions(self: Metrics, client_width: i32, client_height: i32) ?Dimensions {
        if (client_width <= 0 or client_height <= 0) return null;

        const width: u32 = @intCast(client_width);
        const height: u32 = @intCast(client_height);
        const horizontal_margins = self.margin_x * 2;
        const vertical_margins = self.margin_y * 2;
        const usable_width = width -| horizontal_margins;
        const usable_height = height -| vertical_margins;
        const coord_max: u32 = std.math.maxInt(i16);

        return .{
            .columns = @intCast(@min(coord_max, @max(1, usable_width / self.cell_width))),
            .rows = @intCast(@min(coord_max, @max(1, usable_height / self.cell_height))),
        };
    }
};

fn scale(logical_pixels: u32, dpi: u32) u32 {
    return @max(1, (logical_pixels * dpi + base_dpi / 2) / base_dpi);
}

test "pixel geometry scales with DPI" {
    try std.testing.expectEqual(
        Metrics{
            .cell_width = 12,
            .cell_height = 24,
            .margin_x = 36,
            .margin_y = 36,
        },
        Metrics.forDpi(144),
    );
}

test "client pixels convert to cells after margins" {
    const metrics = Metrics.forDpi(96);
    try std.testing.expectEqual(
        Dimensions{ .columns = 80, .rows = 24 },
        metrics.dimensions(688, 432).?,
    );
}

test "small clients clamp to one cell and minimized clients retain old size" {
    const metrics = Metrics.forDpi(96);
    try std.testing.expectEqual(
        Dimensions{ .columns = 1, .rows = 1 },
        metrics.dimensions(1, 1).?,
    );
    try std.testing.expectEqual(@as(?Dimensions, null), metrics.dimensions(0, 560));
    try std.testing.expectEqual(@as(?Dimensions, null), metrics.dimensions(900, 0));
}

test "cell dimensions fit Win32 COORD" {
    const metrics = Metrics.forDpi(96);
    try std.testing.expectEqual(
        Dimensions{
            .columns = std.math.maxInt(i16),
            .rows = std.math.maxInt(i16),
        },
        metrics.dimensions(std.math.maxInt(i32), std.math.maxInt(i32)).?,
    );
}
