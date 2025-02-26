const std = @import("std");
const os = @import("builtin").os.tag;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "vsgifski",
        .root_source_file = b.path("src/vsgifski.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gifski_dep = b.dependency("gifski", .{});
    const vapoursynth_dep = b.dependency("vapoursynth", .{
        .target = target,
        .optimize = optimize,
    });

    const cargo_cmd = b.addSystemCommand(&.{ "cargo", "build", "--lib", "--release" });
    cargo_cmd.cwd = gifski_dep.path(".");

    lib.linkLibC();
    lib.step.dependOn(&cargo_cmd.step);
    lib.addIncludePath(gifski_dep.path("."));
    lib.addLibraryPath(gifski_dep.path("target/release/"));
    lib.linkSystemLibrary2("gifski", .{ .preferred_link_mode = .static });
    lib.root_module.addImport("vapoursynth", vapoursynth_dep.module("vapoursynth"));

    lib.linkSystemLibrary("unwind");
    if (os == .windows) {
        lib.linkSystemLibrary("ws2_32");
        lib.linkSystemLibrary("userenv");
    }

    if (lib.root_module.optimize == .ReleaseFast) {
        lib.root_module.strip = true;
    }

    b.installArtifact(lib);
}
