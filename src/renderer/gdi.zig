const std = @import("std");
const win32 = @import("win32");
const geometry = @import("../geometry.zig");
const render_commands = @import("../render_commands.zig");
const terminal = @import("../terminal.zig");
const resource_cache = @import("resource_cache.zig");

const foundation = win32.foundation;
const gdi = win32.graphics.gdi;
const gdi32 = win32.gdi32;
const user32 = win32.user32;

const terminal_font_name = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
const max_brushes = 64;

const BackBuffer = struct {
    dc: gdi.CreatedHDC,
    bitmap: gdi.HBITMAP,
    previous_bitmap: gdi.HGDIOBJ,
    width: i32,
    height: i32,

    fn deinit(self: *BackBuffer) void {
        _ = gdi32.SelectObject(self.dc, self.previous_bitmap);
        _ = gdi32.DeleteObject(self.bitmap);
        _ = gdi32.DeleteDC(self.dc);
        self.* = undefined;
    }
};

const BrushEntry = struct {
    brush: gdi.HBRUSH,
};

pub const Renderer = struct {
    back_buffer: ?BackBuffer = null,
    font: ?gdi.HFONT = null,
    font_state: resource_cache.FontState = .{},
    brushes: [max_brushes]BrushEntry = undefined,
    brush_slots: resource_cache.KeySlots(max_brushes) = .{},

    pub fn deinit(self: *Renderer) void {
        if (self.back_buffer) |*buffer| buffer.deinit();
        self.back_buffer = null;
        if (self.font) |font| _ = gdi32.DeleteObject(font);
        self.font = null;
        self.font_state = .{};
        for (self.brushes[0..self.brush_slots.count]) |entry|
            _ = gdi32.DeleteObject(entry.brush);
        self.brush_slots = .{};
    }

    pub fn paint(
        self: *Renderer,
        window_dc: gdi.HDC,
        paint_rect: foundation.RECT,
        client_rect: foundation.RECT,
        cache: *const render_commands.RenderCache,
        damage: terminal.RenderDamage,
        metrics: geometry.Metrics,
        dpi: u32,
    ) bool {
        const buffer_result = self.ensureBackBuffer(
            window_dc,
            client_rect.right - client_rect.left,
            client_rect.bottom - client_rect.top,
        ) orelse return false;
        const target_dc = buffer_result.buffer.dc;
        const font = self.ensureFont(metrics, dpi) orelse return false;
        const previous_font = gdi32.SelectObject(target_dc, font) orelse return false;
        defer _ = gdi32.SelectObject(target_dc, previous_font);
        _ = gdi32.SetBkMode(target_dc, gdi.TRANSPARENT);

        if (buffer_result.created) {
            if (!self.drawRect(target_dc, client_rect, cache, metrics)) return false;
        } else switch (damage) {
            .none => {
                // WM_PAINT can also be an expose without terminal damage.
                if (!self.drawRect(target_dc, paint_rect, cache, metrics)) return false;
            },
            .full => if (!self.drawRect(target_dc, client_rect, cache, metrics))
                return false,
            .partial => |rows| for (rows) |row| {
                if (!self.drawRow(target_dc, cache, metrics, row)) return false;
            },
        }

        const width = paint_rect.right - paint_rect.left;
        const height = paint_rect.bottom - paint_rect.top;
        return gdi32.BitBlt(
            window_dc,
            paint_rect.left,
            paint_rect.top,
            width,
            height,
            target_dc,
            paint_rect.left,
            paint_rect.top,
            gdi.SRCCOPY,
        ) != 0;
    }

    fn drawRect(
        self: *Renderer,
        dc: gdi.HDC,
        rect: foundation.RECT,
        cache: *const render_commands.RenderCache,
        metrics: geometry.Metrics,
    ) bool {
        const saved_dc = gdi32.SaveDC(dc);
        if (saved_dc == 0) return false;
        defer _ = gdi32.RestoreDC(dc, saved_dc);
        _ = gdi32.IntersectClipRect(
            dc,
            rect.left,
            rect.top,
            rect.right,
            rect.bottom,
        );
        const background = self.getBrush(cache.background) orelse return false;
        _ = user32.FillRect(dc, &rect, background);

        const first_row = firstRow(rect, metrics);
        const last_row = lastRow(rect, metrics);
        if (first_row >= cache.rows.items.len) return true;
        for (first_row..@min(last_row +| 1, cache.rows.items.len)) |row|
            if (!self.drawCachedRow(dc, &cache.rows.items[row])) return false;
        return true;
    }

    fn drawRow(
        self: *Renderer,
        dc: gdi.HDC,
        cache: *const render_commands.RenderCache,
        metrics: geometry.Metrics,
        row_index: u16,
    ) bool {
        if (row_index >= cache.rows.items.len) return true;
        const top = @as(i32, @intCast(metrics.margin_y)) +
            @as(i32, @intCast(row_index)) * @as(i32, @intCast(metrics.cell_height));
        const bounds: foundation.RECT = .{
            .left = @intCast(metrics.margin_x),
            .top = top,
            .right = @as(i32, @intCast(metrics.margin_x)) +
                @as(i32, @intCast(cache.columns)) *
                    @as(i32, @intCast(metrics.cell_width)),
            .bottom = top + @as(i32, @intCast(metrics.cell_height)),
        };
        const background = self.getBrush(cache.background) orelse return false;
        _ = user32.FillRect(dc, &bounds, background);
        return self.drawCachedRow(dc, &cache.rows.items[row_index]);
    }

    fn drawCachedRow(
        self: *Renderer,
        dc: gdi.HDC,
        row: *const render_commands.CachedRow,
    ) bool {
        for (row.rectangles.items) |rectangle| {
            const brush = self.getBrush(rectangle.color) orelse return false;
            const bounds: foundation.RECT = .{
                .left = rectangle.left,
                .top = rectangle.top,
                .right = rectangle.right,
                .bottom = rectangle.bottom,
            };
            _ = if (rectangle.outline)
                user32.FrameRect(dc, &bounds, brush)
            else
                user32.FillRect(dc, &bounds, brush);
        }

        for (row.text_runs.items) |text_run| {
            _ = gdi32.SetTextColor(dc, toColorRef(text_run.color));
            if (gdi32.TextOutW(
                dc,
                text_run.x,
                text_run.y,
                @ptrCast(row.utf16.items[text_run.text_start..].ptr),
                @intCast(text_run.text_len),
            ) == 0) return false;
        }
        return true;
    }

    const BackBufferResult = struct {
        buffer: *BackBuffer,
        created: bool,
    };

    fn ensureBackBuffer(
        self: *Renderer,
        dc: gdi.HDC,
        width: i32,
        height: i32,
    ) ?BackBufferResult {
        if (width <= 0 or height <= 0) return null;
        if (self.back_buffer) |*buffer| {
            if (buffer.width >= width and buffer.height >= height)
                return .{ .buffer = buffer, .created = false };
            buffer.deinit();
            self.back_buffer = null;
        }

        const memory_dc = gdi32.CreateCompatibleDC(dc);
        if (@intFromPtr(memory_dc) == 0) return null;
        const bitmap = gdi32.CreateCompatibleBitmap(dc, width, height) orelse {
            _ = gdi32.DeleteDC(memory_dc);
            return null;
        };
        const previous_bitmap = gdi32.SelectObject(memory_dc, bitmap) orelse {
            _ = gdi32.DeleteObject(bitmap);
            _ = gdi32.DeleteDC(memory_dc);
            return null;
        };
        self.back_buffer = .{
            .dc = memory_dc,
            .bitmap = bitmap,
            .previous_bitmap = previous_bitmap,
            .width = width,
            .height = height,
        };
        return .{ .buffer = &self.back_buffer.?, .created = true };
    }

    fn ensureFont(
        self: *Renderer,
        metrics: geometry.Metrics,
        dpi: u32,
    ) ?gdi.HFONT {
        const key: resource_cache.FontKey = .{
            .dpi = dpi,
            .cell_width = metrics.cell_width,
            .cell_height = metrics.cell_height,
        };
        if (self.font != null and self.font_state.matches(key))
            return self.font.?;

        const replacement = gdi32.CreateFontW(
            @intCast(metrics.cell_height),
            @intCast(metrics.cell_width),
            0,
            0,
            @intFromEnum(gdi.FW_NORMAL),
            0,
            0,
            0,
            @intFromEnum(gdi.DEFAULT_CHARSET),
            @intFromEnum(gdi.OUT_DEFAULT_PRECIS),
            @as(u8, @bitCast(gdi.CLIP_DEFAULT_PRECIS)),
            @intFromEnum(gdi.CLEARTYPE_QUALITY),
            @intFromEnum(gdi.FIXED_PITCH) | @intFromEnum(gdi.FF_MODERN),
            terminal_font_name,
        ) orelse return null;
        if (self.font) |font| _ = gdi32.DeleteObject(font);
        self.font = replacement;
        self.font_state.commit(key);
        return replacement;
    }

    fn getBrush(self: *Renderer, color: terminal.Rgb) ?gdi.HBRUSH {
        const key = colorKey(color);
        if (self.brush_slots.find(key)) |index| return self.brushes[index].brush;

        const replacement = gdi32.CreateSolidBrush(toColorRef(color)) orelse
            return null;
        const insertion = self.brush_slots.insertion();
        if (insertion.occupied)
            _ = gdi32.DeleteObject(self.brushes[insertion.index].brush);
        self.brushes[insertion.index] = .{ .brush = replacement };
        self.brush_slots.commit(insertion, key);
        return replacement;
    }
};

fn firstRow(rect: foundation.RECT, metrics: geometry.Metrics) usize {
    const margin_y: i32 = @intCast(metrics.margin_y);
    const cell_height: i32 = @intCast(metrics.cell_height);
    return @intCast(@divTrunc(@max(rect.top - margin_y, 0), cell_height));
}

fn lastRow(rect: foundation.RECT, metrics: geometry.Metrics) usize {
    const margin_y: i32 = @intCast(metrics.margin_y);
    const cell_height: i32 = @intCast(metrics.cell_height);
    return @intCast(@divTrunc(@max(rect.bottom - 1 - margin_y, 0), cell_height));
}

fn toColorRef(color: terminal.Rgb) win32.zig.COLORREF {
    return .rgb(color.red, color.green, color.blue);
}

fn colorKey(color: terminal.Rgb) u32 {
    return @as(u32, color.red) << 16 |
        @as(u32, color.green) << 8 |
        color.blue;
}
