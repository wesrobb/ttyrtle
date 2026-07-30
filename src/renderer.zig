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
    window: ?foundation.HWND = null,

    pub fn initialize(self: *Renderer, window: foundation.HWND) void {
        self.window = window;
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
        self.window = null;
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
            self.recreateGpu(width, height, dpi);
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
        if (self.gpu) |*resources| {
            resources.paint(cache, damage, metrics, dpi) catch |err| {
                std.log.warn("GPU paint failed: {s}", .{@errorName(err)});
                const width: u32 = @intCast(@max(
                    client_rect.right - client_rect.left,
                    0,
                ));
                const height: u32 = @intCast(@max(
                    client_rect.bottom - client_rect.top,
                    0,
                ));
                self.recreateGpu(width, height, dpi);
                if (self.gpu) |*replacement| {
                    replacement.paint(
                        cache,
                        .full,
                        metrics,
                        dpi,
                    ) catch |retry_err| {
                        std.log.warn("GPU recovery paint failed: {s}", .{
                            @errorName(retry_err),
                        });
                        replacement.deinit();
                        self.gpu = null;
                    };
                    if (self.gpu != null) return true;
                }
            };
            if (self.gpu != null) return true;
        }

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

    fn recreateGpu(
        self: *Renderer,
        width: u32,
        height: u32,
        dpi: u32,
    ) void {
        if (self.gpu) |*resources| resources.deinit();
        self.gpu = null;
        const window = self.window orelse return;
        var replacement = d2d.DeviceResources.create(window) catch |err| {
            std.log.warn("GPU device recreation failed: {s}", .{
                @errorName(err),
            });
            return;
        };
        _ = replacement.resizeTarget(width, height, dpi) catch |err| {
            std.log.warn("GPU target recovery failed: {s}", .{
                @errorName(err),
            });
            replacement.deinit();
            return;
        };
        self.gpu = replacement;
    }
};
