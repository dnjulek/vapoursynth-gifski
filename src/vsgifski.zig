const std = @import("std");
const vapoursynth = @import("vapoursynth");

const c = @cImport({
    @cInclude("gifski.h");
    @cInclude("stdio.h");
});

const math = std.math;
const vs = vapoursynth.vapoursynth4;
const vsh = vapoursynth.vshelper;
const ZAPI = vapoursynth.ZAPI;
const zon = @import("zon");

const allocator = std.heap.c_allocator;

const Data = struct {
    node: ?*vs.Node,
    alpha: ?*vs.Node,
    vi: *const vs.VideoInfo,
    g: *c.gifski,
    fps: f64,
    file: *c.FILE,
};

fn planarRGBtoRGBA(src: *const ZAPI.ZFrame(*const vs.Frame), rgba: []u8) void {
    const r = src.getReadSlice(0);
    const g = src.getReadSlice(1);
    const b = src.getReadSlice(2);
    const w, const h, const stride = src.getDimensions(0);

    var x: u32 = 0;
    while (x < w) : (x += 1) {
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const i = (y * w + x) * 4;
            rgba[i + 0] = r[y * stride + x];
            rgba[i + 1] = g[y * stride + x];
            rgba[i + 2] = b[y * stride + x];
            rgba[i + 3] = 255;
        }
    }
}

fn planarRGBAtoRGBA(src: *const ZAPI.ZFrame(*const vs.Frame), alpha: *const ZAPI.ZFrame(*const vs.Frame), rgba: []u8) void {
    const r = src.getReadSlice(0);
    const g = src.getReadSlice(1);
    const b = src.getReadSlice(2);
    const a = alpha.getReadSlice(0);
    const w, const h, const stride = src.getDimensions(0);

    var x: u32 = 0;
    while (x < w) : (x += 1) {
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const i = (y * w + x) * 4;
            rgba[i + 0] = r[y * stride + x];
            rgba[i + 1] = g[y * stride + x];
            rgba[i + 2] = b[y * stride + x];
            rgba[i + 3] = a[y * stride + x];
        }
    }
}

export fn writeCallback(buffer_length: usize, buffer: [*c]const u8, user_data: ?*anyopaque) callconv(.c) c_int {
    const file: *c.FILE = @ptrCast(@alignCast(user_data.?));
    const written = c.fwrite(buffer, 1, buffer_length, file);
    return if (written == buffer_length) c.GIFSKI_OK else c.GIFSKI_WRITE_ZERO;
}

fn gifskiGetFrame(n: c_int, activation_reason: vs.ActivationReason, instance_data: ?*anyopaque, _: ?*?*anyopaque, frame_ctx: ?*vs.FrameContext, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) ?*const vs.Frame {
    const d: *Data = @ptrCast(@alignCast(instance_data));
    const zapi = ZAPI.init(vsapi, core, frame_ctx);

    if (activation_reason == .Initial) {
        zapi.requestFrameFilter(n, d.node);
        if (d.alpha) |node| zapi.requestFrameFilter(n, node);
    } else if (activation_reason == .AllFramesReady) {
        const src = zapi.initZFrame(d.node, n);
        const alpha = if (d.alpha) |node| zapi.initZFrame(node, n) else null;
        const rgba = allocator.alignedAlloc(u8, .@"32", @intCast(d.vi.width * d.vi.height * 4)) catch {
            zapi.setFilterError("\ngifski: failed to allocate memory");
            src.deinit();
            if (alpha) |a| a.deinit();
            return null;
        };

        if (alpha) |a| {
            planarRGBAtoRGBA(&src, &a, rgba);
        } else {
            planarRGBtoRGBA(&src, rgba);
        }

        const timestamp: f64 = @as(f64, @floatFromInt(n)) / d.fps;
        if (c.gifski_add_frame_rgba(
            d.g,
            @intCast(n),
            @intCast(d.vi.width),
            @intCast(d.vi.height),
            rgba.ptr,
            timestamp,
        ) != c.GIFSKI_OK) {
            zapi.setFilterError("\ngifski: failed to add frame");
            allocator.free(rgba);
            src.deinit();
            if (alpha) |a| a.deinit();
            return null;
        }

        allocator.free(rgba);
        if (alpha) |a| a.deinit();
        return src.frame;
    }

    return null;
}

