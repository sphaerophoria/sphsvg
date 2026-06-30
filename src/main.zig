const sphtud = @import("sphtud");
const gl = sphtud.render.gl;
const std = @import("std");
const PathParser = @import("PathParser.zig");
const Renderer = @import("Renderer.zig");
const SvgReader = @import("SvgReader.zig");
const SvgRenderer = @import("SvgRenderer.zig");

const xyt = sphtud.render.xyt_program;

pub fn renderSvg(
    scratch: sphtud.alloc.LinearAllocator,
    gl_alloc: *sphtud.render.GlAlloc,
    scratch_gl: *sphtud.render.GlAlloc,
    r: *std.Io.Reader,
    out: sphtud.img.Image,
) !void {
    var reader = try SvgReader.init(r);
    var renderer = Renderer{
        .prog = try .init(gl_alloc, solid_color_frag),
        .scratch_gl = scratch_gl,
        .tl = .{ reader.view_box.min_x, reader.view_box.min_y },
        .br = .{ reader.view_box.min_x + reader.view_box.width, reader.view_box.min_y + reader.view_box.height },
    };

    while (try reader.next()) |elem| switch (elem) {
        .path => |path| {
            try SvgRenderer.handlePath(scratch, path, &renderer, out);
        },
    };
}

pub const solid_color_frag =
    \\#version 330
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();

    _ = args.next();
    const width_s = args.next() orelse return error.NoWidth;
    const height_s = args.next() orelse return error.NoHeight;

    const width = try std.fmt.parseInt(u32, width_s, 0);
    const height = try std.fmt.parseInt(u32, height_s, 0);

    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(1 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphsvg", 800, 800);

    try sphtud.render.initGl(window.glLoader());

    gl.glClearColor(0, 0, 0, 1);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    const svg_f = try sphtud.io.open("blender.svg", .{}, 0);
    defer sphtud.io.close(svg_f);

    // Needs to be large enough to hold the largest attribute
    var reader_buf: [32 * 1024]u8 = undefined;
    var svg_data_reader = sphtud.io.Reader.init(svg_f, &reader_buf);

    const data_buf = try allocators.root.arena().alloc(u8, 4 * width * height);
    @memset(data_buf, 0);
    const img = sphtud.img.Image{
        .colorspace = .srgb,
        .transfer_fn = .srgb,
        .data = .init(.rgba_8888, data_buf),
        .width = width,
    };

    try renderSvg(
        allocators.scratch.linear(),
        &allocators.root_gl,
        &allocators.scratch_gl,
        &svg_data_reader.interface,
        img,
    );

    const out_ppm_f = try sphtud.io.open("out.ppm", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o664);
    defer sphtud.io.close(out_ppm_f);

    var out_ppm_w_buf: [4096]u8 = undefined;
    var out_ppm_w = sphtud.io.Writer.init(out_ppm_f, &out_ppm_w_buf);
    try sphtud.img.ppm.write(img, &out_ppm_w.interface);

    if (true) return;
    window.swapBuffers();

    while (!window.closed()) {
        try sphtud.io.nanosleep(.fromMilliseconds(50));
        window.queue.head = 0;
        window.queue.tail = 0;
        window.pollEvents();
    }
}

test {
    std.testing.refAllDecls(@This());
}
