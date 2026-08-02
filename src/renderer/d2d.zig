const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32");
const frame_trace = @import("../frame_trace.zig");
const geometry = @import("../geometry.zig");
const render_commands = @import("../render_commands.zig");
const terminal = @import("../terminal.zig");
const resource_cache = @import("resource_cache.zig");

const foundation = win32.foundation;
const d2d = win32.graphics.direct2d;
const d3d = win32.graphics.direct3d;
const d3d11 = win32.graphics.direct3d11;
const dwrite = win32.graphics.direct_write;
const dxgi = win32.graphics.dxgi;
const d2d_common = d2d.common;
const dxgi_common = dxgi.common;

const terminal_font_name = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
const nerd_font_name = std.unicode.utf8ToUtf16LeStringLiteral("Symbols Nerd Font Mono");
const nerd_font_relative_path = std.unicode.utf8ToUtf16LeStringLiteral(
    "\\assets\\fonts\\SymbolsNerdFontMono-Regular.ttf",
);
const locale_name = std.unicode.utf8ToUtf16LeStringLiteral("en-US");
const max_brushes = 64;
const max_orphan_layouts = 128;
const counters_enabled = builtin.mode == .Debug or builtin.is_test;

const BrushEntry = struct {
    brush: *d2d.ID2D1SolidColorBrush,
};

const RowLayouts = struct {
    row_generation: u64 = 0,
    font_generation: u64 = 0,
    content_fingerprint: u64 = 0,
    shape_fingerprint: u64 = 0,
    layout_width: u32 = 0,
    layout: ?*dwrite.IDWriteTextLayout = null,

    fn clear(self: *RowLayouts) void {
        if (self.layout) |layout| release(layout);
        self.layout = null;
        self.row_generation = 0;
        self.font_generation = 0;
        self.content_fingerprint = 0;
        self.shape_fingerprint = 0;
        self.layout_width = 0;
    }

    fn deinit(self: *RowLayouts) void {
        self.clear();
        self.* = undefined;
    }
};

