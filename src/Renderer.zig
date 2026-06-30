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

const WindingChange = struct {
    pos: f32,
    change: i8,
};

// FIXME: Bad name
const Sampler = struct {
    hysterisis_size: f32,
    pixel_height: f32,
    // FIXME: lol buf names
    buf: []PixelCross,
    windings: *std.ArrayList(WindingChange),
    contour: Contour,

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

    fn executeScanline(self: *Sampler, y: f32) !void {
        var contour_it = self.contour.iter();

        const Case = struct {
            y: f32,
            how: PixelCross.How,
        };
        const ph = self.pixel_height;

        // FIXME: The entire pixel is kinda acting as a hysteresis, so we
        // should probably re-work this stuff so that we only run scanline
        // checks twice
        const cases: []const Case = &.{
            .{ .y = y - self.hysterisis_size,      .how = .leave_top },
            .{ .y = y + self.hysterisis_size,      .how = .enter_top },
            .{ .y = y + ph + self.hysterisis_size, .how = .leave_bottom },
            .{ .y = y + ph - self.hysterisis_size, .how = .enter_bottom },
        };


        // FIXME: We may have to handle discontinuity between start of one
        // line and end of another due to floating point imprecision. If we
        // cross our boundary between the start of one line and the end of
        // another this could fall over

        var crosses = std.ArrayList(PixelCross).initBuffer(self.buf);
        while (contour_it.next()) |segment| switch (segment.*) {
            .line => |line| {
                if (slopePositive(line)) {
                    // Going down: enters via top edge, leaves via bottom.
                    if (lineXForY(line, y + self.hysterisis_size)) |x| {
                        try crosses.appendBounded(.{ .x_pos = x, .how = .enter_top });
                    }

                    if (lineXForY(line, y + ph + self.hysterisis_size)) |x| {
                        try crosses.appendBounded(.{ .x_pos = x, .how = .leave_bottom });
                    }
                } else {
                    // Going up: enters via bottom edge, leaves via top.
                    if (lineXForY(line, y + ph - self.hysterisis_size)) |x| {
                        try crosses.appendBounded(.{ .x_pos = x, .how = .enter_bottom });
                    }

                    if (lineXForY(line, y - self.hysterisis_size)) |x| {
                        try crosses.appendBounded(.{ .x_pos = x, .how = .leave_top });
                    }
                }
            },
            .quad_bezier => {
                unreachable;
            },
            .cubic_bezier => |c| {
                // From wolfram alpha "collect (1-t)^3*a + 3*(1-t)^2*t*b + 3*(1-t)*t^2*c + t^3 * d, t"
                // t^3 (-a + 3b - 3c + d) + t^2 (3a - 6b + 3c) + t (-3a + 3b) + a
                const cubic = Cubic {
                    .a = -c.start[1] + 3 * c.c1[1] - 3 * c.c2[1] + c.end[1],
                    .b = 3 * c.start[1] - 6 * c.c1[1] + 3 * c.c2[1],
                    .c = -3 * c.start[1] + 3 * c.c1[1],
                    .d = c.start[1],
                };

                // Collect candidate events first, then emit in t-order so
                // adjacency in `crosses` reflects path traversal order.
                const Event = struct { t: f32, cross: PixelCross };
                var events: [12]Event = undefined;
                var events_len: usize = 0;

                for (cases) |case| {
                    const ts = cubicTForY(cubic, case.y);
                    for (ts.buf[0..ts.len]) |t| {
                        if (t < 0 or t > 1) continue;

                        const dir = cubicBezierDirAtT(c, t);
                        if (@abs(dir[1]) < 1e-6) continue;
                        const dir_matches_how = switch (case.how) {
                            .enter_bottom, .leave_top => dir[1] < 0,
                            .leave_bottom, .enter_top => dir[1] > 0,
                        };
                        if (!dir_matches_how) continue;
                        events[events_len] = .{
                            .t = t,
                            .cross = .{
                                .x_pos = cubicBezierXAtT(c, t),
                                .how = case.how,
                            },
                        };
                        events_len += 1;
                    }
                }

                std.mem.sort(Event, events[0..events_len], {}, struct {
                    fn f(_: void, a: Event, b: Event) bool {
                        return a.t < b.t;
                    }
                }.f);

                for (events[0..events_len]) |ev| {
                    try crosses.appendBounded(ev.cross);
                }
            },
            .arc => |arc| {
                // Collect then sort by traversal progress along the arc
                // (same reasoning as the cubic case).
                const Event = struct { progress: f32, cross: PixelCross };
                var events: [8]Event = undefined;
                var events_len: usize = 0;

                for (cases) |case| {
                    const angles = ellipseAnglesForY(arc, case.y) orelse continue;
                    for (angles) |theta| {
                        if (!angleOnArc(arc, theta)) continue;

                        const dir = arcDirAtTheta(arc, theta);
                        // FIXME: duped with bezier
                        const dir_matches_how = switch (case.how) {
                            .enter_bottom, .leave_top => dir[1] < 0,
                            .leave_bottom, .enter_top => dir[1] > 0,
                        };
                        if (!dir_matches_how) continue;

                        const offs = if (arc.delta_theta >= 0)
                            theta - arc.start_theta
                        else
                            arc.start_theta - theta;
                        events[events_len] = .{
                            .progress = @mod(offs, std.math.tau),
                            .cross = .{
                                .x_pos = arcXAtTheta(arc, theta),
                                .how = case.how,
                            },
                        };
                        events_len += 1;
                    }
                }

                std.mem.sort(Event, events[0..events_len], {}, struct {
                    fn lessThan(_: void, a: Event, b: Event) bool {
                        return a.progress < b.progress;
                    }
                }.lessThan);

                for (events[0..events_len]) |ev| {
                    try crosses.appendBounded(ev.cross);
                }
            },
        };

        if (crosses.items.len < 1) return;

        var winding_it = WindingChangeIter {
            .crosses = crosses.items,
            .idx = 1,
            .last = crosses.items[0].how,
        };

        while (winding_it.next()) |change| {
            try self.windings.appendBounded(change);
        }
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
        if (@abs(div) < eps) return null;
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

    fn ellipseAnglesForY(arc: Arc, y: f32) ?[2]f32 {
        const ellipse = sphtud.geometry.Ellipse{
            .center = arc.center,
            .rx = arc.rx,
            .ry = arc.ry,
            .rotation = arc.rot,
        };

        // Start the ray far enough left that both intersections sit ahead of
        // it; the rotated ellipse fits inside a circle of radius max(rx, ry).
        const max_r = @max(arc.rx, arc.ry);
        const ray = sphtud.geometry.Ray2{
            .start = .{ arc.center[0] - 2 * max_r - 1, y },
            .dir = .{ 1, 0 },
        };

        var ret_buf: [2]sphtud.math.Vec2 = undefined;
        const points = sphtud.geometry.rayEllipseIntersection(ray, ellipse, &ret_buf);
        if (points.len < 2) return null;

        // ellipseToCircle maps an ellipse point to (cos θ, sin θ) on the unit circle.
        const to_circle = sphtud.geometry.ellipseToCircle(ellipse);
        const p1 = to_circle.apply2(points[0]);
        const p2 = to_circle.apply2(points[1]);
        return .{
            std.math.atan2(p1[1], p1[0]),
            std.math.atan2(p2[1], p2[0]),
        };
    }

    fn angleOnArc(arc: Arc, theta: f32) bool {
        const tau = std.math.tau;
        // Pick the representative of (theta - start_theta) in [0, 2π).
        var d = @mod(theta - arc.start_theta, tau);
        if (arc.delta_theta >= 0) {
            return d <= arc.delta_theta;
        }
        // For a negative sweep we want d in (-2π, 0].
        if (d > 0) d -= tau;
        return d >= arc.delta_theta;
    }

    fn arcXAtTheta(arc: Arc, theta: f32) f32 {
        // P(θ) = R(rot) · (rx cos θ, ry sin θ) + center; only the x is needed.
        const x_local = arc.rx * @cos(theta);
        const y_local = arc.ry * @sin(theta);
        return @cos(arc.rot) * x_local - @sin(arc.rot) * y_local + arc.center[0];
    }

    fn arcDirAtTheta(arc: Arc, theta: f32) sphtud.math.Vec2 {
        const ellipse = sphtud.geometry.Ellipse{
            .center = arc.center,
            .rx = arc.rx,
            .ry = arc.ry,
            .rotation = arc.rot,
        };
        // Tangent on the unit circle at θ is (-sin θ, cos θ) — radius rotated 90°.
        // Homogeneous coord 0 strips out translation so ellipseFromCircle only
        // applies the scale+rotate stretch to the direction vector.
        const from_circle = sphtud.geometry.ellipseFromCircle(ellipse);
        const tangent = from_circle.apply(.{ -@sin(theta), @cos(theta), 0 });
        var dir = sphtud.math.Vec2{ tangent[0], tangent[1] };
        if (arc.delta_theta < 0) dir = -dir;
        return dir;
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
    for (0..out.calcHeight()) |out_y| {
        var it = path.iter();
        var windings: std.ArrayList(WindingChange) = .initBuffer(&windings_buf);

        while (it.next()) |contour| {
            // FIXME: I'm not really sure this needs to be a struct anymore
            var sampler = Sampler {
                // FIXME: This may be unnecessary
                .hysterisis_size = 0, //pixel_height / 8,
                .pixel_height = pixel_height,
                .buf = &cross_buf,
                .windings = &windings,
                .contour = contour.*,
            };

            var in_y: f32 = @floatFromInt(out_y);
            in_y *= in_height / out_height_f;
            try sampler.executeScanline(in_y);
        }

        std.mem.sort(WindingChange, windings.items, {}, struct {
            fn f(_: void, a: WindingChange, b: WindingChange) bool {
                return a.pos < b.pos;
            }
        }.f);

        var x_idx: usize = 0;
        var winding_count: i32 = 0;
        const px = sphtud.img.RgbF32Pixel{
            .r = color[0],
            .g = color[1],
            .b = color[2],
        };

        for (windings.items) |winding| {
            const prev_count = winding_count;
            winding_count += winding.change;

            const out_x: i64 = @intFromFloat(winding.pos * out_width_f / in_width);
            if (out_x < 0) continue;

            // Clamp so the fill loop never walks past the row into the
            // next one when paths extend beyond the canvas right edge.
            const out_x_u: usize = @intCast(@min(out_x, @as(i64, @intCast(out.width))));
            defer x_idx = out_x_u;

            // We have the following cases
            //  1. non-zero to non-zero -> fill with color
            //  2. zero to non-zero -> do nothing
            //  3. non-zero to zero -> fill with color
            //
            // i.e. fill iff the span we just walked across was inside,
            // which is determined by the winding count BEFORE this event,
            // not after.
            if (prev_count == 0) continue;

            // FIXME: SVG spec defines multiple fill rules
            switch (out.data) {
                inline else => |d| {
                    // FIXME: We need some memset API on the color data
                    for (x_idx..out_x_u) |x| {
                        d.write(out_y * out.width + x, .from(px));
                    }
                }
            }
        }
    }
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
