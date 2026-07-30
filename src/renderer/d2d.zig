const win32 = @import("win32");

const foundation = win32.foundation;
const d2d = win32.graphics.direct2d;
const d3d = win32.graphics.direct3d;
const d3d11 = win32.graphics.direct3d11;
const dwrite = win32.graphics.direct_write;
const dxgi = win32.graphics.dxgi;
const d2d_common = d2d.common;
const dxgi_common = dxgi.common;

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
    target_bitmap: ?*d2d.ID2D1Bitmap1,
    scene_bitmap: ?*d2d.ID2D1Bitmap1,
    target_width: u32,
    target_height: u32,
    target_dpi: u32,
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
        return true;
    }

    pub fn deinit(self: *DeviceResources) void {
        self.releaseTargetResources();
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
        self.d2d_context.SetTarget(@ptrCast(scene));
    }

    fn releaseTargetResources(self: *DeviceResources) void {
        self.d2d_context.SetTarget(null);
        if (self.scene_bitmap) |bitmap| release(bitmap);
        self.scene_bitmap = null;
        if (self.target_bitmap) |bitmap| release(bitmap);
        self.target_bitmap = null;
    }
};

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
