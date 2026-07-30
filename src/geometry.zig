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
    baseline: u32,
    ascent: u32,
    descent: u32,
    underline_top: u32,
    underline_thickness: u32,

    pub fn forDpi(dpi: u32) Metrics {
        const effective_dpi = if (dpi == 0) base_dpi else dpi;
        return .{
            .cell_width = scale(logical_cell_width, effective_dpi),
            .cell_height = scale(logical_cell_height, effective_dpi),
            .margin_x = scale(logical_margin_x, effective_dpi),
            .margin_y = scale(logical_margin_y, effective_dpi),
            .baseline = scale(12, effective_dpi),
            .ascent = scale(12, effective_dpi),
            .descent = scale(4, effective_dpi),
            .underline_top = scale(14, effective_dpi),
            .underline_thickness = scale(1, effective_dpi),
        };
    }

    /// Constructs pixel cell geometry from DirectWrite design-unit metrics.
    pub fn fromDirectWrite(
        dpi: u32,
        design_units_per_em: u16,
        advance_width: u32,
        font_ascent: u16,
        font_descent: u16,
        line_gap: i16,
        underline_position: i16,
        underline_thickness: u16,
    ) Metrics {
        const effective_dpi = @max(dpi, 1);
        const em_pixels = 16.0 * @as(f64, @floatFromInt(effective_dpi)) / base_dpi;
        const units = @as(f64, @floatFromInt(@max(design_units_per_em, 1)));
        const unit_scale = em_pixels / units;
        const ascent_pixels = roundPositive(@as(f64, @floatFromInt(font_ascent)) * unit_scale);
        const descent_pixels = roundPositive(@as(f64, @floatFromInt(font_descent)) * unit_scale);
        const gap_pixels: u32 = if (line_gap > 0)
            roundPositive(@as(f64, @floatFromInt(line_gap)) * unit_scale)
        else
            0;
        const thickness = roundPositive(
            @as(f64, @floatFromInt(underline_thickness)) * unit_scale,
        );
        const underline_offset: i32 = @intFromFloat(@round(
            @as(f64, @floatFromInt(underline_position)) * unit_scale,
        ));
        return .{
            .cell_width = roundPositive(@as(f64, @floatFromInt(advance_width)) * unit_scale),
            .cell_height = @max(1, ascent_pixels + descent_pixels + gap_pixels),
            .margin_x = scale(logical_margin_x, effective_dpi),
            .margin_y = scale(logical_margin_y, effective_dpi),
            .baseline = ascent_pixels,
            .ascent = ascent_pixels,
            .descent = descent_pixels,
            .underline_top = @intCast(@max(0, @as(i32, @intCast(ascent_pixels)) - underline_offset)),
            .underline_thickness = thickness,
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

fn roundPositive(value: f64) u32 {
    return @max(1, @as(u32, @intFromFloat(@round(value))));
}

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
            .baseline = 18,
            .ascent = 18,
            .descent = 6,
            .underline_top = 21,
            .underline_thickness = 2,
        },
        Metrics.forDpi(144),
    );
}

test "DirectWrite design metrics produce terminal pixel geometry" {
    try std.testing.expectEqual(
        Metrics.forDpi(96),
        Metrics.fromDirectWrite(96, 1000, 500, 750, 250, 0, -100, 50),
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
