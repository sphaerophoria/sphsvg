const sphtud = @import("sphtud");
const std = @import("std");
const PathParser = @import("PathParser.zig");
const xyt = sphtud.render.xyt_program;

tl: Point,
br: Point,
prog: xyt.Program(Uniforms),
scratch_gl: *sphtud.render.GlAlloc,

const Renderer = @This();

const Uniforms = struct {
    color: sphtud.math.Vec3,
    transform: sphtud.math.Mat3x3,
};

pub const Path = sphtud.util.RuntimeSegmentedList(Action);
// FIXME: Conversion + real type for renderer
pub const Point = sphtud.math.Vec2;

const CubicBezier = struct {
    c1: Point,
    c2: Point,
    end: Point,
};

const QuadBezier = struct {
    c: Point,
    end: Point,
};


const Arc = struct {
    // Start has to be on the elpise
    rot: f32,
    rx: f32,
    ry: f32,
    center: Point,
    start_theta: f32, // Note semi-duplicated with cursor :)
    delta_theta: f32,
};
pub const Action = union(enum) {
    move: Point,
    line_to: Point,
    cubic_bezier: CubicBezier,
    quad_bezier: QuadBezier,
    arc: Arc,
    close,
};

pub fn renderPath(self: *Renderer, scratch: std.mem.Allocator, path: Path, color: sphtud.math.Vec3) !void {
    //var cursor = Point { .x = 0, .y = 0 };
    // path points are defined in svg space
    // gl points [-1, 1]

    if (path.len == 0) return;

    var cursor: Point = .{0, 0};
    var cursor_start: Point = cursor;
    if (path.get(0) == .move) {
        cursor_start = path.get(0).move;
    }

    var buf_data: std.ArrayList(xyt.Vertex) = .empty;
    try buf_data.append(scratch, .{ .vPos = cursor_start, });

    var it = path.iter();
    while (it.next()) |inst| switch (inst.*) {
        .move => |m| {
            if (buf_data.items.len > 0) {
                try self.renderVertexList(buf_data.items, color);
                buf_data.clearRetainingCapacity();
                try buf_data.append(scratch, .{ .vPos = .{ m[0], m[1] }, });
            }
            cursor = m;

        },
        .line_to => |m| {
            cursor = m;
            try buf_data.append(scratch, .{ .vPos = .{ cursor[0], cursor[1] }, });
        },
        .cubic_bezier => |bezier| {
            const start: sphtud.math.Vec2 = .{ cursor[0], cursor[1] };
            const c1: sphtud.math.Vec2 = .{ bezier.c1[0], bezier.c1[1] };
            const c2: sphtud.math.Vec2 = .{ bezier.c2[0], bezier.c2[1] };
            const end: sphtud.math.Vec2 = .{ bezier.end[0], bezier.end[1] };

            for (0..10) |i| {
                const t: sphtud.math.Vec2 = @splat(0.1 * @as(f32, @floatFromInt(i + 1)));

                const a = std.math.lerp(start, c1, t);
                const b = std.math.lerp(c1, c2, t);
                const c = std.math.lerp(c2, end, t);

                const d = std.math.lerp(a, b, t);
                const e = std.math.lerp(b, c, t);

                const p = std.math.lerp(d, e, t);
                try buf_data.append(scratch, .{ .vPos = p });
            }

            cursor = bezier.end;
        },
        .quad_bezier => {
            unreachable;
    },
        .arc => |arc| {
            for (0..10) |i| {
                const t: f32 = 0.1 * @as(f32, @floatFromInt(i + 1));
                const theta = arc.start_theta + arc.delta_theta * t;

                const rotation_mat = sphtud.math.Transform.rotate(arc.rot);
                // FIXME: Maybe mat2x2 apply would be nice here
                var val = rotation_mat.apply(.{arc.rx * @cos(theta), arc.ry * @sin(theta), 1});
                val += .{ arc.center[0], arc.center[1], 0 };

                try buf_data.append(scratch, .{ .vPos = .{val[0], val[1]} });
            }
            const last = buf_data.items[buf_data.items.len-1];
            cursor[0] = last.vPos[0];
            cursor[1] = last.vPos[1];

        },
        .close => {
            cursor = cursor_start;
            try buf_data.append(scratch, .{ .vPos = .{ cursor[0], cursor[1] }, });
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

    self.prog.renderLineStrip(s, .{
        .color = color,
        .transform = transform.inner,
    });
}
