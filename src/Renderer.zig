const sphtud = @import("sphtud");
const std = @import("std");
const PathParser = @import("PathParser.zig");
const xyt = sphtud.render.xyt_program;

tl: Point,
br: Point,
// FIXME: If this renderer is for a specific image, than the program should be
// shared between other renderers
prog: xyt.Program(Uniforms),
scratch_gl: *sphtud.render.GlAlloc,

const bezier_resolution = 20;

const Renderer = @This();

const Uniforms = struct {
    color: sphtud.math.Vec3,
    transform: sphtud.math.Mat3x3,
};

pub const Contour = sphtud.util.RuntimeSegmentedList(Action);
pub const Path = sphtud.util.RuntimeSegmentedList(Contour);
pub const Point = sphtud.math.Vec2;

pub const CubicBezier = struct {
    start: Point,
    c1: Point,
    c2: Point,
    end: Point,
};

pub const QuadBezier = struct {
    start: Point,
    c: Point,
    end: Point,
};

pub const Arc = struct {
    rot: f32,
    rx: f32,
    ry: f32,
    center: Point,
    start_theta: f32,
    delta_theta: f32,
};

pub const Line = sphtud.geometry.Line2;

pub const Action = union(enum) {
    line: Line,
    cubic_bezier: CubicBezier,
    quad_bezier: QuadBezier,
    arc: Arc,
};

const PixelCross = struct {
    x_pos: f32,
    how: How,

    const How = enum {
        leave_top,
        enter_top,
        leave_bottom,
        enter_bottom,
    };
};

// FIXME: Duplicated with ttf renderer
pub fn findQuadBezierTForY(p1: f32, p2: f32, p3: f32, y: f32) [2]f32 {
    // Bezier curve formula comes from lerping p1->p2 by t, p2->p3 by t, and
    // then lerping the line from those two points by t as well
    //
    // p12 = (t * (p2 - p1)) + p1
    // p23 = (t * (p3 - p2)) + p2
    // out = (t * (p23 - p12)) + p12
    //
    // expanding and simplifying...
    // p12 = t*p2 - t*p1 + p1
    // p23 = t*p3 - t*p2 + p2
    // out = t(t*p3 - t*p2 + p2) - t(t*p2 - t*p1 + p1) + t*p2 - t*p1 + p1
    // out = t^2*p3 - t^2*p2 + t*p2 - t^2*p2 + t^2*p1 - t*p1 + t*p2 - t*p1 + p1
    // out = t^2(p3 - 2*p2 + p1) + t(p2 - p1 + p2 - p1) + p1
    // out = t^2(p3 - 2*p2 + p1) + 2*t(p2 - p1) + p1
    //
    // Which now looks like a quadratic formula that we can solve for.
    // Calling t^2 coefficient a, t coefficient b, and the remainder c...
    const a = p3 - 2 * p2 + p1;
    const b = 2 * (p2 - p1);
    // Note that we are solving for out == y, so we need to adjust the c term
    // to p1 - y
    const c = p1 - y;

    const eps = 1e-7;
    const not_quadratic = @abs(a) < eps;
    const not_linear = not_quadratic and @abs(b) < eps;
    if (not_linear) {
        // I guess in this case we can return any t, as all t values will
        // result in the same y value.
        return .{ 0.5, 0.5 };
    } else if (not_quadratic) {
        // bt + c = 0 (c accounts for y)
        const ret = -c / b;
        return .{ ret, ret };
    }

    const out_1 = (-b + @sqrt(b * b - 4 * a * c)) / (2 * a);
    const out_2 = (-b - @sqrt(b * b - 4 * a * c)) / (2 * a);
    return .{ out_1, out_2 };
}

const TangentLine = struct {
    a: @Vector(2, f32),
    b: @Vector(2, f32),
};

