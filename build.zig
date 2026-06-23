const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sphtud_dep = b.dependency("sphtud", .{});
    const sphtud = sphtud_dep.module("sphtud");

    const exe = b.addExecutable(.{
        .name = "sphsvg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("sphtud", sphtud);

    const sphsvg_tests = b.addTest(.{
        .name = "sphsvg_test",
        .root_module = exe.root_module,
    });

    b.installArtifact(exe);
    b.installArtifact(sphsvg_tests);
}
