const sphtud = @import("sphtud");
const std = @import("std");
const PathParser = @import("PathParser.zig");
const xyt = sphtud.render.xyt_program;

tl: Point,
br: Point,
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
