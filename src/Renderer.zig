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

pub const Path = sphtud.util.RuntimeSegmentedList(Action);
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

pub const Line = struct {
    start: Point,
    end: Point,
};

pub const Action = union(enum) {
    line: Line,
    cubic_bezier: CubicBezier,
    quad_bezier: QuadBezier,
    arc: Arc,
};

const RowCurvePoint = struct {
    x_pos: i64,
    entering: bool,
};

// FIXME: Duplicated with ttf renderer
pub fn findBezierTForY(p1: f32, p2: f32, p3: f32, y: f32) [2]f32 {
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

fn findRowCurvePoints(buf: []RowCurvePoint, curves: sphtud.util.RuntimeSegmentedList(Action), y: i64) ![]RowCurvePoint {
    var ret = std.ArrayList(RowCurvePoint).initBuffer(buf);

    var it = curves.iter();

    while (it.next()) |curve| {
        switch (curve.*) {
            .line => |l| {
                const a_f = l.start;
                const b_f = l.end;
                const y_f: f32 = @floatFromInt(y);

                if (l.end[1] == l.start[1]) continue;
                const t = (y_f - a_f[1]) / (b_f[1] - a_f[1]);

                if (!(t >= 0.0 and t <= 1.0)) {
                    continue;
                }

                const x = std.math.lerp(a_f[0], b_f[0], t);

                const x_pos_i: i64 = @intFromFloat(@round(x));
                const entering = l.start[1] < l.end[1];

                try ret.appendBounded(.{ .entering = entering, .x_pos = x_pos_i });
            },
            .quad_bezier => |b| {
                const a_f: @Vector(2, f32) = b.start;
                const b_f: @Vector(2, f32) = b.c;
                const c_f: @Vector(2, f32) = b.end;

                const ts = findBezierTForY(a_f[1], b_f[1], c_f[1], @floatFromInt(y));

                for (ts, 0..) |t, i| {
                    if (!(t >= 0.0 and t <= 1.0)) {
                        continue;
                    }
                    const tangent_line = quadBezierTangentLine(a_f, b_f, c_f, t);

                    const eps = 1e-7;
                    const at_apex = @abs(tangent_line.a[1] - tangent_line.b[1]) < eps;
                    const at_end = t < eps or @abs(t - 1.0) < eps;
                    const moving_up = tangent_line.a[1] < tangent_line.b[1] or b.start[1] < b.end[1];

                    // If we are at the apex, and at the very edge of a curve,
                    // we have to be careful. In this case we can only count
                    // one of the enter/exit events as we are only half of the
                    // parabola.
                    //
                    // U -> enter/exit
                    // \_ -> enter
                    // _/ -> exit
                    //  _
                    // / -> enter
                    // _
                    //  \-> exit

                    // The only special case is that we are at the apex, and at
                    // the end of the curve. In this case we only want to
                    // consider one of the two points. Otherwise we just ignore
                    // the apex as it's an immediate enter/exit. I.e. useless
                    //
                    // This boils down to the following condition
                    if (at_apex and (!at_end or i == 1)) continue;

                    const x_f = sampleQuadBezierCurve(a_f, b_f, c_f, t)[0];
                    const x_px: i64 = @intFromFloat(@round(x_f));
                    try ret.appendBounded(.{
                        .entering = moving_up,
                        .x_pos = x_px,
                    });
                }
            },
            .cubic_bezier, .arc => {
                // Ellipse is defined by
            },
        }
    }

    return ret.items;
}

pub fn renderPathToImage(self: *Renderer, scratch: sphtud.alloc.LinearAllocator, path: Path, color: sphtud.math.Vec3, out: sphtud.img.Image) !void {
    if (path.len == 0) return;

    std.debug.assert(out.width == @as(usize, @intFromFloat(self.br[0] - self.tl[0])));
    std.debug.assert(out.calcHeight() == @as(usize, @intFromFloat(self.br[1] - self.tl[1])));

    var y: i64 = 0;
    const height = out.calcHeight();

    const buf = try scratch.allocator().alloc(RowCurvePoint, path.len);

    while (y < height) {
        defer y += 1;

        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const points = try findRowCurvePoints(buf, path, y);
        for (points) |p| {
            switch (out.data) {
                inline else => |d| {
                    const px = sphtud.img.RgbF32Pixel {
                        .r = color[0],
                        .g = color[1],
                        .b = color[2],
                    };
                    d.write(@intCast(y * out.width + p.x_pos), .from(px));
                },
            }
        }
    }
}

pub fn renderPath(self: *Renderer, scratch: std.mem.Allocator, path: Path, color: sphtud.math.Vec3) !void {
    if (path.len == 0) return;

    var buf_data: std.ArrayList(xyt.Vertex) = .empty;

    var it = path.iter();
    while (it.next()) |inst| switch (inst.*) {
        .line => |m| {
            try buf_data.append(scratch, .{ .vPos = m.start, });
            try buf_data.append(scratch, .{ .vPos = m.end, });
        },
        .cubic_bezier => |bezier| {
            const start = bezier.start;
            const c1 = bezier.c1;
            const c2 = bezier.c2;
            const end = bezier.end;

            var last = bezier.start;
            for (0..bezier_resolution) |i| {
                const t: sphtud.math.Vec2 = @splat(1.0 / @as(f32,bezier_resolution) * @as(f32, @floatFromInt(i + 1)));

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

            var last = transform.apply(.{arc.rx * @cos(arc.start_theta), arc.ry * @sin(arc.start_theta), 1});

            for (0..bezier_resolution) |i| {
                const t: f32 = 1.0 / @as(f32, bezier_resolution) * @as(f32, @floatFromInt(i + 1));
                const theta = arc.start_theta + arc.delta_theta * t;

                const val = transform.apply(.{arc.rx * @cos(theta), arc.ry * @sin(theta), 1});

                try buf_data.append(scratch, .{ .vPos = .{last[0], last[1]} });
                try buf_data.append(scratch, .{ .vPos = .{val[0], val[1]} });
                last = val;
            }
        },
    };

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
        .then(.scale(2.0 / width, -2.0 / height))
    ;

    self.prog.renderLines(s, .{
        .color = color,
        .transform = transform.inner,
    });
}
