const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .opengl,
        .abi = .none,
        .cpu_features_add = std.Target.spirv.featureSet(&.{
            .float64,
            .variable_pointers,
            .v1_6
        }),
    });

    const sphtud = b.createModule(.{
        .root_source_file = b.path("sphtud/sphtud.zig"),
    });

    const shader = b.addExecutable(.{
        .name = "shader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("shader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    shader.root_module.addImport("sphtud", sphtud);

    b.installArtifact(shader);
}
