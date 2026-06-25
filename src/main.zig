const sphtud = @import("sphtud");
const gl = sphtud.render.gl;
const std = @import("std");
const PathParser = @import("PathParser.zig");
const Renderer = @import("Renderer.zig");

fn loadSvg(alloc: std.mem.Allocator) ![]const u8 {
    const f = try sphtud.io.open("blender.svg", .{}, 0);
    defer sphtud.io.close(f);

    var reader_buf: [4096]u8 = undefined;
    var fr = sphtud.io.Reader.init(f, &reader_buf);
    const r = &fr.interface;

    return try r.allocRemaining(alloc, .unlimited);
}

fn ensureIsSvg(first_item: ?sphtud.xml.Item) !void {
    const unwrapped = first_item orelse return error.Invalid;
    if (unwrapped.type != .element_start) return error.Invalid;
    if (!std.mem.eql(u8, unwrapped.name, "svg")) return error.Invalid;
}

const xyt = sphtud.render.xyt_program;

fn angleBetween(a: sphtud.math.Vec2, b: sphtud.math.Vec2) f32 {
    const ret =  std.math.acos(sphtud.math.dot(sphtud.math.normalize(a), sphtud.math.normalize(b)));
    return ret * std.math.copysign(@as(f32, 1.0), sphtud.math.cross2(a, b));
}