pub fn quadBezierTangentLine(a: @Vector(2, f32), b: @Vector(2, f32), c: @Vector(2, f32), t: f32) TangentLine {
    const t_splat: @Vector(2, f32) = @splat(t);
    const ab = std.math.lerp(a, b, t_splat);
    const bc = std.math.lerp(b, c, t_splat);
    return .{
        .a = ab,
        .b = bc,
    };
}

pub fn sampleQuadBezierCurve(a: @Vector(2, f32), b: @Vector(2, f32), c: @Vector(2, f32), t: f32) @Vector(2, f32) {
    const tangent_line = quadBezierTangentLine(a, b, c, t);
    return std.math.lerp(tangent_line.a, tangent_line.b, @as(@Vector(2, f32), @splat(t)));
}

const WindingChange = struct {
    pos: f32,
    change: i8,
};
// FIXME: Bad name
const Sampler = struct {
    hysterisis_size: f32,
    // FIXME: lol buf names
    buf: []PixelCross,
    buf2: []WindingChange,
    path: Path,

    const WindingChangeIter = struct {
        crosses: []const PixelCross,
        idx: usize = 0,
        last: PixelCross.How,

        pub fn next(self: *WindingChangeIter) ?WindingChange {
            // Note we have to check the wraparound case
            while (self.idx < self.crosses.len + 1) {
                defer self.idx += 1;

                const val = self.crosses[self.idx % self.crosses.len];
                defer self.last = val.how;

                if (val.how == .leave_top and self.last == .enter_bottom) {
                    return .{
                        .pos = val.x_pos,
                        .change = 1,
                    };
                } else if (val.how == .leave_bottom and self.last == .enter_top) {
                    return .{
                        .pos = val.x_pos,
                        .change = -1,
                    };
                }
            }

            return null;
        }
    };

    fn executeScanline(self: *Sampler, y: f32) ![]WindingChange {
        var it = self.path.iter();

        var ret = std.ArrayList(WindingChange).initBuffer(self.buf2);

        while (it.next()) |contour| {
            var contour_it = contour.iter();
            var crosses = std.ArrayList(PixelCross).initBuffer(self.buf);
            while (contour_it.next()) |segment| switch (segment.*) {
                .line => |line| {
                    if (slopePositive(line)) {
                        if (lineXForY(line, y - self.hysterisis_size)) |x| {
                            try crosses.appendBounded(.{ .x_pos = x, .how = .leave_top });
                        }

                        if (lineXForY(line, y + 1.0 - self.hysterisis_size)) |x| {
                            try crosses.appendBounded(.{ .x_pos = x, .how = .enter_bottom });
                        }
                    } else {
                        if (lineXForY(line, y + self.hysterisis_size)) |x| {
                            try crosses.appendBounded(.{ .x_pos = x, .how = .enter_top });
                        }

                        if (lineXForY(line, y + 1.0 + self.hysterisis_size)) |x| {
                            try crosses.appendBounded(.{ .x_pos = x, .how = .leave_bottom });
                        }
                    }
                },
                .cubic_bezier => |c| {
                    const Case = struct {
                        y: f32,
                        how: PixelCross.How,
                    };
                    const cases: []const Case = &.{
                        .{ .y = y,       .how = .leave_top },
                        //.{ .y = y - self.hysterisis_size,       .how = .leave_top },
                        //.{ .y = y + self.hysterisis_size,       .how = .enter_top },
                        //.{ .y = y + 1.0 + self.hysterisis_size, .how = .leave_bottom },
                        //.{ .y = y + 1.0 - self.hysterisis_size, .how = .enter_bottom },
                    };

                    // From wolfram alpha "collect (1-t)^3*a + 3*(1-t)^2*b + 3(1-t)t^2*c + t^3 * d, t"
                    // t^2 (3 a + 3 b + 3 c) + t (-3 a - 6 b) + t^3 (-a - 3 c + d) + a + 3 b
                    const cubic = Cubic {
                        .a = c.end[1] - c.start[1] - 3 * c.c2[1],
                        .b = 3 * (c.start[1] + c.c1[1] + c.c2[1]),
                        .c = -3 * c.start[1] - 6 * c.c1[1],
                        .d = c.start[1] + 3 * c.c1[1],
                    };

                    for (cases) |case| {
                        const ts = cubicTForY(cubic, case.y);
                        for (ts.buf[0..ts.len]) |t| {
                            if (t < 0 or t > 1) continue;

                            std.debug.print("t: {d}\n", .{t});
                            const sampled_y = cubicBezierYAtT(c, t);
                            std.debug.print("actual y: {d}, sampled y: {d}\n", .{sampled_y, y});
                            std.debug.assert(@abs(sampled_y - y) < 1e-6);

                            //const dir = cubicBezierDirAtT(c, t);
                            //if (dir[1] < 1e-6) continue;
                            //const dir_matches_how = switch (case.how) {
                            //    .enter_bottom, .leave_top => dir[1] < 0,
                            //    .leave_bottom, .enter_top => dir[1] > 0,
                            //};
                            //if (!dir_matches_how) continue;
                            const pos = cubicBezierXAtT(c, t);
                            try crosses.appendBounded(.{
                                .x_pos = pos,
                                .how = .enter_top,
                            });
                            try crosses.appendBounded(.{
                                .x_pos = pos,
                                .how = .leave_bottom,
                            });
                        }
                    }
                },
                else => {},
            };

            if (crosses.items.len < 1) continue;

            var winding_it = WindingChangeIter {
                .crosses = crosses.items,
                .idx = 1,
                .last = crosses.items[0].how,
            };

            while (winding_it.next()) |change| {
                try ret.appendBounded(change);
            }
        }

        return ret.items;
    }

    fn slopePositive(l: Line) bool {
        const right = sphtud.math.Vec2{1, 0};
        return sphtud.math.cross2(right, l.dir()) > 0;
    }

    test "slopePositive" {
        try std.testing.expectEqual(true, slopePositive(.{ .a = .{0, 0}, .b = .{1, 1}}));
        try std.testing.expectEqual(false, slopePositive(.{ .a = .{0, 0}, .b = .{0, 0}}));
        try std.testing.expectEqual(false, slopePositive(.{ .a = .{0, 0}, .b = .{1, -1}}));
    }

    fn lineXForY(l: Line, y: f32) ?f32 {
        var min_y = l.a[1];
        var max_y = l.b[1];

        if (min_y > max_y) std.mem.swap(f32, &min_y, &max_y);
        if (y < min_y or y > max_y) return null;

        const eps = 1e-7;

        //y = lerp(start, end, t);
        //y = l.a[1] + t*(l.b[1] - l.a[1]);
        //(y - l.a[1]) / (l.b[1] - l.a[1]) = t
        //x = l.a[0] + t*(l.b[0] - l.a[0]);
        const div = (l.b[1] - l.a[1]);
        // Relatively horizontal line. This cannot contribute to our winding
        // counts, so we just ignore
        if (div < eps) return null;
        const t = (y - l.a[1]) / div;

        return std.math.lerp(l.a[0], l.b[0], t);
    }

    test "lineXForY" {

        const res = lineXForY(.{
            .a = .{0, 0},
            .b = .{10, 10},
        }, 5.0) orelse return error.NoPoint;
        try std.testing.expectApproxEqAbs(5.0, res, 0.001);
    }

    const Cubic = struct {
        a: f32,
        b: f32,
        c: f32,
        d: f32,
    };

    fn cubicTForY(c: Cubic, y: f32) sphtud.math.CubicSolution {
        // cubic = y, move y to other side and solve
        return sphtud.math.solveCubic(c.a, c.b, c.c, c.d - y);
    }

    fn cubicBezierDirAtT(c: CubicBezier, t: f32) sphtud.math.Vec2 {
        // Derivative from https://en.wikipedia.org/wiki/B%C3%A9zier_curve#Cubic_B%C3%A9zier_curves
        const inv_t: sphtud.math.Vec2 = @splat(1 - t);
        const inv_t_2 = inv_t * inv_t;
        const t_2: sphtud.math.Vec2 = @splat(t * t);
        const t_v: sphtud.math.Vec2 = @splat(t);
        return sphtud.math.Vec2{3, 3} * inv_t_2 * (c.c1 - c.start) + sphtud.math.Vec2{6, 6} * inv_t*t_v*(c.c2 - c.c1) + sphtud.math.Vec2{3, 3} * t_2 * (c.end - c.c2);
    }

    fn cubicBezierXAtT(bez: CubicBezier, t: f32) f32 {
        const a = std.math.lerp(bez.start[0], bez.c1[0], t);
        const b = std.math.lerp(bez.c1[0], bez.c2[0], t);
        const c = std.math.lerp(bez.c2[0], bez.end[0], t);

        const d = std.math.lerp(a, b, t);
        const e = std.math.lerp(b, c, t);

        return std.math.lerp(d, e, t);
    }

    fn cubicBezierYAtT(bez: CubicBezier, t: f32) f32 {
        const a = std.math.lerp(bez.start[1], bez.c1[1], t);
        const b = std.math.lerp(bez.c1[1], bez.c2[1], t);
        const c = std.math.lerp(bez.c2[1], bez.end[1], t);

        const d = std.math.lerp(a, b, t);
        const e = std.math.lerp(b, c, t);

        return std.math.lerp(d, e, t);
    }
};