pub const DeviceResources = struct {
    d3d_device: *d3d11.ID3D11Device,
    d3d_context: *d3d11.ID3D11DeviceContext,
    dxgi_device: *dxgi.IDXGIDevice,
    dxgi_factory: *dxgi.IDXGIFactory2,
    swap_chain: *dxgi.IDXGISwapChain1,
    d2d_factory: *d2d.ID2D1Factory1,
    d2d_device: *d2d.ID2D1Device,
    d2d_context: *d2d.ID2D1DeviceContext,
    dwrite_factory: *dwrite.IDWriteFactory,
    dwrite_factory2: *dwrite.IDWriteFactory2,
    font_fallback: *dwrite.IDWriteFontFallback,
    typography: *dwrite.IDWriteTypography,
    target_bitmap: ?*d2d.ID2D1Bitmap1,
    scene_bitmap: ?*d2d.ID2D1Bitmap1,
    target_width: u32,
    target_height: u32,
    target_dpi: u32,
    scene_width: u32,
    scene_height: u32,
    scene_dpi: u32,
    scene_capacity_width: u32,
    scene_capacity_height: u32,
    scene_valid: bool,
    text_format: ?*dwrite.IDWriteTextFormat,
    font_state: resource_cache.FontState,
    font_generation: u64,
    row_layouts: std.ArrayListUnmanaged(RowLayouts),
    /// Bounded ownership pool for layouts displaced by viewport/grid changes.
    /// Layouts are position independent; drawing effects are reapplied after a
    /// layout is exclusively taken from this pool.
    orphan_layouts: std.ArrayListUnmanaged(RowLayouts),
    layout_pool_hit_count: if (counters_enabled) u64 else void,
    layout_pool_evict_count: if (counters_enabled) u64 else void,
    layout_build_count: if (counters_enabled) u64 else void,
    paint_trace: frame_trace.Counter,
    scene_trace: frame_trace.Counter,
    layout_trace: frame_trace.Counter,
    copy_trace: frame_trace.Counter,
    present_trace: frame_trace.Counter,
    surface_resize_trace: frame_trace.Counter,
    surface_resize_count: if (counters_enabled) u64 else void,
    scene_recreation_count: if (counters_enabled) u64 else void,
    scene_redraw_count: if (counters_enabled) u64 else void,
    brushes: [max_brushes]BrushEntry,
    brush_slots: resource_cache.KeySlots(max_brushes),
    simulate_device_loss: bool,
    driver: Driver,

    pub const Driver = enum {
        hardware,
        warp,
    };

    pub fn create(window: foundation.HWND) !DeviceResources {
        var resources: DeviceResources = undefined;
        resources.target_bitmap = null;
        resources.scene_bitmap = null;
        resources.target_width = 0;
        resources.target_height = 0;
        resources.target_dpi = 0;
        resources.scene_width = 0;
        resources.scene_height = 0;
        resources.scene_dpi = 0;
        resources.scene_capacity_width = 0;
        resources.scene_capacity_height = 0;
        resources.scene_valid = false;
        resources.text_format = null;
        resources.font_state = .{};
        resources.font_generation = 0;
        resources.row_layouts = .empty;
        resources.orphan_layouts = .empty;
        resources.layout_pool_hit_count = if (counters_enabled) 0 else {};
        resources.layout_pool_evict_count = if (counters_enabled) 0 else {};
        resources.layout_build_count = if (counters_enabled) 0 else {};
        resources.paint_trace = .{};
        resources.scene_trace = .{};
        resources.layout_trace = .{};
        resources.copy_trace = .{};
        resources.present_trace = .{};
        resources.surface_resize_trace = .{};
        resources.surface_resize_count = if (counters_enabled) 0 else {};
        resources.scene_recreation_count = if (counters_enabled) 0 else {};
        resources.scene_redraw_count = if (counters_enabled) 0 else {};
        resources.brush_slots = .{};
        resources.simulate_device_loss = false;

        resources.driver = .hardware;
        var result = win32.d3d11.D3D11CreateDevice(
            null,
            d3d.D3D_DRIVER_TYPE_HARDWARE,
            null,
            d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            d3d11.D3D11_SDK_VERSION,
            &resources.d3d_device,
            null,
            &resources.d3d_context,
        );
        if (result.failed) {
            resources.driver = .warp;
            result = win32.d3d11.D3D11CreateDevice(
                null,
                d3d.D3D_DRIVER_TYPE_WARP,
                null,
                d3d11.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                null,
                0,
                d3d11.D3D11_SDK_VERSION,
                &resources.d3d_device,
                null,
                &resources.d3d_context,
            );
            if (result.failed) return error.CreateD3DDeviceFailed;
        }
        errdefer release(resources.d3d_context);
        errdefer release(resources.d3d_device);

        resources.dxgi_device = try queryInterface(
            dxgi.IDXGIDevice,
            resources.d3d_device,
            dxgi.IID_IDXGIDevice,
        );
        errdefer release(resources.dxgi_device);
        try setMaximumFrameLatency(resources.dxgi_device);

        var adapter: *dxgi.IDXGIAdapter = undefined;
        if (resources.dxgi_device.GetAdapter(&adapter).failed)
            return error.GetDxgiAdapterFailed;
        defer release(adapter);

        resources.dxgi_factory = try getParent(
            dxgi.IDXGIFactory2,
            adapter,
            dxgi.IID_IDXGIFactory2,
        );
        errdefer release(resources.dxgi_factory);

        const swap_chain_description: dxgi.DXGI_SWAP_CHAIN_DESC1 = .{
            .Width = 0,
            .Height = 0,
            .Format = dxgi_common.DXGI_FORMAT_B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = dxgi.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = dxgi.DXGI_SCALING_STRETCH,
            .SwapEffect = dxgi.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            .AlphaMode = dxgi_common.DXGI_ALPHA_MODE_IGNORE,
            .Flags = 0,
        };
        if (resources.dxgi_factory.CreateSwapChainForHwnd(
            @ptrCast(resources.d3d_device),
            window,
            &swap_chain_description,
            null,
            null,
            &resources.swap_chain,
        ).failed) return error.CreateSwapChainFailed;
        errdefer release(resources.swap_chain);

        const factory_options: d2d.D2D1_FACTORY_OPTIONS = .{
            .debugLevel = d2d.D2D1_DEBUG_LEVEL_NONE,
        };
        var factory_raw: *anyopaque = undefined;
        if (win32.d2d1.D2D1CreateFactory(
            d2d.D2D1_FACTORY_TYPE_SINGLE_THREADED,
            d2d.IID_ID2D1Factory1,
            &factory_options,
            &factory_raw,
        ).failed) return error.CreateD2DFactoryFailed;
        resources.d2d_factory = @ptrCast(@alignCast(factory_raw));
        errdefer release(resources.d2d_factory);

        if (resources.d2d_factory.CreateDevice(
            resources.dxgi_device,
            &resources.d2d_device,
        ).failed) return error.CreateD2DDeviceFailed;
        errdefer release(resources.d2d_device);

        if (resources.d2d_device.CreateDeviceContext(
            d2d.D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
            &resources.d2d_context,
        ).failed) return error.CreateD2DContextFailed;
        errdefer release(resources.d2d_context);

        var dwrite_raw: *anyopaque = undefined;
        if (win32.dwrite.DWriteCreateFactory(
            dwrite.DWRITE_FACTORY_TYPE_SHARED,
            dwrite.IID_IDWriteFactory,
            &dwrite_raw,
        ).failed) return error.CreateDWriteFactoryFailed;
        resources.dwrite_factory = @ptrCast(@alignCast(dwrite_raw));
        errdefer release(resources.dwrite_factory);
        resources.dwrite_factory2 = try queryInterface(
            dwrite.IDWriteFactory2,
            resources.dwrite_factory,
            dwrite.IID_IDWriteFactory2,
        );
        errdefer release(resources.dwrite_factory2);
        resources.font_fallback = try createFontFallback(
            resources.dwrite_factory,
            resources.dwrite_factory2,
        );
        errdefer release(resources.font_fallback);
        if (resources.dwrite_factory.CreateTypography(
            &resources.typography,
        ).failed) return error.CreateTypographyFailed;
        errdefer release(resources.typography);
        for ([_]dwrite.DWRITE_FONT_FEATURE_TAG{
            .STANDARD_LIGATURES,
            .CONTEXTUAL_LIGATURES,
            .DISCRETIONARY_LIGATURES,
            .HISTORICAL_LIGATURES,
        }) |tag| {
            if (resources.typography.AddFontFeature(.{
                .nameTag = tag,
                .parameter = 0,
            }).failed) return error.ConfigureTypographyFailed;
        }

        return resources;
    }

    pub fn resizeTarget(
        self: *DeviceResources,
        width: u32,
        height: u32,
        dpi: u32,
    ) !bool {
        if (width == 0 or height == 0) return false;
        if (self.target_bitmap != null and
            self.target_width == width and
            self.target_height == height and
            self.target_dpi == dpi)
            return false;

        const trace_start = frame_trace.timestamp();
        defer self.surface_resize_trace.recordSince(trace_start);
        const size_changed = self.target_width != width or
            self.target_height != height;
        self.releaseSwapChainTarget();
        if (size_changed and self.swap_chain.IDXGISwapChain.ResizeBuffers(
            0,
            width,
            height,
            dxgi_common.DXGI_FORMAT_UNKNOWN,
            0,
        ).failed) return error.ResizeSwapChainFailed;

        try self.createTargetBitmap(width, height, dpi);
        self.target_width = width;
        self.target_height = height;
        self.target_dpi = dpi;
        if (counters_enabled) self.surface_resize_count +|= 1;
        return true;
    }

    pub fn metricsForDpi(self: *DeviceResources, dpi: u32) !geometry.Metrics {
        var collection: *dwrite.IDWriteFontCollection = undefined;
        if (self.dwrite_factory.GetSystemFontCollection(
            &collection,
            0,
        ).failed) return error.GetSystemFontCollectionFailed;
        defer release(collection);
        var family_index: u32 = 0;
        var family_exists: i32 = 0;
        if (collection.FindFamilyName(
            terminal_font_name,
            &family_index,
            &family_exists,
        ).failed or family_exists == 0) return error.PrimaryFontUnavailable;
        var family: *dwrite.IDWriteFontFamily = undefined;
        if (collection.GetFontFamily(family_index, &family).failed)
            return error.GetFontFamilyFailed;
        defer release(family);
        var font: *dwrite.IDWriteFont = undefined;
        if (family.GetFirstMatchingFont(
            .NORMAL,
            .NORMAL,
            .NORMAL,
            &font,
        ).failed) return error.GetFontFailed;
        defer release(font);
        var face: *dwrite.IDWriteFontFace = undefined;
        if (font.CreateFontFace(&face).failed) return error.CreateFontFaceFailed;
        defer release(face);
        var font_metrics: dwrite.DWRITE_FONT_METRICS = undefined;
        face.GetMetrics(&font_metrics);
        const code_points = [_]u32{'0'};
        var glyph_indices: [1:0]u16 = undefined;
        if (face.GetGlyphIndices(&code_points, 1, &glyph_indices).failed)
            return error.GetGlyphIndicesFailed;
        var glyph_metrics: [1]dwrite.DWRITE_GLYPH_METRICS = undefined;
        if (face.GetDesignGlyphMetrics(
            &glyph_indices,
            1,
            &glyph_metrics,
            0,
        ).failed) return error.GetGlyphMetricsFailed;
        return .fromDirectWrite(
            dpi,
            font_metrics.designUnitsPerEm,
            glyph_metrics[0].advanceWidth,
            font_metrics.ascent,
            font_metrics.descent,
            font_metrics.lineGap,
            font_metrics.underlinePosition,
            font_metrics.underlineThickness,
        );
    }
    pub fn paint(
        self: *DeviceResources,
        cache: *const render_commands.RenderCache,
        damage: terminal.RenderDamage,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !void {
        const trace_start = frame_trace.timestamp();
        defer self.paint_trace.recordSince(trace_start);
        if (self.simulate_device_loss) {
            self.simulate_device_loss = false;
            return error.DeviceLost;
        }
        if (self.target_bitmap == null)
            return error.TargetUnavailable;

        _ = try self.ensureTextFormat(metrics, dpi);
        try self.resizeRowLayouts(cache.rows.items.len);
        self.rotateRowLayoutsUp(cache.scroll_up_rows);
        self.rotateRowLayoutsDown(cache.scroll_down_rows);
        try self.ensureSceneBitmap(cache, metrics, dpi);
        if (!self.scene_valid) {
            try self.drawScene(cache, .full, metrics, dpi);
        } else switch (damage) {
            .none => {},
            else => try self.drawScene(cache, damage, metrics, dpi),
        }
        try self.presentScene(cache.background);
    }

    pub fn deinit(self: *DeviceResources) void {
        self.releaseTargetResources();
        self.releaseRowLayouts();
        self.releaseBrushes();
        if (self.text_format) |format| release(format);
        self.text_format = null;
        release(self.typography);
        release(self.font_fallback);
        release(self.dwrite_factory2);
        release(self.dwrite_factory);
        release(self.d2d_context);
        release(self.d2d_device);
        release(self.d2d_factory);
        release(self.swap_chain);
        release(self.dxgi_factory);
        release(self.dxgi_device);
        release(self.d3d_context);
        release(self.d3d_device);
        self.* = undefined;
    }

    pub fn invalidateSceneForTesting(self: *DeviceResources) void {
        self.scene_valid = false;
    }

    /// Cached DirectWrite layouts are keyed by row generation. Generations are
    /// local to a terminal model, so a tab switch must discard them as well.
    pub fn invalidateTerminalContent(self: *DeviceResources) void {
        self.scene_valid = false;
        for (self.row_layouts.items) |*layouts| layouts.clear();
        self.clearOrphanLayouts();
    }

    pub fn simulateDeviceLossForTesting(self: *DeviceResources) void {
        self.simulate_device_loss = true;
    }

    fn createTargetBitmap(
        self: *DeviceResources,
        _: u32,
        _: u32,
        dpi: u32,
    ) !void {
        var surface_raw: *anyopaque = undefined;
        if (self.swap_chain.IDXGISwapChain.GetBuffer(
            0,
            dxgi.IID_IDXGISurface,
            &surface_raw,
        ).failed) return error.GetSwapChainBufferFailed;
        const surface: *dxgi.IDXGISurface = @ptrCast(@alignCast(surface_raw));
        defer release(surface);

        const pixels_per_inch: f32 = @floatFromInt(dpi);
        const pixel_format: d2d_common.D2D1_PIXEL_FORMAT = .{
            .format = dxgi_common.DXGI_FORMAT_B8G8R8A8_UNORM,
            .alphaMode = d2d_common.D2D1_ALPHA_MODE_IGNORE,
        };
        const target_properties: d2d.D2D1_BITMAP_PROPERTIES1 = .{
            .pixelFormat = pixel_format,
            .dpiX = pixels_per_inch,
            .dpiY = pixels_per_inch,
            .bitmapOptions = .{ .TARGET = 1, .CANNOT_DRAW = 1 },
            .colorContext = null,
        };
        var target: *d2d.ID2D1Bitmap1 = undefined;
        if (self.d2d_context.CreateBitmapFromDxgiSurface(
            surface,
            &target_properties,
            &target,
        ).failed) return error.CreateSwapChainBitmapFailed;
        self.target_bitmap = target;
    }

    fn ensureSceneBitmap(
        self: *DeviceResources,
        cache: *const render_commands.RenderCache,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !void {
        const width = metrics.margin_x + @as(u32, cache.columns) * metrics.cell_width;
        const height = metrics.margin_y + @as(u32, @intCast(cache.rows.items.len)) * metrics.cell_height;
        if (self.scene_bitmap != null and self.scene_dpi == dpi and
            self.scene_capacity_width >= width and self.scene_capacity_height >= height)
        {
            if (self.scene_width != width or self.scene_height != height)
                self.scene_valid = false;
            self.scene_width = width;
            self.scene_height = height;
            return;
        }

        if (self.scene_bitmap) |bitmap| release(bitmap);
        self.scene_bitmap = null;
        const pixels_per_inch: f32 = @floatFromInt(dpi);
        const properties: d2d.D2D1_BITMAP_PROPERTIES1 = .{
            .pixelFormat = .{
                .format = dxgi_common.DXGI_FORMAT_B8G8R8A8_UNORM,
                .alphaMode = d2d_common.D2D1_ALPHA_MODE_IGNORE,
            },
            .dpiX = pixels_per_inch,
            .dpiY = pixels_per_inch,
            .bitmapOptions = d2d.D2D1_BITMAP_OPTIONS_TARGET,
            .colorContext = null,
        };
        const capacity_width = growSceneCapacity(self.scene_capacity_width, width);
        const capacity_height = growSceneCapacity(self.scene_capacity_height, height);
        var scene: *d2d.ID2D1Bitmap1 = undefined;
        if (self.d2d_context.CreateBitmap(
            .{ .width = capacity_width, .height = capacity_height },
            null,
            0,
            &properties,
            &scene,
        ).failed) return error.CreateSceneBitmapFailed;
        self.scene_bitmap = scene;
        self.scene_width = width;
        self.scene_height = height;
        self.scene_dpi = dpi;
        self.scene_capacity_width = capacity_width;
        self.scene_capacity_height = capacity_height;
        self.scene_valid = false;
        if (counters_enabled) self.scene_recreation_count +|= 1;
    }

    fn drawScene(
        self: *DeviceResources,
        cache: *const render_commands.RenderCache,
        damage: terminal.RenderDamage,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !void {
        if (counters_enabled) self.scene_redraw_count +|= 1;
        const trace_start = frame_trace.timestamp();
        defer self.scene_trace.recordSince(trace_start);
        const scene = self.scene_bitmap orelse return error.TargetUnavailable;
        self.d2d_context.SetTarget(@ptrCast(scene));
        const target = &self.d2d_context.ID2D1RenderTarget;
        target.BeginDraw();
        var drawing = true;
        errdefer {
            if (drawing) _ = target.EndDraw(null, null);
        }

        switch (damage) {
            .none => {},
            .full => {
                const background = toColor(cache.background);
                target.Clear(&background);
                for (cache.rows.items, 0..) |*row, row_index|
                    try self.drawCachedRow(row_index, row, metrics, dpi);
            },
            .partial => |rows| for (rows) |row_index| {
                if (row_index >= cache.rows.items.len) continue;
                try self.clearRow(cache, metrics, dpi, row_index);
                try self.drawCachedRow(
                    row_index,
                    &cache.rows.items[row_index],
                    metrics,
                    dpi,
                );
            },
        }

        const result = target.EndDraw(null, null);
        drawing = false;
        try checkDrawResult(result);
        self.scene_valid = true;
    }

    fn clearRow(
        self: *DeviceResources,
        cache: *const render_commands.RenderCache,
        metrics: geometry.Metrics,
        dpi: u32,
        row_index: u16,
    ) !void {
        const scale = dipScale(dpi);
        const top_pixels = metrics.margin_y +
            @as(u32, row_index) * metrics.cell_height;
        const bounds: d2d_common.D2D_RECT_F = .{
            .left = @as(f32, @floatFromInt(metrics.margin_x)) * scale,
            .top = @as(f32, @floatFromInt(top_pixels)) * scale,
            .right = @as(f32, @floatFromInt(
                metrics.margin_x +
                    @as(u32, cache.columns) * metrics.cell_width,
            )) * scale,
            .bottom = @as(f32, @floatFromInt(
                top_pixels + metrics.cell_height,
            )) * scale,
        };
        const brush = try self.getBrush(cache.background);
        self.d2d_context.ID2D1RenderTarget.FillRectangle(
            &bounds,
            @ptrCast(brush),
        );
    }

    fn drawCachedRow(
        self: *DeviceResources,
        row_index: usize,
        row: *const render_commands.CachedRow,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !void {
        const target = &self.d2d_context.ID2D1RenderTarget;
        const scale = dipScale(dpi);
        for (row.rectangles.items) |rectangle| {
            const bounds: d2d_common.D2D_RECT_F = .{
                .left = @as(f32, @floatFromInt(rectangle.left)) * scale,
                .top = @as(f32, @floatFromInt(rectangle.top)) * scale,
                .right = @as(f32, @floatFromInt(rectangle.right)) * scale,
                .bottom = @as(f32, @floatFromInt(rectangle.bottom)) * scale,
            };
            const brush = try self.getBrush(rectangle.color);
            if (rectangle.outline) {
                target.DrawRectangle(
                    &bounds,
                    @ptrCast(brush),
                    scale,
                    null,
                );
            } else {
                target.FillRectangle(&bounds, @ptrCast(brush));
            }
        }

        const layouts = try self.ensureRowLayouts(row_index, row, metrics, dpi);
        const layout = layouts.layout orelse return;
        const default_brush = try self.getBrush(.{
            .red = 255,
            .green = 255,
            .blue = 255,
        });
        target.DrawTextLayout(
            .{
                .x = @as(f32, @floatFromInt(metrics.margin_x)) * scale,
                .y = @as(f32, @floatFromInt(
                    metrics.margin_y +
                        @as(u32, @intCast(row_index)) * metrics.cell_height,
                )) * scale,
            },
            layout,
            @ptrCast(default_brush),
            .{ .CLIP = 1, .ENABLE_COLOR_FONT = 1 },
        );
    }

    fn resizeRowLayouts(self: *DeviceResources, row_count: usize) !void {
        const old_length = self.row_layouts.items.len;
        if (row_count < old_length) {
            for (self.row_layouts.items[row_count..]) |*layouts| self.stashOrphan(layouts);
            self.row_layouts.shrinkRetainingCapacity(row_count);
        } else if (row_count > old_length) {
            try self.row_layouts.resize(std.heap.smp_allocator, row_count);
            for (self.row_layouts.items[old_length..]) |*layouts| layouts.* = .{};
        }
    }

    /// Keep DirectWrite layouts paired with the cached content when a terminal
    /// line scrolls off the top. The bottom row is rebuilt by the normal
    /// generation check in ensureRowLayouts.
    fn rotateRowLayoutsUp(self: *DeviceResources, count: u16) void {
        const rows = @min(@as(usize, count), self.row_layouts.items.len);
        for (0..rows) |_| {
            const moved = self.row_layouts.orderedRemove(0);
            self.row_layouts.appendAssumeCapacity(moved);
        }
    }

    /// Keep DirectWrite layouts paired with cached content when scrolling into
    /// history moves retained terminal lines toward the bottom.
    fn rotateRowLayoutsDown(self: *DeviceResources, count: u16) void {
        const rows = @min(@as(usize, count), self.row_layouts.items.len);
        for (0..rows) |_| {
            const moved = self.row_layouts.pop().?;
            self.row_layouts.insertAssumeCapacity(0, moved);
        }
    }

    fn ensureRowLayouts(
        self: *DeviceResources,
        row_index: usize,
        row: *const render_commands.CachedRow,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !*RowLayouts {
        const layouts = &self.row_layouts.items[row_index];
        const layout_width = metrics.cell_width * @as(u32, row.shaped_columns);
        if (layouts.row_generation == row.generation and
            layouts.font_generation == self.font_generation)
            return layouts;

        const text_length = render_commands.shapedUtf16Length(row);
        if (text_length == 0) {
            self.stashOrphan(layouts);
            layouts.row_generation = row.generation;
            layouts.font_generation = self.font_generation;
            layouts.content_fingerprint = row.fingerprint;
            layouts.shape_fingerprint = row.shape_fingerprint;
            layouts.layout_width = layout_width;
            return layouts;
        }

        // Selection, cursor, and color changes only alter drawing effects.
        // Keep the expensive shaped layout when its text and cell advances
        // are unchanged, and update the brush ranges in place.
        if (layouts.layout) |layout| {
            if (layouts.font_generation == self.font_generation and
                layouts.shape_fingerprint == row.shape_fingerprint and
                layouts.layout_width == layout_width)
            {
                try self.applyDrawingEffects(layout, row, text_length);
                layouts.row_generation = row.generation;
                layouts.content_fingerprint = row.fingerprint;
                return layouts;
            }
        }

        // Broad terminal damage can move unchanged rows to new viewport
        // positions. Transfer a matching layout with exclusive ownership, then
        // apply current colors/selection/cursor effects in place.
        if (self.takeMatchingLayout(row_index, row, layout_width)) |replacement| {
            self.stashOrphan(layouts);
            layouts.* = replacement;
            try self.applyDrawingEffects(layouts.layout.?, row, text_length);
            layouts.row_generation = row.generation;
            layouts.content_fingerprint = row.fingerprint;
            if (counters_enabled) self.layout_pool_hit_count +|= 1;
            return layouts;
        }

        const trace_start = frame_trace.timestamp();
        defer self.layout_trace.recordSince(trace_start);
        self.stashOrphan(layouts);
        errdefer layouts.clear();
        const format = self.text_format orelse return error.TextFormatUnavailable;
        const scale = dipScale(dpi);
        var layout: *dwrite.IDWriteTextLayout = undefined;
        if (self.dwrite_factory.CreateTextLayout(
            @ptrCast(row.utf16.items.ptr),
            @intCast(text_length),
            format,
            @max(1.0, @as(f32, @floatFromInt(layout_width)) * scale),
            @as(f32, @floatFromInt(metrics.cell_height)) * scale,
            &layout,
        ).failed) return error.CreateTextLayoutFailed;
        errdefer release(layout);
        const full_range: dwrite.DWRITE_TEXT_RANGE = .{
            .startPosition = 0,
            .length = @intCast(text_length),
        };
        if (layout.SetTypography(self.typography, full_range).failed)
            return error.ConfigureTextLayoutFailed;
        const layout1 = try queryInterface(
            dwrite.IDWriteTextLayout1,
            layout,
            dwrite.IID_IDWriteTextLayout1,
        );
        defer release(layout1);
        if (layout1.SetPairKerning(0, full_range).failed)
            return error.ConfigureTextLayoutFailed;
        if (row.hasUniformAsciiGrid()) {
            const first = row.graphemes.items[0];
            const measurement = try measureTextRange(
                layout,
                @intCast(first.text_start),
                @intCast(first.text_len),
            );
            const grid_advance =
                @as(f32, @floatFromInt(metrics.cell_width)) * scale;
            if (layout1.SetCharacterSpacing(
                0,
                (grid_advance - measurement.advance) /
                    @as(f32, @floatFromInt(measurement.hit_count)),
                0,
                full_range,
            ).failed) return error.ConfigureTextLayoutFailed;
        } else for (row.graphemes.items) |grapheme| {
            if (grapheme.cell_start + grapheme.cell_count > row.shaped_columns) break;
            const range: dwrite.DWRITE_TEXT_RANGE = .{
                .startPosition = @intCast(grapheme.text_start),
                .length = @intCast(grapheme.text_len),
            };
            const measurement = try measureTextRange(
                layout,
                range.startPosition,
                range.length,
            );
            const grid_advance = @as(f32, @floatFromInt(
                @as(u32, grapheme.cell_count) * metrics.cell_width,
            )) * scale;
            const trailing = (grid_advance - measurement.advance) /
                @as(f32, @floatFromInt(measurement.hit_count));
            if (layout1.SetCharacterSpacing(0, trailing, 0, range).failed)
                return error.ConfigureTextLayoutFailed;
        }
        try self.applyDrawingEffects(layout, row, text_length);
        layouts.layout = layout;
        if (counters_enabled) self.layout_build_count +|= 1;
        layouts.row_generation = row.generation;
        layouts.font_generation = self.font_generation;
        layouts.content_fingerprint = row.fingerprint;
        layouts.shape_fingerprint = row.shape_fingerprint;
        layouts.layout_width = layout_width;
        return layouts;
    }

    fn applyDrawingEffects(
        self: *DeviceResources,
        layout: *dwrite.IDWriteTextLayout,
        row: *const render_commands.CachedRow,
        text_length: usize,
    ) !void {
        const full_range: dwrite.DWRITE_TEXT_RANGE = .{
            .startPosition = 0,
            .length = @intCast(text_length),
        };
        if (layout.SetDrawingEffect(null, full_range).failed)
            return error.ConfigureTextLayoutFailed;
        for (row.text_runs.items) |text_run| {
            if (text_run.text_start >= text_length) break;
            const effect_length = @min(
                text_run.text_len,
                text_length - text_run.text_start,
            );
            const brush = try self.getBrush(text_run.color);
            if (layout.SetDrawingEffect(
                @ptrCast(&brush.IUnknown),
                .{
                    .startPosition = @intCast(text_run.text_start),
                    .length = @intCast(effect_length),
                },
            ).failed) return error.ConfigureTextLayoutFailed;
        }
    }

    fn presentScene(self: *DeviceResources, background_rgb: terminal.Rgb) !void {
        const copy_start = frame_trace.timestamp();
        const target_bitmap = self.target_bitmap orelse
            return error.TargetUnavailable;
        const scene = self.scene_bitmap orelse return error.TargetUnavailable;
        self.d2d_context.SetTarget(@ptrCast(target_bitmap));
        const target = &self.d2d_context.ID2D1RenderTarget;
        target.BeginDraw();
        const background = toColor(background_rgb);
        target.Clear(&background);
        // Do not rely on DrawBitmap's null-destination shorthand: after a
        // swap-chain resize it may round through DIPs and shift the terminal
        // by a pixel.  Source and destination are exactly the committed scene
        // pixels, anchored at the terminal margin.
        const scale = dipScale(self.target_dpi);
        const destination: d2d_common.D2D_RECT_F = .{
            .left = 0,
            .top = 0,
            .right = @as(f32, @floatFromInt(self.scene_width)) * scale,
            .bottom = @as(f32, @floatFromInt(self.scene_height)) * scale,
        };
        const source: d2d_common.D2D_RECT_F = .{
            .left = 0,
            .top = 0,
            .right = @floatFromInt(self.scene_width),
            .bottom = @floatFromInt(self.scene_height),
        };
        target.DrawBitmap(
            @ptrCast(scene),
            &destination,
            1.0,
            d2d.D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
            &source,
        );
        try checkDrawResult(target.EndDraw(null, null));
        self.copy_trace.recordSince(copy_start);

        const present_start = frame_trace.timestamp();
        // The DWM owns the display cadence for a windowed swap chain. Waiting
        // for v-sync here stalls the window procedure during live resizing;
        // that turns each WM_SIZE into a GPU round trip. A zero sync interval
        // lets DWM select the newest completed frame, as it does for GDI apps.
        const result = self.swap_chain.IDXGISwapChain.Present(0, 0);
        self.present_trace.recordSince(present_start);
        if (!result.failed) return;
        if (isDeviceLoss(result)) return error.DeviceLost;
        return error.PresentFailed;
    }

    fn ensureTextFormat(
        self: *DeviceResources,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !*dwrite.IDWriteTextFormat {
        const key: resource_cache.FontKey = .{
            .dpi = dpi,
            .cell_width = metrics.cell_width,
            .cell_height = metrics.cell_height,
        };
        if (self.text_format != null and self.font_state.matches(key))
            return self.text_format.?;

        var replacement: *dwrite.IDWriteTextFormat = undefined;
        const font_size: f32 = 16.0;
        if (self.dwrite_factory.CreateTextFormat(
            terminal_font_name,
            null,
            dwrite.DWRITE_FONT_WEIGHT_NORMAL,
            dwrite.DWRITE_FONT_STYLE_NORMAL,
            dwrite.DWRITE_FONT_STRETCH_NORMAL,
            font_size,
            locale_name,
            &replacement,
        ).failed) return error.CreateTextFormatFailed;
        errdefer release(replacement);
        if (replacement.SetWordWrapping(
            dwrite.DWRITE_WORD_WRAPPING_NO_WRAP,
        ).failed) return error.ConfigureTextFormatFailed;
        if (replacement.SetParagraphAlignment(
            dwrite.DWRITE_PARAGRAPH_ALIGNMENT_NEAR,
        ).failed) return error.ConfigureTextFormatFailed;
        const replacement1 = try queryInterface(
            dwrite.IDWriteTextFormat1,
            replacement,
            dwrite.IID_IDWriteTextFormat1,
        );
        defer release(replacement1);
        if (replacement1.SetFontFallback(self.font_fallback).failed)
            return error.ConfigureTextFormatFailed;

        if (self.text_format) |format| release(format);
        self.text_format = replacement;
        self.font_state.commit(key);
        self.font_generation +%= 1;
        if (self.font_generation == 0) self.font_generation = 1;
        self.clearRowLayouts();
        self.clearOrphanLayouts();
        self.scene_valid = false;
        return replacement;
    }

    fn getBrush(
        self: *DeviceResources,
        color: terminal.Rgb,
    ) !*d2d.ID2D1SolidColorBrush {
        const key = colorKey(color);
        if (self.brush_slots.find(key)) |index|
            return self.brushes[index].brush;

        const value = toColor(color);
        var replacement: *d2d.ID2D1SolidColorBrush = undefined;
        if (self.d2d_context.ID2D1RenderTarget.CreateSolidColorBrush(
            &value,
            null,
            &replacement,
        ).failed) return error.CreateBrushFailed;
        const insertion = self.brush_slots.insertion();
        if (insertion.occupied)
            release(self.brushes[insertion.index].brush);
        self.brushes[insertion.index] = .{ .brush = replacement };
        self.brush_slots.commit(insertion, key);
        return replacement;
    }

    fn releaseBrushes(self: *DeviceResources) void {
        for (self.brushes[0..self.brush_slots.count]) |entry|
            release(entry.brush);
        self.brush_slots = .{};
    }

    fn clearRowLayouts(self: *DeviceResources) void {
        for (self.row_layouts.items) |*layouts| layouts.clear();
    }

    fn releaseRowLayouts(self: *DeviceResources) void {
        for (self.row_layouts.items) |*layouts| layouts.deinit();
        self.row_layouts.deinit(std.heap.smp_allocator);
        self.row_layouts = .empty;
        self.clearOrphanLayouts();
        self.orphan_layouts.deinit(std.heap.smp_allocator);
        self.orphan_layouts = .empty;
    }

    fn clearOrphanLayouts(self: *DeviceResources) void {
        for (self.orphan_layouts.items) |*layouts| layouts.deinit();
        self.orphan_layouts.clearRetainingCapacity();
    }

    fn stashOrphan(self: *DeviceResources, layouts: *RowLayouts) void {
        if (layouts.layout == null) return;
        if (self.orphan_layouts.items.len == max_orphan_layouts) {
            self.orphan_layouts.items[0].deinit();
            _ = self.orphan_layouts.orderedRemove(0);
            if (counters_enabled) self.layout_pool_evict_count +|= 1;
        }
        self.orphan_layouts.append(std.heap.smp_allocator, layouts.*) catch {
            layouts.deinit();
            return;
        };
        layouts.* = .{};
    }

    fn takeMatchingLayout(
        self: *DeviceResources,
        row_index: usize,
        row: *const render_commands.CachedRow,
        layout_width: u32,
    ) ?RowLayouts {
        for (self.row_layouts.items, 0..) |candidate, index| {
            if (index == row_index or candidate.layout == null or
                candidate.font_generation != self.font_generation or
                candidate.shape_fingerprint != row.shape_fingerprint or
                candidate.layout_width != layout_width)
                continue;
            self.row_layouts.items[index] = .{};
            return candidate;
        }
        for (self.orphan_layouts.items, 0..) |candidate, index| {
            if (candidate.font_generation != self.font_generation or
                candidate.shape_fingerprint != row.shape_fingerprint or
                candidate.layout_width != layout_width)
                continue;
            return self.orphan_layouts.orderedRemove(index);
        }
        return null;
    }

    fn releaseTargetResources(self: *DeviceResources) void {
        self.releaseSwapChainTarget();
        if (self.scene_bitmap) |bitmap| release(bitmap);
        self.scene_bitmap = null;
        self.scene_width = 0;
        self.scene_height = 0;
        self.scene_dpi = 0;
        self.scene_capacity_width = 0;
        self.scene_capacity_height = 0;
        self.scene_valid = false;
    }

    fn releaseSwapChainTarget(self: *DeviceResources) void {
        self.d2d_context.SetTarget(null);
        if (self.target_bitmap) |bitmap| release(bitmap);
        self.target_bitmap = null;
    }
};

/// Build the normal system fallback chain, with the application-bundled Nerd
/// Font symbols taking priority for its Private Use Area glyphs. The font is
/// kept beside the executable so it never needs to be installed system-wide.
fn createFontFallback(
    factory: *dwrite.IDWriteFactory,
    factory2: *dwrite.IDWriteFactory2,
) !*dwrite.IDWriteFontFallback {
    var system_fallback: *dwrite.IDWriteFontFallback = undefined;
    if (factory2.GetSystemFontFallback(&system_fallback).failed)
        return error.GetSystemFontFallbackFailed;
    errdefer release(system_fallback);

    const factory3 = queryInterface(
        dwrite.IDWriteFactory3,
        factory,
        dwrite.IID_IDWriteFactory3,
    ) catch return system_fallback;
    defer release(factory3);

    var font_path: [1024:0]u16 = undefined;
    const executable_length = win32.kernel32.GetModuleFileNameW(
        null,
        &font_path,
        font_path.len,
    );
    if (executable_length == 0 or executable_length >= font_path.len)
        return system_fallback;
    const executable_path = font_path[0..executable_length];
    const directory_length = std.mem.lastIndexOfScalar(u16, executable_path, '\\') orelse
        return system_fallback;
    const font_path_length = directory_length + nerd_font_relative_path.len;
    if (font_path_length >= font_path.len) return system_fallback;
    std.mem.copyForwards(
        u16,
        font_path[directory_length..font_path_length],
        nerd_font_relative_path,
    );
    font_path[font_path_length] = 0;

    var face_reference: *dwrite.IDWriteFontFaceReference = undefined;
    if (factory3.CreateFontFaceReferencePath(
        @ptrCast(&font_path),
        null,
        0,
        .{},
        &face_reference,
    ).failed) return system_fallback;
    defer release(face_reference);
    var font_set_builder: *dwrite.IDWriteFontSetBuilder = undefined;
    if (factory3.CreateFontSetBuilder(&font_set_builder).failed)
        return system_fallback;
    defer release(font_set_builder);
    if (font_set_builder.AddFontFaceReferenceDefault(face_reference).failed)
        return system_fallback;
    var font_set: *dwrite.IDWriteFontSet = undefined;
    if (font_set_builder.CreateFontSet(&font_set).failed)
        return system_fallback;
    defer release(font_set);
    var font_collection: *dwrite.IDWriteFontCollection1 = undefined;
    if (factory3.CreateFontCollectionFromFontSet(font_set, &font_collection).failed)
        return system_fallback;
    defer release(font_collection);

    var builder: *dwrite.IDWriteFontFallbackBuilder = undefined;
    if (factory2.CreateFontFallbackBuilder(&builder).failed)
        return system_fallback;
    defer release(builder);
    const ranges = [_]dwrite.DWRITE_UNICODE_RANGE{
        .{ .first = 0xe000, .last = 0xf8ff },
        .{ .first = 0xf0000, .last = 0xf1fff },
    };
    const families = [_]?*const u16{@ptrCast(nerd_font_name.ptr)};
    if (builder.AddMapping(
        &ranges,
        ranges.len,
        &families,
        families.len,
        @ptrCast(font_collection),
        null,
        null,
        1.0,
    ).failed) return system_fallback;
    if (builder.AddMappings(system_fallback).failed)
        return system_fallback;
    var fallback: *dwrite.IDWriteFontFallback = undefined;
    if (builder.CreateFontFallback(&fallback).failed)
        return system_fallback;
    release(system_fallback);
    return fallback;
}

fn dipScale(dpi: u32) f32 {
    return 96.0 / @as(f32, @floatFromInt(@max(dpi, 1)));
}

/// Grow retained build surfaces geometrically. Interactive sizing crosses
/// cell boundaries far more often than it changes the eventual allocation
/// class, so exact-size allocations turn a drag into repeated GPU churn.
fn growSceneCapacity(current: u32, required: u32) u32 {
    if (current >= required) return current;
    const grown = current +| current / 2;
    return @max(required, @max(grown, 64));
}

fn toColor(color: terminal.Rgb) d2d_common.D2D_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt(color.red)) / 255.0,
        .g = @as(f32, @floatFromInt(color.green)) / 255.0,
        .b = @as(f32, @floatFromInt(color.blue)) / 255.0,
        .a = 1.0,
    };
}

fn colorKey(color: terminal.Rgb) u32 {
    return @as(u32, color.red) << 16 |
        @as(u32, color.green) << 8 |
        color.blue;
}

fn measureTextRange(
    layout: *dwrite.IDWriteTextLayout,
    start: u32,
    length: u32,
) !struct { advance: f32, hit_count: u32 } {
    var hit_metrics: [16]dwrite.DWRITE_HIT_TEST_METRICS = undefined;
    var hit_count: u32 = 0;
    if (layout.HitTestTextRange(
        start,
        length,
        0,
        0,
        &hit_metrics,
        hit_metrics.len,
        &hit_count,
    ).failed or hit_count == 0 or hit_count > hit_metrics.len)
        return error.MeasureTextClusterFailed;
    var shaped_advance: f32 = 0;
    for (hit_metrics[0..hit_count]) |hit| shaped_advance += hit.width;
    return .{ .advance = shaped_advance, .hit_count = hit_count };
}

fn checkDrawResult(result: win32.zig.HRESULT) !void {
    if (!result.failed) return;
    if (std.meta.eql(result, foundation.D2DERR_RECREATE_TARGET))
        return error.RecreateTarget;
    if (isDeviceLoss(result)) return error.DeviceLost;
    return error.DrawFailed;
}

fn isDeviceLoss(result: win32.zig.HRESULT) bool {
    return std.meta.eql(result, dxgi.DXGI_ERROR_DEVICE_REMOVED) or
        std.meta.eql(result, dxgi.DXGI_ERROR_DEVICE_RESET);
}

fn setMaximumFrameLatency(device: *dxgi.IDXGIDevice) !void {
    const device1 = try queryInterface(
        dxgi.IDXGIDevice1,
        device,
        dxgi.IID_IDXGIDevice1,
    );
    defer release(device1);
    if (device1.SetMaximumFrameLatency(1).failed)
        return error.SetMaximumFrameLatencyFailed;
}

fn queryInterface(
    comptime T: type,
    source: anytype,
    interface_id: *const win32.zig.Guid,
) !*T {
    var raw: *anyopaque = undefined;
    if (source.IUnknown.QueryInterface(interface_id, &raw).failed)
        return error.QueryInterfaceFailed;
    return @ptrCast(@alignCast(raw));
}

fn getParent(
    comptime T: type,
    source: anytype,
    interface_id: *const win32.zig.Guid,
) !*T {
    var raw: *anyopaque = undefined;
    if (source.IDXGIObject.GetParent(interface_id, &raw).failed)
        return error.GetParentFailed;
    return @ptrCast(@alignCast(raw));
}

fn release(value: anytype) void {
    _ = value.IUnknown.Release();
}
