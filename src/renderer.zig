const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const frame_trace = @import("frame_trace.zig");
const geometry = @import("geometry.zig");
const render_commands = @import("render_commands.zig");
const terminal = @import("terminal.zig");

const d2d = @import("renderer/d2d.zig");
const gdi = @import("renderer/gdi.zig");

const foundation = win32.foundation;
const graphics_gdi = win32.graphics.gdi;
const counters_enabled = builtin.mode == .Debug or builtin.is_test;

pub const Renderer = struct {
    fallback: gdi.Renderer = .{},
    gpu: ?d2d.DeviceResources = null,
    window: ?foundation.HWND = null,
    frame_request_count: if (counters_enabled) u64 else void = if (counters_enabled) 0 else {},
    frame_presented_count: if (counters_enabled) u64 else void = if (counters_enabled) 0 else {},
    gpu_present_count: if (counters_enabled) u64 else void = if (counters_enabled) 0 else {},
    gpu_recreation_count: if (counters_enabled) u64 else void = if (counters_enabled) 0 else {},
    retired_layout_build_count: if (counters_enabled) u64 else void = if (counters_enabled) 0 else {},

    pub const Diagnostics = struct {
        frames_requested: u64,
        frames_presented: u64,
        gpu_present_count: u64,
        gpu_recreation_count: u64,
        surface_resize_count: u64,
        scene_recreation_count: u64,
        scene_redraw_count: u64,
        layout_build_count: u64,
        layout_pool_hits: u64,
        layout_pool_evictions: u64,
        target_width: u32,
        target_height: u32,
        gpu_paint_trace: frame_trace.Stats,
        scene_trace: frame_trace.Stats,
        layout_trace: frame_trace.Stats,
        copy_trace: frame_trace.Stats,
        present_trace: frame_trace.Stats,
        surface_resize_trace: frame_trace.Stats,
    };

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
        self.releaseGpu();
        self.window = null;
        self.fallback.deinit();
    }

    pub fn metricsForDpi(self: *Renderer, dpi: u32) geometry.Metrics {
        const resources = &(self.gpu orelse return .forDpi(dpi));
        return resources.metricsForDpi(dpi) catch |err| {
            std.log.warn("DirectWrite font metrics unavailable: {s}", .{
                @errorName(err),
            });
            return .forDpi(dpi);
        };
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
                        if (counters_enabled) self.retired_layout_build_count +|=
                            replacement.layout_build_count;
                        replacement.deinit();
                        self.gpu = null;
                    };
                    if (self.gpu != null) {
                        if (counters_enabled) {
                            self.gpu_present_count +|= 1;
                            self.frame_presented_count +|= 1;
                        }
                        return true;
                    }
                }
            };
            if (self.gpu != null) {
                if (counters_enabled) {
                    self.gpu_present_count +|= 1;
                    self.frame_presented_count +|= 1;
                }
                return true;
            }
        }

        const presented = self.fallback.paint(
            window_dc,
            paint_rect,
            client_rect,
            cache,
            damage,
            metrics,
            dpi,
        );
        if (counters_enabled and presented) self.frame_presented_count +|= 1;
        return presented;
    }

    pub fn requestFrame(self: *Renderer) void {
        if (counters_enabled) self.frame_request_count +|= 1;
    }

    pub fn invalidateTerminalContent(self: *Renderer) void {
        if (self.gpu) |*resources| resources.invalidateTerminalContent();
    }

    pub fn diagnostics(self: *const Renderer) Diagnostics {
        if (!counters_enabled) return .{
            .frames_requested = 0,
            .frames_presented = 0,
            .gpu_present_count = 0,
            .gpu_recreation_count = 0,
            .surface_resize_count = 0,
            .scene_recreation_count = 0,
            .scene_redraw_count = 0,
            .layout_build_count = 0,
            .layout_pool_hits = 0,
            .layout_pool_evictions = 0,
            .target_width = 0,
            .target_height = 0,
            .gpu_paint_trace = .{},
            .scene_trace = .{},
            .layout_trace = .{},
            .copy_trace = .{},
            .present_trace = .{},
            .surface_resize_trace = .{},
        };
        const gpu_traces = if (self.gpu) |*resources| .{
            resources.paint_trace.snapshot(),
            resources.scene_trace.snapshot(),
            resources.layout_trace.snapshot(),
            resources.copy_trace.snapshot(),
            resources.present_trace.snapshot(),
            resources.surface_resize_trace.snapshot(),
        } else .{
            frame_trace.Stats{},
            frame_trace.Stats{},
            frame_trace.Stats{},
            frame_trace.Stats{},
            frame_trace.Stats{},
            frame_trace.Stats{},
        };
        return .{
            .frames_requested = self.frame_request_count,
            .frames_presented = self.frame_presented_count,
            .gpu_present_count = self.gpu_present_count,
            .gpu_recreation_count = self.gpu_recreation_count,
            .surface_resize_count = if (self.gpu) |resources| resources.surface_resize_count else 0,
            .scene_recreation_count = if (self.gpu) |resources| resources.scene_recreation_count else 0,
            .scene_redraw_count = if (self.gpu) |resources| resources.scene_redraw_count else 0,
            .layout_build_count = self.retired_layout_build_count +
                if (self.gpu) |resources| resources.layout_build_count else 0,
            .layout_pool_hits = if (self.gpu) |resources| resources.layout_pool_hit_count else 0,
            .layout_pool_evictions = if (self.gpu) |resources| resources.layout_pool_evict_count else 0,
            .target_width = if (self.gpu) |resources| resources.target_width else 0,
            .target_height = if (self.gpu) |resources| resources.target_height else 0,
            .gpu_paint_trace = gpu_traces[0],
            .scene_trace = gpu_traces[1],
            .layout_trace = gpu_traces[2],
            .copy_trace = gpu_traces[3],
            .present_trace = gpu_traces[4],
            .surface_resize_trace = gpu_traces[5],
        };
    }

    pub fn layoutGenerationForTesting(self: *const Renderer, row: usize) ?u64 {
        const resources = &(self.gpu orelse return null);
        if (row >= resources.row_layouts.items.len) return null;
        return resources.row_layouts.items[row].row_generation;
    }
    pub fn invalidateGpuSceneForTesting(self: *Renderer) bool {
        const resources = &(self.gpu orelse return false);
        resources.invalidateSceneForTesting();
        return true;
    }

    pub fn simulateDeviceLossForTesting(self: *Renderer) bool {
        const resources = &(self.gpu orelse return false);
        resources.simulateDeviceLossForTesting();
        return true;
    }

    fn recreateGpu(
        self: *Renderer,
        width: u32,
        height: u32,
        dpi: u32,
    ) void {
        self.releaseGpu();
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
        if (counters_enabled) self.gpu_recreation_count +|= 1;
    }

    fn releaseGpu(self: *Renderer) void {
        if (self.gpu) |*resources| {
            if (counters_enabled) self.retired_layout_build_count +|= resources.layout_build_count;
            resources.deinit();
        }
        self.gpu = null;
    }
};
