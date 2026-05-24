const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_path = b.path("../sci/libsci/target");
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("../sci/libsci/target/libsci.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(include_path);
    const libsci_module = translate_c.createModule();

    const exe = b.addExecutable(.{
        .name = "sci-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig-host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("libsci", libsci_module);
    exe.root_module.addLibraryPath(include_path);
    exe.root_module.linkSystemLibrary("sci", .{});
    exe.root_module.addRPath(include_path);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);
}
