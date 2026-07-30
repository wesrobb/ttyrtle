const std = @import("std");
const win32 = @import("win32");
const geometry = @import("geometry.zig");
const render_commands = @import("render_commands.zig");
const terminal = @import("terminal.zig");

const d2d = @import("renderer/d2d.zig");
const gdi = @import("renderer/gdi.zig");

const foundation = win32.foundation;
const graphics_gdi = win32.graphics.gdi;

pub const Renderer = struct {
    fallback: gdi.Renderer = .{},
    gpu: ?d2d.DeviceResources = null,

    pub fn initialize(self: *Renderer, window: foundation.HWND) void {
        self.gpu = d2d.DeviceResources.create(window) catch |err| {
            // The GDI renderer remains usable when Direct3D is unavailable.
            std.log.warn("GPU renderer initialization failed: {s}", .{
                @errorName(err),
            });
            return;
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.gpu) |*resources| resources.deinit();
        self.gpu = null;
        self.fallback.deinit();
    }

    pub fn resize(
        self: *Renderer,
        width: u32,
        height: u32,
        dpi: u32,
    ) bool {
        const resources = &(self.gpu orelse return false);
        return resources.resizeTarget(width, height, dpi) catch |err| {
            std.log.warn("GPU target recreation failed: {s}", .{
                @errorName(err),
            });
            resources.deinit();
            self.gpu = null;
            return true;
        };
    }

    pub fn paint(
        self: *Renderer,
        window_dc: graphics_gdi.HDC,
        paint_rect: foundation.RECT,
        client_rect: foundation.RECT,
        cache: *const render_commands.RenderCache,
        damage: terminal.RenderDamage,
        metrics: geometry.Metrics,
        dpi: u32,
    ) bool {
        return self.fallback.paint(
            window_dc,
            paint_rect,
            client_rect,
            cache,
            damage,
            metrics,
            dpi,
        );
    }
};