fn gifskiFree(instance_data: ?*anyopaque, _: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    const d: *Data = @ptrCast(@alignCast(instance_data));
    _ = c.gifski_finish(d.g);
    _ = c.fclose(d.file);
    vsapi.?.freeNode.?(d.node);
    if (d.alpha) |node| vsapi.?.freeNode.?(node);
    allocator.destroy(d);
}

fn gifskiCreate(in: ?*const vs.Map, out: ?*vs.Map, _: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.c) void {
    var d: Data = undefined;
    const zapi = ZAPI.init(vsapi, core, null);
    const map_in = zapi.initZMap(in);
    const map_out = zapi.initZMap(out);

    d.node, d.vi = map_in.getNodeVi("clip").?;

    if (!vsh.isConstantVideoFormat(d.vi) or
        (d.vi.format.sampleType != .Integer) or
        (d.vi.format.bitsPerSample != 8) or
        (d.vi.format.colorFamily != .RGB))
    {
        map_out.setError("gifski: only constant format RGB24 input supported");
        zapi.freeNode(d.node);
        return;
    }

    d.alpha = map_in.getNode("alpha");
    if (d.alpha != null) {
        const alpha_vi = zapi.getVideoInfo(d.alpha);
        if (!vsh.isConstantVideoFormat(alpha_vi) or
            (alpha_vi.format.sampleType != .Integer) or
            (alpha_vi.format.bitsPerSample != 8) or
            (alpha_vi.format.colorFamily != .Gray))
        {
            map_out.setError("gifski: alpha must be a constant format Gray8 input");
            zapi.freeNode(d.node);
            zapi.freeNode(d.alpha);
            return;
        }

        if (d.vi.width != alpha_vi.width or d.vi.height != alpha_vi.height) {
            map_out.setError("gifski: alpha must have the same dimensions as the input clip");
            zapi.freeNode(d.node);
            zapi.freeNode(d.alpha);
            return;
        }
    }

    d.fps = @as(f64, @floatFromInt(d.vi.fpsNum)) / @as(f64, @floatFromInt(d.vi.fpsDen));
    const filename = map_in.getData("filename", 0) orelse "output.gif";
    const quality = map_in.getInt(i32, "quality") orelse 90;
    if (quality < 1 or quality > 100) {
        map_out.setError("gifski: quality must be between 1 and 100");
        zapi.freeNode(d.node);
        if (d.alpha) |node| zapi.freeNode(node);
        return;
    }

    const settings: c.GifskiSettings = .{
        .width = @intCast(d.vi.width),
        .height = @intCast(d.vi.height),
        .quality = @intCast(quality),
        .fast = false,
        .repeat = 0,
    };

    d.g = if (c.gifski_new(&settings)) |g| g else {
        map_out.setError("gifski: failed to create gifski instance");
        zapi.freeNode(d.node);
        if (d.alpha) |node| zapi.freeNode(node);
        return;
    };

    d.file = if (c.fopen(filename.ptr, "wb")) |f| f else {
        map_out.setError("gifski: failed to open output file");
        zapi.freeNode(d.node);
        if (d.alpha) |node| zapi.freeNode(node);
        return;
    };

    if (c.gifski_set_write_callback(d.g, writeCallback, d.file) != c.GIFSKI_OK) {
        map_out.setError("gifski: failed to set write callback");
        zapi.freeNode(d.node);
        if (d.alpha) |node| zapi.freeNode(node);
        return;
    }

    const data: *Data = allocator.create(Data) catch unreachable;
    data.* = d;

    const rp2: vs.RequestPattern = if ((d.alpha != null) and (d.vi.numFrames <= zapi.getVideoInfo(d.alpha).numFrames)) .StrictSpatial else .FrameReuseLastOnly;
    const deps = [_]vs.FilterDependency{
        .{ .source = d.node, .requestPattern = .StrictSpatial },
        .{ .source = d.alpha, .requestPattern = rp2 },
    };

    const ndeps: usize = if (d.alpha != null) 2 else 1;
    zapi.createVideoFilter(out, "gifski", d.vi, gifskiGetFrame, gifskiFree, .Parallel, deps[0..ndeps], data);
}

export fn VapourSynthPluginInit2(plugin: *vs.Plugin, vspapi: *const vs.PLUGINAPI) void {
    ZAPI.Plugin.config("com.julek.gifski", "gifski", "VapourSynth gifski", zon.version, plugin, vspapi);
    ZAPI.Plugin.function("Write", "clip:vnode;filename:data:opt;quality:int:opt;alpha:vnode:opt;", "clip:vnode;", gifskiCreate, plugin, vspapi);
}
