const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sphtud_dep = b.dependency("sphtud", .{
        .with_gl = true,
        .with_glfw = true,
    });
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

    const hit_test = b.addExecutable(.{
        .name = "hit_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hit_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hit_test.root_module.addImport("sphtud", sphtud);

    b.installArtifact(hit_test);

    const render_debug = b.addExecutable(.{
        .name = "render_debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render_debug.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    render_debug.root_module.addImport("sphtud", sphtud);

    b.installArtifact(render_debug);
}