fn handlePath(scratch: sphtud.alloc.LinearAllocator, xml_item: sphtud.xml.Item, renderer: *Renderer) !void {
    const cp = scratch.checkpoint();
    defer scratch.restore(cp);

    var attr_it = xml_item.attributeIt();

    // FIXME: Find a reasonable upper bound
    var render_path = try Renderer.Path.init(scratch.allocator(), .linear(scratch.allocator()), 16, 32 * 1024);
    var cursor = Renderer.Point{0, 0};
    // FIXME: Default color maybe comes from renderer?
    var color = sphtud.math.Vec3{1, 1, 1};

    while (try attr_it.next()) |attr| {
        if (std.mem.eql(u8, attr.key, "fill")) blk: {
            if (attr.val.len < 7 or attr.val[0] != '#') break :blk;

            const rs = attr.val[1..3];
            const gs = attr.val[3..5];
            const bs = attr.val[5..7];

            const r = try std.fmt.parseInt(u8, rs, 16);
            const g = try std.fmt.parseInt(u8, gs, 16);
            const b = try std.fmt.parseInt(u8, bs, 16);
            color = .{ r, g, b };
        }

        if (std.mem.eql(u8, attr.key, "d")) {
            var pp = PathParser.init(attr.val);

            while (try pp.next()) |item| {
                switch(item) {
                    .abs_move => |m| {
                        cursor = m;
                        try render_path.append(.{
                            .move = cursor,
                        });
                    },
                    .abs_line => |m| {
                        cursor = m;
                        try render_path.append(.{
                            .line_to = cursor,
                        });
                    },
                    .abs_horizontal_line => |x| {
                        cursor[0] = x;
                        try render_path.append(.{
                            .line_to = cursor,
                        });
                    },
                    .abs_vertical_line => |y| {
                        cursor[1] = y;
                        try render_path.append(.{
                            .line_to = cursor,
                        });
                    },
                    .abs_cubic_bezier => |b| {
                        cursor = b[2];
                        try render_path.append(.{
                            .cubic_bezier = .{
                                .c1 = b[0],
                                .c2 = b[1],
                                .end = b[2],
                            },
                        });
                    },
                    .abs_quad_bezier => |b| {
                        cursor = b[1];
                        try render_path.append(.{
                            .quad_bezier = .{
                                .c = b[0],
                                .end = b[1],
                            },
                        });
                    },
                    .abs_cubic_bezier_seq => |b| {
                        std.log.warn("skipping abs sequential bezier (need to reflect c1)\n", .{});
                        cursor = b[1];
                    },
                    .abs_arc => {
                        std.log.warn("skipping abs arc\n", .{});
                    },
                    .rel_move => |m| {
                        cursor += m;
                        try render_path.append(.{
                            .move = cursor,
                        });
                    },
                    .rel_line => |m| {
                        cursor += m;
                        try render_path.append(.{
                            .line_to = cursor,
                        });
                    },
                    .rel_horizontal_line => |x| {
                        cursor[0] += x;
                        try render_path.append(.{
                            .line_to = cursor,
                        });
                    },
                    .rel_vertical_line => |y| {
                        cursor[1] += y;
                        try render_path.append(.{
                            .line_to = cursor,
                        });
                    },
                    .rel_cubic_bezier => |b| {
                        const c1 = cursor + b[0];
                        const c2 = cursor + b[1];
                        cursor += b[2];

                        try render_path.append(.{
                            .cubic_bezier = .{
                                .c1 = c1,
                                .c2 = c2,
                                .end = cursor,
                            },
                        });
                    },
                    .rel_quad_bezier => |b| {
                        const c = cursor + b[0];
                        cursor += b[1];

                        try render_path.append(.{
                            .quad_bezier = .{
                                .c = c,
                                .end = cursor,
                            },
                        });
                    },
                    .rel_cubic_bezier_seq => |b| {
                        const end_v = cursor + b[1];
                        const c2_v = cursor + b[0];

                        const end_c2 = c2_v - end_v;

                        // FIXME: Why is this here?
                        const cursor_v = cursor;


                        const start_end_dir = sphtud.math.normalize(end_v - cursor_v);
                        const reflect_offs = start_end_dir * @as(sphtud.math.Vec2, @splat(2 * sphtud.math.dot(end_c2, start_end_dir)));
                        const start_c2 = end_c2 + reflect_offs;
                        const c1 = cursor_v + start_c2;

                        try render_path.append(.{
                            .cubic_bezier = .{
                                .c1 = c1,
                                .c2 = cursor + b[0],
                                .end = cursor + b[1],
                            },
                        });
                        cursor += b[1];
                    },
                    .rel_arc => |rel_params| {
                        const params = PathParser.Arc {
                            .sweep_flag = rel_params.sweep_flag,
                            .rx = rel_params.rx,
                            .ry = rel_params.ry,
                            .large_arc = rel_params.large_arc,
                            .x_rot = rel_params.x_rot,
                            .end = cursor + rel_params.end,
                        };

                        // https://www.w3.org/TR/SVG2/implnote.html#ArcImplementationNotes
                        // Section B.2.3
                        const half_x = (cursor[0] - params.end[0]) / 2.0;
                        const half_y = (cursor[1] - params.end[1]) / 2.0;

                        const x_rot_rad = params.x_rot * std.math.pi / 180.0;
                        const cos_phi = @cos(x_rot_rad);
                        const sin_phi = @sin(x_rot_rad);

                        // step 1
                        const x_prime = half_x * cos_phi + half_y * sin_phi;
                        const y_prime = half_x * -sin_phi + half_y * cos_phi;

                        const x_prime_2 = x_prime * x_prime;
                        const y_prime_2 = y_prime * y_prime;

                        //step 2
                        const rx2 = params.rx * params.rx;
                        const ry2 = params.ry * params.ry;

                        var step_2_scale = @sqrt(
                            (rx2 * ry2 - rx2 * y_prime_2 - ry2 * x_prime_2) /
                            (rx2 * y_prime_2  + ry2 * x_prime_2)
                        );

                        if (params.large_arc == params.sweep_flag) {
                            step_2_scale *= -1;
                        }

                        const cx_prime = step_2_scale * params.rx * y_prime / params.ry;
                        const cy_prime = step_2_scale * -params.ry * x_prime / params.rx;

                        // Step 3
                        const avg_x = (cursor[0] + params.end[0]) / 2;
                        const avg_y = (cursor[1] + params.end[1]) / 2;

                        const cx = cx_prime * cos_phi + cy_prime * -sin_phi + avg_x;
                        const cy = cy_prime * sin_phi + cy_prime * cos_phi + avg_y;


                        // step 4
                        const v1 = sphtud.math.Vec2{
                            (x_prime - cx_prime) / params.rx,
                            (y_prime - cy_prime) / params.ry,
                        };
                        const v2 = sphtud.math.Vec2{
                            (-x_prime - cx_prime) / params.rx,
                            (-y_prime - cy_prime) / params.ry,
                        };

                        const theta = angleBetween(.{1, 0}, v1);
                        var delta_theta = angleBetween(v1, v2);
                        if (!params.sweep_flag and delta_theta > 0) {
                            delta_theta -= std.math.pi * 2;
                        } else if (params.sweep_flag and delta_theta < 0) {
                            delta_theta += std.math.pi * 2;
                        }

                        try render_path.append(.{
                            .arc = .{
                                .delta_theta = delta_theta,
                                .start_theta = theta,
                                .center = .{ cx, cy },
                                .rx = params.rx,
                                .ry = params.ry,
                                .rot = params.x_rot,
                            },
                        });
                        cursor = params.end;
                    },
                    .close => {
                        try render_path.append(.close);
                    },
                }
            }
        }
    }

    try renderer.renderPath(scratch.allocator(), render_path, color);
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


pub fn main(init: std.process.Init) !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(1 * 1024 * 1024);

    const svg_data = try loadSvg(init.arena.allocator());
    var svg_reader = std.Io.Reader.fixed(svg_data);

    var parser = sphtud.xml.Parser.init(&svg_reader);

    var discarding = std.Io.Writer.Discarding.init(&.{});
    const dw = &discarding.writer;

    try ensureIsSvg(try parser.next(dw));

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphsvg", 800, 800);

    try sphtud.render.initGl(window.glLoader());

    gl.glClearColor(0, 0, 0, 1);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    var renderer = Renderer{
        .prog = try .init(&allocators.root_gl, solid_color_frag),
        .scratch_gl = &allocators.scratch_gl,
        // FIXME: Parse from the svg
        .tl = .{0, 0 },
        .br = .{ 128, 128 },
    };

    //try renderer.renderPath(.empty, .{ 1, 0, 0 });

    while (try parser.next(&discarding.writer)) |elem| switch (elem.type) {
        .xml_decl => {},
        .element_start => {
            const KnownElements = enum {
                path,
            };

            const known = std.meta.stringToEnum(KnownElements, elem.name) orelse return error.Unimplemented;

            switch (known) {
                .path => {
                    try handlePath(allocators.scratch.linear(), elem, &renderer);
                },
            }
        },
        .element_end => {},
        .element_content => {},
        .comment => {},
    };

    //{
    //    var path = try Renderer.Path.init(allocators.scratch.allocator(), .linear(allocators.scratch.allocator()), 16, 1024);
    //    try path.append(.{
    //        .arc = .{
    //            .center = .{ .x = 64, .y = 64 },
    //            .rx = 50,
    //            .ry = 32,
    //            .start_theta = 0,
    //            .delta_theta = 2 * std.math.pi,
    //            .rot = std.math.pi / 4.0,
    //        },
    //    });

    //    try renderer.renderPath(allocators.scratch.allocator(), path, .{ 1, 1, 1 });
    //}

    window.swapBuffers();

    //std.debug.print("{s}\n", .{svg_data});
    //
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
