const sphtud = @import("sphtud");
const std = @import("std");
const PathParser = @import("PathParser.zig");
const xyt = sphtud.render.xyt_program;
const CoordinateConverter = @import("CoordinateConverter.zig");

tl: Point,
br: Point,

const Renderer = @This();

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

    const Applier = struct {
        transform: sphtud.math.Transform,

        pub fn apply(self: Applier, theta: f32) Point {
            return self.transform.apply2(.{
                @cos(theta), @sin(theta),
            });
        }
    };

    pub fn applier(arc: Arc) Applier {
        return .{
            .transform = sphtud.math.Transform.scale(arc.rx, arc.ry)
                .then(.rotate(arc.rot))
                .then(
                .translate(arc.center[0], arc.center[1]),
            ),
        };
    }
};

pub const Line = sphtud.geometry.Line2;

pub const Action = union(enum) {
    line: Line,
    cubic_bezier: CubicBezier,
    quad_bezier: QuadBezier,
    arc: Arc,
};

pub const PixelCross = struct {
    x_pos: f32,
    how: How,

    pub const How = enum {
        leave_top,
        enter_top,
        leave_bottom,
        enter_bottom,

        fn isEnter(self: How) bool {
            switch (self) {
                .enter_top, .enter_bottom => return true,
                .leave_top, .leave_bottom => return false,
            }
        }
    };
};

pub const WindingChange = struct {
    pos: f32,
    change: i8,
};