pub fn renderPathToImage(self: *Renderer, path: Path, color: sphtud.math.Vec3, out: sphtud.img.Image) !void {
    if (path.len == 0) return;

    const in_width = self.br[0] - self.tl[0];
    const in_height = self.br[1] - self.tl[1];

    const out_height: i64 = @intCast(out.calcHeight());
    const out_height_f: f32 = @floatFromInt(out_height);
    const out_width_f: f32 = @floatFromInt(out.width);

    // FIXME: Calculate based off max contour size * max crosses per segment or something
    const max_crosses = 1024;
    var cross_buf: [max_crosses]PixelCross = undefined;
    var windings_buf: [max_crosses]WindingChange = undefined;

    const pixel_height = in_height / out_height_f;
    var sampler = Sampler {
        .hysterisis_size = pixel_height / 8,
        .buf = &cross_buf,
        .buf2 = &windings_buf,
        .path = path,
    };

    for (0..out.calcHeight()) |out_y| {
        var in_y: f32 = @floatFromInt(out_y);
        in_y *= in_height / out_height_f;
        const scanline_windings = try sampler.executeScanline(in_y);

        var x_idx: usize = 0;
        var winding_count: i32 = 0;
        const px = sphtud.img.RgbF32Pixel{
            .r = color[0],
            .g = color[1],
            .b = color[2],
        };
        for (scanline_windings) |winding| {
            winding_count += winding.change;

            const out_x: i64 = @intFromFloat(winding.pos * out_width_f / in_width);
            if (out_x < 0) continue;

            const out_x_u: usize = @intCast(out_x);
            defer x_idx = out_x_u;

            // FIXME: SVG spec defines multiple fill rules
            switch (out.data) {
                inline else => |d| {
                    d.write(out_y * out.width + out_x_u, .from(px));
                }
            }
        }
    }

    //const buf = try scratch.allocator().alloc(RowCurvePoint, path.len);

    //while (y < out_height) {
    //    defer y += 1;

    //    const cp = scratch.checkpoint();
    //    defer scratch.restore(cp);

    //    const y_f: f32 = @floatFromInt(y);
    //    const points = try findRowCurvePoints(buf, path, @intFromFloat(y_f * in_height / out_height_f));
    //    for (points) |p| {
    //        switch (out.data) {
    //            inline else => |d| {
    //                const out_x: i64 = @intFromFloat(asf32(p.x_pos) * asf32(out.width) / in_width);
    //                const px = sphtud.img.RgbF32Pixel{
    //                    .r = color[0],
    //                    .g = color[1],
    //                    .b = color[2],
    //                };
    //                d.write(@intCast(y * out.width + out_x), .from(px));
    //            },
    //        }
    //    }
    //}
}

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

