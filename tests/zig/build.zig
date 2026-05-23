const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "from_zig_host",
        .root_source_file = b.path("from_zig_host.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link against libsci (translated C header)
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("../../sci/libsci/target/libsci.h"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("libsci", translate.createModule());

    // Library and include paths
    exe.addLibraryPath(b.path("../../sci/libsci/target"));
    exe.linkSystemLibrary("sci");
    exe.addRPath(b.path("../../sci/libsci/target"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the integration test");
    run_step.dependOn(&run_cmd.step);
}
