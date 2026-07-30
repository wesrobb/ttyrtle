const std = @import("std");
const win32 = @import("win32");
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
const locale_name = std.unicode.utf8ToUtf16LeStringLiteral("en-US");
const max_brushes = 64;

const BrushEntry = struct {
    brush: *d2d.ID2D1SolidColorBrush,
};

const RowLayouts = struct {
    row_generation: u64 = 0,
    font_generation: u64 = 0,
    layout: ?*dwrite.IDWriteTextLayout = null,

    fn clear(self: *RowLayouts) void {
        if (self.layout) |layout| release(layout);
        self.layout = null;
        self.row_generation = 0;
        self.font_generation = 0;
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
    scene_valid: bool,
    text_format: ?*dwrite.IDWriteTextFormat,
    font_state: resource_cache.FontState,
    font_generation: u64,
    row_layouts: std.ArrayListUnmanaged(RowLayouts),
    layout_build_count: u64,
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
        resources.scene_valid = false;
        resources.text_format = null;
        resources.font_state = .{};
        resources.font_generation = 0;
        resources.row_layouts = .empty;
        resources.layout_build_count = 0;
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
        if (resources.dwrite_factory2.GetSystemFontFallback(
            &resources.font_fallback,
        ).failed) return error.GetSystemFontFallbackFailed;
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
            self.scene_bitmap != null and
            self.target_width == width and
            self.target_height == height and
            self.target_dpi == dpi)
            return false;

        const size_changed = self.target_width != width or
            self.target_height != height;
        self.releaseTargetResources();
        if (size_changed and self.swap_chain.IDXGISwapChain.ResizeBuffers(
            0,
            width,
            height,
            dxgi_common.DXGI_FORMAT_UNKNOWN,
            0,
        ).failed) return error.ResizeSwapChainFailed;

        try self.createTargetResources(width, height, dpi);
        self.target_width = width;
        self.target_height = height;
        self.target_dpi = dpi;
        self.scene_valid = false;
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
        if (self.simulate_device_loss) {
            self.simulate_device_loss = false;
            return error.DeviceLost;
        }
        if (self.target_bitmap == null or self.scene_bitmap == null)
            return error.TargetUnavailable;

        _ = try self.ensureTextFormat(metrics, dpi);
        try self.resizeRowLayouts(cache.rows.items.len);
        if (!self.scene_valid) {
            try self.drawScene(cache, .full, metrics, dpi);
        } else switch (damage) {
            .none => {},
            else => try self.drawScene(cache, damage, metrics, dpi),
        }
        try self.presentScene();
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

    pub fn simulateDeviceLossForTesting(self: *DeviceResources) void {
        self.simulate_device_loss = true;
    }

    fn createTargetResources(
        self: *DeviceResources,
        width: u32,
        height: u32,
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
        errdefer release(target);

        const scene_properties: d2d.D2D1_BITMAP_PROPERTIES1 = .{
            .pixelFormat = pixel_format,
            .dpiX = pixels_per_inch,
            .dpiY = pixels_per_inch,
            .bitmapOptions = d2d.D2D1_BITMAP_OPTIONS_TARGET,
            .colorContext = null,
        };
        var scene: *d2d.ID2D1Bitmap1 = undefined;
        if (self.d2d_context.CreateBitmap(
            .{ .width = width, .height = height },
            null,
            0,
            &scene_properties,
            &scene,
        ).failed) return error.CreateSceneBitmapFailed;

        self.target_bitmap = target;
        self.scene_bitmap = scene;
        self.scene_valid = false;
    }

    fn drawScene(
        self: *DeviceResources,
        cache: *const render_commands.RenderCache,
        damage: terminal.RenderDamage,
        metrics: geometry.Metrics,
        dpi: u32,
    ) !void {
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
            for (self.row_layouts.items[row_count..]) |*layouts| layouts.deinit();
            self.row_layouts.shrinkRetainingCapacity(row_count);
        } else if (row_count > old_length) {
            try self.row_layouts.resize(std.heap.smp_allocator, row_count);
            for (self.row_layouts.items[old_length..]) |*layouts| layouts.* = .{};
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
        if (layouts.row_generation == row.generation and
            layouts.font_generation == self.font_generation)
            return layouts;

        layouts.clear();
        errdefer layouts.clear();
        const format = self.text_format orelse return error.TextFormatUnavailable;
        const scale = dipScale(dpi);
        var layout: *dwrite.IDWriteTextLayout = undefined;
        if (self.dwrite_factory.CreateTextLayout(
            @ptrCast(row.utf16.items.ptr),
            @intCast(row.utf16.items.len),
            format,
            @max(1.0, @as(f32, @floatFromInt(metrics.cell_width *
                @as(u32, @intCast(row.cells.items.len)))) * scale),
            @as(f32, @floatFromInt(metrics.cell_height)) * scale,
            &layout,
        ).failed) return error.CreateTextLayoutFailed;
        errdefer release(layout);
        const full_range: dwrite.DWRITE_TEXT_RANGE = .{
            .startPosition = 0,
            .length = @intCast(row.utf16.items.len),
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
        for (row.graphemes.items) |grapheme| {
            const range: dwrite.DWRITE_TEXT_RANGE = .{
                .startPosition = @intCast(grapheme.text_start),
                .length = @intCast(grapheme.text_len),
            };
            var hit_metrics: [16]dwrite.DWRITE_HIT_TEST_METRICS = undefined;
            var hit_count: u32 = 0;
            if (layout.HitTestTextRange(
                range.startPosition,
                range.length,
                0,
                0,
                &hit_metrics,
                hit_metrics.len,
                &hit_count,
            ).failed or hit_count == 0 or hit_count > hit_metrics.len)
                return error.MeasureTextClusterFailed;
            var shaped_advance: f32 = 0;
            for (hit_metrics[0..hit_count]) |hit| shaped_advance += hit.width;
            const grid_advance = @as(f32, @floatFromInt(
                @as(u32, grapheme.cell_count) * metrics.cell_width,
            )) * scale;
            const trailing = (grid_advance - shaped_advance) /
                @as(f32, @floatFromInt(hit_count));
            if (layout1.SetCharacterSpacing(0, trailing, 0, range).failed)
                return error.ConfigureTextLayoutFailed;
        }
        for (row.text_runs.items) |text_run| {
            const brush = try self.getBrush(text_run.color);
            if (layout.SetDrawingEffect(
                @ptrCast(&brush.IUnknown),
                .{
                    .startPosition = @intCast(text_run.text_start),
                    .length = @intCast(text_run.text_len),
                },
            ).failed) return error.ConfigureTextLayoutFailed;
        }
        layouts.layout = layout;
        self.layout_build_count +%= 1;
        layouts.row_generation = row.generation;
        layouts.font_generation = self.font_generation;
        return layouts;
    }

    fn presentScene(self: *DeviceResources) !void {
        const target_bitmap = self.target_bitmap orelse
            return error.TargetUnavailable;
        const scene = self.scene_bitmap orelse return error.TargetUnavailable;
        self.d2d_context.SetTarget(@ptrCast(target_bitmap));
        const target = &self.d2d_context.ID2D1RenderTarget;
        target.BeginDraw();
        target.DrawBitmap(
            @ptrCast(scene),
            null,
            1.0,
            d2d.D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
            null,
        );
        try checkDrawResult(target.EndDraw(null, null));

        const result = self.swap_chain.IDXGISwapChain.Present(1, 0);
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
    }

    fn releaseTargetResources(self: *DeviceResources) void {
        self.d2d_context.SetTarget(null);
        if (self.scene_bitmap) |bitmap| release(bitmap);
        self.scene_bitmap = null;
        if (self.target_bitmap) |bitmap| release(bitmap);
        self.target_bitmap = null;
        self.scene_valid = false;
    }
};

fn dipScale(dpi: u32) f32 {
    return 96.0 / @as(f32, @floatFromInt(@max(dpi, 1)));
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
