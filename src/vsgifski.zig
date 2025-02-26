const std = @import("std");
const vapoursynth = @import("vapoursynth");

const c = @cImport({
    @cInclude("gifski.h");
    @cInclude("stdio.h");
});

const math = std.math;
const vs = vapoursynth.vapoursynth4;
const vsh = vapoursynth.vshelper;
const zapi = vapoursynth.zigapi;

const allocator = std.heap.c_allocator;

const Data = struct {
    node: ?*vs.Node,
    alpha: ?*vs.Node,
    vi: *const vs.VideoInfo,
    g: *c.gifski,
    fps: f64,
    file: *c.FILE,
};

fn planarRGBtoRGBA(src: *const zapi.ZFrameRO, rgba: []u8) void {
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

fn planarRGBAtoRGBA(src: *const zapi.ZFrameRO, alpha: *const zapi.ZFrameRO, rgba: []u8) void {
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

export fn writeCallback(buffer_length: usize, buffer: [*c]const u8, user_data: ?*anyopaque) callconv(.C) c_int {
    const file: *c.FILE = @ptrCast(@alignCast(user_data.?));
    const written = c.fwrite(buffer, 1, buffer_length, file);
    return if (written == buffer_length) c.GIFSKI_OK else c.GIFSKI_WRITE_ZERO;
}

export fn gifskiGetFrame(n: c_int, activation_reason: vs.ActivationReason, instance_data: ?*anyopaque, frame_data: ?*?*anyopaque, frame_ctx: ?*vs.FrameContext, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) ?*const vs.Frame {
    _ = frame_data;
    const d: *Data = @ptrCast(@alignCast(instance_data));

    if (activation_reason == .Initial) {
        vsapi.?.requestFrameFilter.?(n, d.node, frame_ctx);
        if (d.alpha) |node| vsapi.?.requestFrameFilter.?(n, node, frame_ctx);
    } else if (activation_reason == .AllFramesReady) {
        const src = zapi.ZFrameRO.init(d.node, n, frame_ctx, core, vsapi);
        const alpha = if (d.alpha) |node| zapi.ZFrameRO.init(node, n, frame_ctx, core, vsapi) else null;
        const rgba = allocator.alignedAlloc(u8, 32, @intCast(d.vi.width * d.vi.height * 4)) catch {
            vsapi.?.setFilterError.?("\ngifski: failed to allocate memory", frame_ctx);
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
            vsapi.?.setFilterError.?("\ngifski: failed to add frame", frame_ctx);
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

export fn gifskiFree(instance_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = core;
    const d: *Data = @ptrCast(@alignCast(instance_data));
    _ = c.gifski_finish(d.g);
    _ = c.fclose(d.file);
    vsapi.?.freeNode.?(d.node);
    if (d.alpha) |node| vsapi.?.freeNode.?(node);
    allocator.destroy(d);
}

export fn gifskiCreate(in: ?*const vs.Map, out: ?*vs.Map, user_data: ?*anyopaque, core: ?*vs.Core, vsapi: ?*const vs.API) callconv(.C) void {
    _ = user_data;
    var d: Data = undefined;
    const map_in = zapi.ZMapRO.init(in, vsapi);
    const map_out = zapi.ZMapRW.init(out, vsapi);

    d.node, d.vi = map_in.getNodeVi("clip");

    if (!vsh.isConstantVideoFormat(d.vi) or
        (d.vi.format.sampleType != .Integer) or
        (d.vi.format.bitsPerSample != 8) or
        (d.vi.format.colorFamily != .RGB))
    {
        map_out.setError("gifski: only constant format RGB24 input supported");
        vsapi.?.freeNode.?(d.node);
        return;
    }

    d.alpha, const alpha_vi = map_in.getNodeVi("alpha");
    if (d.alpha != null) {
        if (!vsh.isConstantVideoFormat(alpha_vi) or
            (alpha_vi.format.sampleType != .Integer) or
            (alpha_vi.format.bitsPerSample != 8) or
            (alpha_vi.format.colorFamily != .Gray))
        {
            map_out.setError("gifski: alpha must be a constant format Gray8 input");
            vsapi.?.freeNode.?(d.node);
            vsapi.?.freeNode.?(d.alpha);
            return;
        }

        if (d.vi.width != alpha_vi.width or d.vi.height != alpha_vi.height) {
            map_out.setError("gifski: alpha must have the same dimensions as the input clip");
            vsapi.?.freeNode.?(d.node);
            vsapi.?.freeNode.?(d.alpha);
            return;
        }
    }

    d.fps = @as(f64, @floatFromInt(d.vi.fpsNum)) / @as(f64, @floatFromInt(d.vi.fpsDen));
    const filename = map_in.getData("filename", 0) orelse "output.gif";
    const quality = map_in.getInt(i32, "quality") orelse 90;
    if (quality < 1 or quality > 100) {
        map_out.setError("gifski: quality must be between 1 and 100");
        vsapi.?.freeNode.?(d.node);
        if (d.alpha) |node| vsapi.?.freeNode.?(node);
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
        vsapi.?.freeNode.?(d.node);
        if (d.alpha) |node| vsapi.?.freeNode.?(node);
        return;
    };

    d.file = if (c.fopen(filename.ptr, "wb")) |f| f else {
        map_out.setError("gifski: failed to open output file");
        vsapi.?.freeNode.?(d.node);
        if (d.alpha) |node| vsapi.?.freeNode.?(node);
        return;
    };

    if (c.gifski_set_write_callback(d.g, writeCallback, d.file) != c.GIFSKI_OK) {
        map_out.setError("gifski: failed to set write callback");
        vsapi.?.freeNode.?(d.node);
        if (d.alpha) |node| vsapi.?.freeNode.?(node);
        return;
    }

    const data: *Data = allocator.create(Data) catch unreachable;
    data.* = d;

    const deps1 = [_]vs.FilterDependency{
        .{ .source = d.node, .requestPattern = .StrictSpatial },
    };
    var deps_len: c_int = deps1.len;
    var deps: [*]const vs.FilterDependency = &deps1;

    if (d.alpha != null) {
        const deps2 = [_]vs.FilterDependency{ deps1[0], .{
            .source = d.alpha,
            .requestPattern = if (d.vi.numFrames <= alpha_vi.numFrames) .StrictSpatial else .General,
        } };

        deps_len = deps2.len;
        deps = &deps2;
    }

    vsapi.?.createVideoFilter.?(out, "gifski", d.vi, gifskiGetFrame, gifskiFree, .Parallel, deps, deps_len, data, core);
}

export fn VapourSynthPluginInit2(plugin: *vs.Plugin, vspapi: *const vs.PLUGINAPI) void {
    _ = vspapi.configPlugin.?("com.julek.gifski", "gifski", "VapourSynth gifski", vs.makeVersion(1, 0), vs.VAPOURSYNTH_API_VERSION, 0, plugin);
    _ = vspapi.registerFunction.?("Write", "clip:vnode;filename:data:opt;quality:int:opt;alpha:vnode:opt;", "clip:vnode;", gifskiCreate, null, plugin);
}