pub const WindingChangeCalculator = struct {
    pixel_height: f32,
    y: f32,
    crosses_buf: [max_crosses]PixelCross,
    windings_buf: [max_crosses]WindingChange,
    num_crosses: usize = 0,
    num_windings: usize = 0,
    path: Path,

    // FIXME: Calculate based off max contour size * max crosses per segment or something
    const max_crosses = 1024;

    pub fn initPinned(
        self: *WindingChangeCalculator,
        pixel_height: f32,
        y: f32,
        path: Path,
    ) void {
        self.* = .{
            .pixel_height = pixel_height,
            .y = y,
            .crosses_buf = undefined,
            .windings_buf = undefined,
            .path = path,
        };
    }

    pub fn calculateWindingChanges(self: *WindingChangeCalculator) ![]const WindingChange {
        var windings = std.ArrayList(WindingChange).initBuffer(&self.windings_buf);
        defer self.num_windings = windings.items.len;

        var it = self.path.iter();
        while (it.next()) |contour| {
            var contour_it = contour.iter();

            // Keep all crosses around for inspection if something goes wrong
            var crosses = std.ArrayList(PixelCross).initBuffer(self.crosses_buf[self.num_crosses..]);
            defer self.num_crosses += crosses.items.len;

            while (contour_it.next()) |segment| {
                try appendSortedSegmentCrosses(segment.*, self.y, self.pixel_height, &crosses);
            }

            if (crosses.items.len < 1) continue;

            var winding_it = WindingChangeIter{
                .crosses = crosses.items,
                .idx = 1,
                .last = crosses.items[0].how,
            };

            while (winding_it.next()) |change| {
                try windings.appendBounded(change);
            }
        }

        std.mem.sort(WindingChange, windings.items, {}, struct {
            fn f(_: void, a: WindingChange, b: WindingChange) bool {
                return a.pos < b.pos;
            }
        }.f);

        return windings.items;
    }

    fn appendSortedSegmentCrosses(segment: Action, y: f32, pixel_height: f32, crosses: *std.ArrayList(PixelCross)) !void {
        var unsorted_buf: [12]CrossWithT = undefined;
        const events = calcUnsortedSegmentCrosses(segment, y, pixel_height, &unsorted_buf);

        std.mem.sort(CrossWithT, events, {}, struct {
            fn f(_: void, a: CrossWithT, b: CrossWithT) bool {
                return a.t < b.t;
            }
        }.f);

        for (events) |ev| {
            try crosses.appendBounded(ev.cross);
        }
    }

    const CrossWithT = struct {
        t: f32,
        cross: PixelCross,
    };

    fn calcUnsortedSegmentCrosses(segment: Action, y: f32, pixel_height: f32, events_buf: []CrossWithT) []CrossWithT {
        var events = std.ArrayList(CrossWithT).initBuffer(events_buf);

        const Case = struct {
            y: f32,
            how_map: [2]PixelCross.How,
        };

        const cases: []const Case = &.{
            .{ .y = y, .how_map = .{ .leave_top, .enter_top } },
            .{ .y = y + pixel_height, .how_map = .{ .enter_bottom, .leave_bottom } },
        };

        for (cases) |case| switch (segment) {
            .line => |line| {
                if (lineXForY(line, case.y)) |res| {
                    const x, const t = res;
                    const slope_positive = slopePositive(line);
                    events.appendBounded(.{
                        .t = t,
                        .cross = .{
                            .x_pos = x,
                            .how = case.how_map[@intFromBool(slope_positive)],
                        },
                    }) catch unreachable;
                }
            },
            .quad_bezier => |qb| {
                const ts = quadBezierTForY(qb, case.y) orelse continue;
                for (ts) |t| {
                    if (t < 0 or t > 1) continue;

                    const dir = quadBezierDirAtT(qb, t);
                    if (@abs(dir[1]) < 1e-6) continue;
                    const slope_positive = dir[1] > 0;

                    events.appendBounded(.{
                        .t = t,
                        .cross = .{
                            .x_pos = quadBezierXAtT(qb, t),
                            .how = case.how_map[@intFromBool(slope_positive)],
                        },
                    }) catch unreachable;
                }
            },
            .cubic_bezier => |c| {
                const ts = cubicBezierTForY(c, case.y);
                for (ts.buf[0..ts.len]) |t| {
                    if (t < 0 or t > 1) continue;

                    const dir = cubicBezierDirAtT(c, t);
                    if (@abs(dir[1]) < 1e-6) continue;
                    const slope_positive = dir[1] > 0;

                    events.appendBounded(.{
                        .t = t,
                        .cross = .{
                            .x_pos = cubicBezierXAtT(c, t),
                            .how = case.how_map[@intFromBool(slope_positive)],
                        },
                    }) catch unreachable;
                }
            },
            .arc => |arc| {
                const angles = ellipseAnglesForY(arc, case.y) orelse continue;
                for (angles) |theta| {
                    if (!angleOnArc(arc, theta)) continue;

                    const dir = arcDirAtTheta(arc, theta);
                    if (@abs(dir[1]) < 1e-6) continue;
                    const slope_positive = dir[1] > 0;

                    const offs = if (arc.delta_theta >= 0)
                        theta - arc.start_theta
                    else
                        arc.start_theta - theta;

                    events.appendBounded(.{
                        .t = @mod(offs, std.math.tau),
                        .cross = .{
                            .x_pos = arcXAtTheta(arc, theta),
                            .how = case.how_map[@intFromBool(slope_positive)],
                        },
                    }) catch unreachable;
                }
            },
        };

        return events.items;
    }

    const WindingChangeIter = struct {
        crosses: []const PixelCross,
        idx: usize,
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

    fn slopePositive(l: Line) bool {
        const right = sphtud.math.Vec2{ 1, 0 };
        return sphtud.math.cross2(right, l.dir()) > 0;
    }

    test "slopePositive" {
        try std.testing.expectEqual(true, slopePositive(.{ .a = .{ 0, 0 }, .b = .{ 1, 1 } }));
        try std.testing.expectEqual(false, slopePositive(.{ .a = .{ 0, 0 }, .b = .{ 0, 0 } }));
        try std.testing.expectEqual(false, slopePositive(.{ .a = .{ 0, 0 }, .b = .{ 1, -1 } }));
    }

    fn lineXForY(l: Line, y: f32) ?struct { f32, f32 } {
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

        return .{ std.math.lerp(l.a[0], l.b[0], t), t };
    }

    test "lineXForY" {
        const res = lineXForY(.{
            .a = .{ 0, 0 },
            .b = .{ 10, 10 },
        }, 5.0) orelse return error.NoPoint;
        try std.testing.expectApproxEqAbs(5.0, res[0], 0.001);
    }

    const Cubic = struct {
        a: f32,
        b: f32,
        c: f32,
        d: f32,
    };

    fn cubicBezierTForY(cb: CubicBezier, y: f32) sphtud.math.CubicSolution(f32) {
        // From wolfram alpha "collect (1-t)^3*a + 3*(1-t)^2*t*b + 3*(1-t)*t^2*c + t^3 * d, t"
        // t^3 (-a + 3b - 3c + d) + t^2 (3a - 6b + 3c) + t (-3a + 3b) + a
        //
        // However the above causes some pretty major numerical instability. If
        // we rewrite as follows we lose a lot less precision (thanks claude)
        const d01 = cb.c1[1] - cb.start[1];
        const d12 = cb.c2[1] - cb.c1[1];
        const d23 = cb.end[1] - cb.c2[1];

        var res = sphtud.math.solveCubic(
            f32,
            (d23 - d12) - (d12 - d01),
            3 * (d12 - d01),
            3 * d01,
            cb.start[1] - y,
        );

        for (res.buf[0..res.len]) |*t| {
            t.* = refineBezierSolution(cb, y, t.*);
        }

        return res;
    }

    fn refineBezierSolution(cb: CubicBezier, y_target: f32, t_init: f32) f32 {
        // F32 solutions are pretty imprecise, but lucky for us we can just
        // walk downhill a few times and call it a day
        var t = t_init;
        for (0..4) |_| {
            const dy = cubicBezierDirAtT(cb, t)[1];
            if (@abs(dy) < 1e-6) break;

            const y = cubicBezierYAtT(cb, t);
            const step = (y - y_target) / dy;
            t -= step;

            if (@abs(step) < 1e-7) break;
        }
        return t;
    }

    fn cubicBezierDirAtT(c: CubicBezier, t: f32) sphtud.math.Vec2 {
        // Derivative from https://en.wikipedia.org/wiki/B%C3%A9zier_curve#Cubic_B%C3%A9zier_curves
        const inv_t: sphtud.math.Vec2 = @splat(1 - t);
        const inv_t_2 = inv_t * inv_t;
        const t_2: sphtud.math.Vec2 = @splat(t * t);
        const t_v: sphtud.math.Vec2 = @splat(t);
        return sphtud.math.Vec2{ 3, 3 } * inv_t_2 * (c.c1 - c.start) + sphtud.math.Vec2{ 6, 6 } * inv_t * t_v * (c.c2 - c.c1) + sphtud.math.Vec2{ 3, 3 } * t_2 * (c.end - c.c2);
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

    fn quadBezierTForY(qb: QuadBezier, y: f32) ?[2]f32 {
        // collect (1-t)^2a + 2(1-t)t*b + t^2c, t
        // (a-2b+c)t^2 + (2b-2a)t + a
        return sphtud.math.solveQuadratic(
            f32,
            qb.start[1] - 2 * qb.c[1] + qb.end[1],
            2 * (qb.c[1] - qb.start[1]),
            qb.start[1] - y,
        );
    }

    fn quadBezierDirAtT(qb: QuadBezier, t: f32) sphtud.math.Vec2 {
        // https://en.wikipedia.org/wiki/B%C3%A9zier_curve#Quadratic_B%C3%A9zier_curves
        const inv_t: sphtud.math.Vec2 = @splat(1 - t);
        const t_v: sphtud.math.Vec2 = @splat(t);
        return sphtud.math.Vec2{ 2, 2 } * inv_t * (qb.c - qb.start) + sphtud.math.Vec2{ 2, 2 } * t_v * (qb.end - qb.c);
    }

    fn quadBezierXAtT(bez: QuadBezier, t: f32) f32 {
        const a = std.math.lerp(bez.start[0], bez.c[0], t);
        const b = std.math.lerp(bez.c[0], bez.end[0], t);

        return std.math.lerp(a, b, t);
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

    const cc = CoordinateConverter{
        .in_width = self.br[0] - self.tl[0],
        .in_height = self.br[1] - self.tl[1],
        .out_width = @floatFromInt(out.width),
        .out_height = @floatFromInt(out.calcHeight()),
    };

    const pixel_height = cc.pixelHeight();

    for (0..out.calcHeight()) |out_y| {
        var sampler: WindingChangeCalculator = undefined;
        sampler.initPinned(
            pixel_height,
            cc.outputToInputY(@floatFromInt(out_y)),
            path,
        );

        const windings = try sampler.calculateWindingChanges();

        var x_idx: usize = 0;
        var winding_count: i32 = 0;
        const px = sphtud.img.RgbF32Pixel{
            .r = color[0],
            .g = color[1],
            .b = color[2],
        };

        for (windings) |winding| {
            const prev_count = winding_count;
            winding_count += winding.change;

            const out_x: i64 = @intFromFloat(cc.inputToOutputX(winding.pos));
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
                },
            }
        }
    }
}

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

pub const PathLineIter = struct {
    contours: Path.Iter,
    segments: ?Contour.Iter,
    current_segment: Action,
    t_idx: usize,
    last: sphtud.math.Vec2,

    const line_segments = 20;

    pub fn init(path: *const Path) PathLineIter {
        return .{
            .contours = path.iter(),
            .segments = null,
            .current_segment = undefined,
            .t_idx = line_segments,
            .last = undefined,
        };
    }

    pub fn next(self: *PathLineIter) ?Line {
        while (true) {
            if (self.t_idx < line_segments) {
                switch (self.current_segment) {
                    .line => |m| {
                        self.t_idx = line_segments;
                        return m;
                    },
                    .cubic_bezier => |bezier| {
                        defer self.t_idx += 1;

                        if (self.t_idx == 0) {
                            self.last = bezier.start;
                        }

                        const t: f32 = 1.0 / @as(f32, line_segments) * @as(f32, @floatFromInt(self.t_idx + 1));

                        const p = sampleCubicBezier(bezier, t);

                        defer self.last = p;
                        return .{
                            .a = self.last,
                            .b = p,
                        };
                    },
                    .quad_bezier => |bezier| {
                        defer self.t_idx += 1;

                        if (self.t_idx == 0) {
                            self.last = bezier.start;
                        }

                        const t: f32 = 1.0 / @as(f32, line_segments) * @as(f32, @floatFromInt(self.t_idx + 1));

                        const p = sampleQuadBezier(bezier, t);

                        defer self.last = p;
                        return .{
                            .a = self.last,
                            .b = p,
                        };
                    },
                    .arc => |arc| {
                        defer self.t_idx += 1;

                        const applier = arc.applier();

                        if (self.t_idx == 0) {
                            self.last = applier.apply(arc.start_theta);
                        }

                        const t: f32 = 1.0 / @as(f32, line_segments) * @as(f32, @floatFromInt(self.t_idx + 1));
                        const theta = arc.start_theta + arc.delta_theta * t;

                        const val = applier.apply(theta);

                        defer self.last = val;
                        return .{
                            .a = self.last,
                            .b = val,
                        };
                    },
                }
            }

            if (self.segments) |*s| blk: {
                self.current_segment = (s.next() orelse break :blk).*;
                self.t_idx = 0;
                continue;
            }

            const segments = self.contours.next() orelse return null;
            self.segments = segments.iter();
        }
    }

    fn sampleCubicBezier(bezier: CubicBezier, t: f32) Point {
        const t_v = sphtud.math.Vec2{ t, t };
        const a = std.math.lerp(bezier.start, bezier.c1, t_v);
        const b = std.math.lerp(bezier.c1, bezier.c2, t_v);
        const c = std.math.lerp(bezier.c2, bezier.end, t_v);

        const d = std.math.lerp(a, b, t_v);
        const e = std.math.lerp(b, c, t_v);

        return std.math.lerp(d, e, t_v);
    }

    fn sampleQuadBezier(bezier: QuadBezier, t: f32) Point {
        const t_v = sphtud.math.Vec2{ t, t };
        const a = std.math.lerp(bezier.start, bezier.c, t_v);
        const b = std.math.lerp(bezier.c, bezier.end, t_v);

        return std.math.lerp(a, b, t_v);
    }
};

test {
    _ = WindingChangeCalculator;
    std.testing.refAllDecls(@This());
}
