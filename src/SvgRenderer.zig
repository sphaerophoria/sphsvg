const sphtud = @import("sphtud");
const std = @import("std");
const SvgReader = @import("SvgReader.zig");
const Renderer = @import("Renderer.zig");
const PathParser = @import("PathParser.zig");


pub fn svgPathToRenderPath(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc, path: SvgReader.Path) !Renderer.Path {
    // FIXME: Find a reasonable upper bound
    var render_path = try Renderer.Path.init(arena, expansion, 16, 32 * 1024);
    var contour = try Renderer.Contour.init(arena, expansion, 16, 32 * 1024);
    var cursor = Renderer.Point{ 0, 0 };

    var cursor_start = cursor;

    var pp = PathParser.init(path.instructions);

    while (try pp.next()) |item| {
        switch (item) {
            .abs_move => |m| {
                cursor = m;
                cursor_start = cursor;
                try render_path.append(contour);
                contour = try Renderer.Contour.init(arena, expansion, 16, 32 * 1024);
            },
            .abs_line => |m| {
                const start = cursor;
                cursor = m;
                try contour.append(.{
                    .line = .{
                        .a = start,
                        .b = cursor,
                    },
                });
            },
            .abs_horizontal_line => |x| {
                const start = cursor;
                cursor[0] = x;
                try contour.append(.{ .line = .{
                    .a = start,
                    .b = cursor,
                } });
            },
            .abs_vertical_line => |y| {
                const start = cursor;
                cursor[1] = y;
                try contour.append(.{ .line = .{
                    .a = start,
                    .b = cursor,
                } });
            },
            .abs_cubic_bezier => |b| {
                const start = cursor;
                cursor = b[2];
                try contour.append(.{
                    .cubic_bezier = .{
                        .start = start,
                        .c1 = b[0],
                        .c2 = b[1],
                        .end = b[2],
                    },
                });
            },
            .abs_quad_bezier => |b| {
                const start = cursor;
                cursor = b[1];
                try contour.append(.{
                    .quad_bezier = .{
                        .start = start,
                        .c = b[0],
                        .end = b[1],
                    },
                });
            },
            .abs_cubic_bezier_seq => |b| {
                const c1 = reflectCubicBezier(cursor, b[0], b[1]);

                try contour.append(.{
                    .cubic_bezier = .{
                        .start = cursor,
                        .c1 = c1,
                        .c2 = b[0],
                        .end = b[1],
                    },
                });
                cursor = b[1];
            },
            .abs_arc => |params| {
                try contour.append(.{
                    .arc = svgToRenderArc(cursor, params),
                });

                cursor = params.end;
            },
            .rel_move => |m| {
                cursor += m;
                cursor_start = cursor;
            },
            .rel_line => |m| {
                const start = cursor;
                cursor += m;
                try contour.append(.{ .line = .{
                    .a = start,
                    .b = cursor,
                } });
            },
            .rel_horizontal_line => |x| {
                const start = cursor;
                cursor[0] += x;
                try contour.append(.{ .line = .{
                    .a = start,
                    .b = cursor,
                } });
            },
            .rel_vertical_line => |y| {
                const start = cursor;
                cursor[1] += y;
                try contour.append(.{ .line = .{
                    .a = start,
                    .b = cursor,
                } });
            },
            .rel_cubic_bezier => |b| {
                const start = cursor;
                const c1 = cursor + b[0];
                const c2 = cursor + b[1];
                cursor += b[2];

                try contour.append(.{
                    .cubic_bezier = .{
                        .start = start,
                        .c1 = c1,
                        .c2 = c2,
                        .end = cursor,
                    },
                });
            },
            .rel_quad_bezier => |b| {
                const start = cursor;
                const c = cursor + b[0];
                cursor += b[1];

                try contour.append(.{
                    .quad_bezier = .{
                        .start = start,
                        .c = c,
                        .end = cursor,
                    },
                });
            },
            .rel_cubic_bezier_seq => |b| {
                const end = cursor + b[1];
                const c2 = cursor + b[0];
                const c1 = reflectCubicBezier(cursor, c2, end);

                try contour.append(.{
                    .cubic_bezier = .{
                        .start = cursor,
                        .c1 = c1,
                        .c2 = c2,
                        .end = end,
                    },
                });
                cursor += b[1];
            },
            .rel_arc => |rel_params| {
                const params = PathParser.Arc{
                    .sweep_flag = rel_params.sweep_flag,
                    .rx = rel_params.rx,
                    .ry = rel_params.ry,
                    .large_arc = rel_params.large_arc,
                    .x_rot = rel_params.x_rot,
                    .end = cursor + rel_params.end,
                };

                try contour.append(.{
                    .arc = svgToRenderArc(cursor, params),
                });

                cursor = params.end;
            },
            .close => {
                try contour.append(.{
                    .line = .{
                        .a = cursor,
                        .b = cursor_start,
                    },
                });
            },
        }
    }

    try render_path.append(contour);

    return render_path;
}

pub fn handlePath(scratch: sphtud.alloc.LinearAllocator, path: SvgReader.Path, renderer: *Renderer, out: sphtud.img.Image) !void {
    const cp = scratch.checkpoint();
    defer scratch.restore(cp);

    const render_path = try svgPathToRenderPath(scratch.allocator(), .linear(scratch.allocator()), path);

    // FIXME: Default color maybe comes from renderer?
    var color = sphtud.math.Vec3{ 1, 1, 1 };
    if (path.fill) |f| {
        color = .{
            @as(f32, @floatFromInt(f[0])) / 255.0,
            @as(f32, @floatFromInt(f[1])) / 255.0,
            @as(f32, @floatFromInt(f[2])) / 255.0,
        };
    }
    try renderer.renderPath(scratch.allocator(), render_path, color);
    try renderer.renderPathToImage(render_path, color, out);
}

fn reflectCubicBezier(start: sphtud.math.Vec2, c2: sphtud.math.Vec2, end: sphtud.math.Vec2) sphtud.math.Vec2 {
    const end_c2 = c2 - end;
    const start_end_dir = sphtud.math.normalize(end - start);
    const reflect_offs = start_end_dir * @as(sphtud.math.Vec2, @splat(2 * sphtud.math.dot(end_c2, start_end_dir)));
    const start_c2 = end_c2 + reflect_offs;
    return start + start_c2;
}

fn svgToRenderArc(cursor: sphtud.math.Vec2, params: PathParser.Arc) Renderer.Arc {
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

    var step_2_scale = @sqrt((rx2 * ry2 - rx2 * y_prime_2 - ry2 * x_prime_2) /
        (rx2 * y_prime_2 + ry2 * x_prime_2));

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

    const theta = angleBetween(.{ 1, 0 }, v1);
    var delta_theta = angleBetween(v1, v2);
    if (!params.sweep_flag and delta_theta > 0) {
        delta_theta -= std.math.pi * 2;
    } else if (params.sweep_flag and delta_theta < 0) {
        delta_theta += std.math.pi * 2;
    }

    return .{
        .delta_theta = delta_theta,
        .start_theta = theta,
        .center = .{ cx, cy },
        .rx = params.rx,
        .ry = params.ry,
        .rot = params.x_rot,
    };
}

fn angleBetween(a: sphtud.math.Vec2, b: sphtud.math.Vec2) f32 {
    const ret = std.math.acos(sphtud.math.dot(sphtud.math.normalize(a), sphtud.math.normalize(b)));
    return ret * std.math.copysign(@as(f32, 1.0), sphtud.math.cross2(a, b));
}

