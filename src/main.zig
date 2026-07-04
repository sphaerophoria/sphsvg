const sphtud = @import("sphtud");
const gl = sphtud.render.gl;
const std = @import("std");
const PathParser = @import("PathParser.zig");
const Renderer = @import("Renderer.zig");
const SvgReader = @import("SvgReader.zig");
const svg_render_adapter = @import("svg_render_adapter.zig");

const xyt = sphtud.render.xyt_program;

pub fn renderSvg(
    scratch: sphtud.alloc.LinearAllocator,
    r: *std.Io.Reader,
    out: sphtud.img.Image,
) !void {
    var reader = try SvgReader.init(r);
    var renderer = Renderer{
        .tl = .{ reader.view_box.min_x, reader.view_box.min_y },
        .br = .{ reader.view_box.min_x + reader.view_box.width, reader.view_box.min_y + reader.view_box.height },
    };

    while (try reader.next()) |elem| switch (elem) {
        .path => |path| {
            try svg_render_adapter.handlePath(scratch, path, &renderer, out);
        },
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();

    _ = args.next();
    const filename = args.next() orelse return error.NoFile;
    const width_s = args.next() orelse return error.NoWidth;
    const height_s = args.next() orelse return error.NoHeight;

    const width = try std.fmt.parseInt(u32, width_s, 0);
    const height = try std.fmt.parseInt(u32, height_s, 0);

    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(1 * 1024 * 1024);

    const svg_f = try sphtud.io.open(filename, .{}, 0);
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
        &svg_data_reader.interface,
        img,
    );

    const out_ppm_f = try sphtud.io.open("out.ppm", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o664);
    defer sphtud.io.close(out_ppm_f);

    var out_ppm_w_buf: [4096]u8 = undefined;
    var out_ppm_w = sphtud.io.Writer.init(out_ppm_f, &out_ppm_w_buf);
    try sphtud.img.ppm.write(img, &out_ppm_w.interface);
    try out_ppm_w.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