pub fn renderPath(self: *Renderer, scratch: std.mem.Allocator, path: Path, color: sphtud.math.Vec3) !void {
    if (path.len == 0) return;

    var buf_data: std.ArrayList(xyt.Vertex) = .empty;

    var it = path.iter();
    while (it.next()) |contour| {
        var contour_it = contour.iter();
        while (contour_it.next()) |inst| switch (inst.*) {
            .line => |m| {
                try buf_data.append(scratch, .{
                    .vPos = m.a,
                });
                try buf_data.append(scratch, .{
                    .vPos = m.b,
                });
            },
            .cubic_bezier => |bezier| {
                const start = bezier.start;
                const c1 = bezier.c1;
                const c2 = bezier.c2;
                const end = bezier.end;

                var last = bezier.start;
                for (0..bezier_resolution) |i| {
                    const t: sphtud.math.Vec2 = @splat(1.0 / @as(f32, bezier_resolution) * @as(f32, @floatFromInt(i + 1)));

                    const a = std.math.lerp(start, c1, t);
                    const b = std.math.lerp(c1, c2, t);
                    const c = std.math.lerp(c2, end, t);

                    const d = std.math.lerp(a, b, t);
                    const e = std.math.lerp(b, c, t);

                    const p = std.math.lerp(d, e, t);
                    try buf_data.append(scratch, .{ .vPos = last });
                    try buf_data.append(scratch, .{ .vPos = p });
                    last = p;
                }
            },
            .quad_bezier => {
                unreachable;
            },
            .arc => |arc| {
                const transform = sphtud.math.Transform.rotate(arc.rot).then(
                    .translate(arc.center[0], arc.center[1]),
                );

                var last = transform.apply(.{ arc.rx * @cos(arc.start_theta), arc.ry * @sin(arc.start_theta), 1 });

                for (0..bezier_resolution) |i| {
                    const t: f32 = 1.0 / @as(f32, bezier_resolution) * @as(f32, @floatFromInt(i + 1));
                    const theta = arc.start_theta + arc.delta_theta * t;

                    const val = transform.apply(.{ arc.rx * @cos(theta), arc.ry * @sin(theta), 1 });

                    try buf_data.append(scratch, .{ .vPos = .{ last[0], last[1] } });
                    try buf_data.append(scratch, .{ .vPos = .{ val[0], val[1] } });
                    last = val;
                }
            },
        };
    }

    try self.renderVertexList(buf_data.items, color);
}

fn renderVertexList(self: *Renderer, buf_data: []const xyt.Vertex, color: sphtud.math.Vec3) !void {
    const buf = try xyt.Buffer.init(self.scratch_gl, buf_data);

    var s = try xyt.RenderSource.init(self.scratch_gl);
    s.bindData(self.prog.handle(), buf);

    // Center of image at 0,0
    // Scale such that width/height are both 2
    // Tl -> br
    // width = br.x - tl.x
    // width = br.x - tl.x
    const cx = (self.tl[0] + self.br[0]) / 2.0;
    const cy = (self.tl[1] + self.br[1]) / 2.0;
    const width = self.br[0] - self.tl[0];
    const height = self.br[1] - self.tl[1];
    const transform = sphtud.math.Transform.translate(-cx, -cy)
        .then(.scale(2.0 / width, -2.0 / height));

    self.prog.renderLines(s, .{
        .color = color,
        .transform = transform.inner,
    });
}

test {
    _ = Sampler;
    std.testing.refAllDecls(@This());
}
