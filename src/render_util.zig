const std = @import("std");
const math = std.math;
const mem = std.mem;
const sphtud = @import("sphtud");
const builtin = @import("builtin");

pub const Point = sphtud.math.Vec2;
pub const Line = sphtud.geometry.Line2;

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

pub const ContourSegment = union(enum) {
    line: Line,
    cubic_bezier: CubicBezier,
    quad_bezier: QuadBezier,
    arc: Arc,
};

pub const CrossSolution = struct {
    x: f32,
    t: f32,
    slope_positive: bool,
};

pub fn lineCross(l: Line, y: f32) ?CrossSolution {
    const min_y = @min(l.a[1], l.b[1]);
    const max_y = @max(l.a[1], l.b[1]);

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

    return .{
        .x = std.math.lerp(l.a[0], l.b[0], t),
        .t = t,
        .slope_positive = lineSlopePositive(l),
    };
}

// This is not a particularly sane API on it's own, but it matches the shape of
// all the other solvers which is a nice convenience
pub fn lineCrosses(l: Line, y: f32) CrossSolutionArray {
    var ret = CrossSolutionArray.init;
    if (lineCross(l, y)) |res| {
        ret.append(res);
    }
    return ret;
}

test "lineCross" {
    const res = lineCross(.{
        .a = .{ 0, 0 },
        .b = .{ 10, 10 },
    }, 5.0) orelse return error.NoPoint;
    try std.testing.expectApproxEqAbs(5.0, res.x, 0.001);
}

fn lineSlopePositive(l: Line) bool {
    const right = sphtud.math.Vec2{ 1, 0 };
    return sphtud.math.cross2(right, l.dir()) > 0;
}

pub const CrossSolutionArray = struct {
    buf: [3]CrossSolution,
    len: usize,

    pub const init: CrossSolutionArray = .{
        .buf = undefined,
        .len = 0,
    };

    pub fn append(self: *CrossSolutionArray, sol: CrossSolution) void {
        self.buf[self.len] = sol;
        self.len += 1;
    }
};

pub fn quadBezierCrosses(qb: QuadBezier, y: f32) CrossSolutionArray {
    var ret = CrossSolutionArray.init;
    const ts = quadBezierTForY(qb, y) orelse return ret;
    for (ts) |t| {
        if (t < 0 or t > 1) continue;

        const dir = quadBezierDirAtT(qb, t);
        if (@abs(dir[1]) < 1e-6) continue;
        const slope_positive = dir[1] > 0;

        ret.append(.{
            .slope_positive = slope_positive,
            .x = quadBezierXAtT(qb, t),
            .t = t,
        });
    }

    return ret;
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

pub fn cubicBezierCrosses(c: CubicBezier, y: f32) CrossSolutionArray {
    var ret: CrossSolutionArray = .init;
    const ts = cubicBezierTForY(c, y);
    for (0..ts.len) |i| {
        const t = ts.buf[i];
        if (t < 0 or t > 1) continue;

        const dir = cubicBezierDirAtT(c, t);
        if (@abs(dir[1]) < 1e-6) continue;

        ret.append(.{
            .x = cubicBezierXAtT(c, t),
            .t = t,
            .slope_positive = dir[1] > 0,
        });
    }

    return ret;
}

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

    for (0..res.len) |i| {
        res.buf[i] = refineBezierSolution(cb, y, res.buf[i]);
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

fn atan2(y: f32, x: f32) f32 {
    if (builtin.target.os.tag == .opengl) {
        return asm volatile (
            \\%inst_set = OpExtInstImport "GLSL.std.450"
            \\%ret = OpExtInst %Result %inst_set 25 %y %x
            : [ret] "" (-> f32),
            : [Result] "t" (f32),
              [x] "" (x),
              [y] "" (y),
        );
    } else {
        return std.math.atan2(y, x);
    }
}

pub fn arcCrosses(arc: Arc, y: f32 ) CrossSolutionArray {
    var ret = CrossSolutionArray.init;

    const angles = ellipseAnglesForY(arc, y) orelse return ret;
    for (angles) |theta| {
        if (!angleOnArc(arc, theta)) continue;

        const dir = arcDirAtTheta(arc, theta);
        if (@abs(dir[1]) < 1e-6) continue;

        const offs = if (arc.delta_theta >= 0)
            theta - arc.start_theta
        else
            arc.start_theta - theta;

        ret.append(.{
            .t = @mod(offs, std.math.tau),
            .x = arcXAtTheta(arc, theta),
            .slope_positive = dir[1] > 0,
        });
    }

    return ret;
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

    const points = sphtud.geometry.rayEllipseIntersection(ray, ellipse);
    if (points.len < 2) return null;

    // ellipseToCircle maps an ellipse point to (cos θ, sin θ) on the unit circle.
    const to_circle = sphtud.geometry.ellipseToCircle(ellipse);
    const p1 = to_circle.apply2(points.buf[0]);
    const p2 = to_circle.apply2(points.buf[1]);
    return .{
        atan2(p1[1], p1[0]),
        atan2(p2[1], p2[0]),
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
