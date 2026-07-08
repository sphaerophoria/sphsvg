const std = @import("std");

const Output = extern struct {
    x: f32,
    // FIXME: Y might be implicit
    y: f32,
    positive: u16,
    valid: u16,
};
const F32Array = @SpirvType(.{ .runtime_array = f32 });
const OutputArray = @SpirvType(.{ .runtime_array = Output });

const F32Buffer = extern struct {
    data: F32Array,
};

const OutputBuffer = extern struct {
    data: OutputArray,
};

const Item = extern struct {
    arg_offs: u32,
    arg_type: u32,
    out_offs: u32,
};

const ItemArray = @SpirvType(.{ .runtime_array = Item });

const ItemBuffer = extern struct {
    data: ItemArray,
};

comptime {
    std.debug.assert(@offsetOf(Item, "arg_offs") == 0);
    std.debug.assert(@offsetOf(Item, "arg_type") == 4);
    std.debug.assert(@offsetOf(Item, "out_offs") == 8);
}

const f32_storage = @extern(*addrspace(.storage_buffer) F32Buffer, .{
    .name = "f32_storage",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

const items = @extern(*addrspace(.storage_buffer) ItemBuffer, .{
    .name = "items",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});

const output = @extern(*addrspace(.storage_buffer) OutputBuffer, .{
    .name = "output",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 2 } },
});

const outputs_per_line = @extern(*addrspace(.uniform) u32, .{
    .name = "outputs_per_line",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

export fn main() callconv(.{ .spirv_kernel = .{.x = 1, .y = 1, .z = 1} }) void {
    const val = std.spirv.global_invocation_id[0];
    const y_u = std.spirv.global_invocation_id[1];
    const y: f32 = @floatFromInt(y_u);

    // FIXME: Set upper bound
    //if (val > num_segments) return;

    const item = items.data[val];
    switch (item.arg_type) {
        // FIXME: named type
        // line
        0 => {
            const line = Line {
                .a = .{
                    f32_storage.data[item.arg_offs + 0],
                    f32_storage.data[item.arg_offs + 1],
                },
                .b = .{
                    f32_storage.data[item.arg_offs + 2],
                    f32_storage.data[item.arg_offs + 3],
                },
            };
            const x, const t, const valid = lineXForY(line, y);
            if (valid) {
                _ = t;
                const slope_positive = slopePositive(line);
                output.data[outputs_per_line.* * y_u + item.out_offs]  = .{.x = x, .y = y, .positive = if (slope_positive) 1 else 0, .valid = 1};
            } else {
                output.data[outputs_per_line.* * y_u + item.out_offs].valid = 0;
            }
        },
        2 => {
            const c = CubicBezier {
                .start = .{
                    f32_storage.data[item.arg_offs + 0],
                    f32_storage.data[item.arg_offs + 1],
                },
                .c1 = .{
                    f32_storage.data[item.arg_offs + 2],
                    f32_storage.data[item.arg_offs + 3],
                },
                .c2 = .{
                    f32_storage.data[item.arg_offs + 4],
                    f32_storage.data[item.arg_offs + 5],
                },
                .end = .{
                    f32_storage.data[item.arg_offs + 6],
                    f32_storage.data[item.arg_offs + 7],
                },
            };

            const ts = cubicBezierTForY(c, y);
            for (0..ts.len) |i| {
                const t = switch (i) {
                    0 => ts.a,
                    1 => ts.b,
                    2 => ts.c,
                    else => unreachable,
                };
                if (t < 0 or t > 1) continue;

                const dir = cubicBezierDirAtT(c, t);
                if (@abs(dir[1]) < 1e-6) continue;
                const slope_positive = dir[1] > 0;

                output.data[outputs_per_line.* * y_u + item.out_offs + i]  = .{.x = cubicBezierXAtT(c, t), .y = y, .positive = if (slope_positive) 1 else 0, .valid = 1};
                //events.appendBounded(.{
                //    .t = t,
                //    .cross = .{
                //        .x_pos = cubicBezierXAtT(c, t),
                //        .how = case.how_map[@intFromBool(slope_positive)],
                //    },
                //}) catch unreachable;
            }
        },
        else => {},
    }

}

fn lineXForY(l: Line, y: f32) struct { f32, f32, bool } {
    const min_y = @min(l.a[1], l.b[1]);
    const max_y = @max(l.a[1], l.b[1]);

    const invalid = .{undefined, undefined, false};
    if (y < min_y or y > max_y) return invalid;

    const eps = 1e-7;

    //y = lerp(start, end, t);
    //y = l.a[1] + t*(l.b[1] - l.a[1]);
    //(y - l.a[1]) / (l.b[1] - l.a[1]) = t
    //x = l.a[0] + t*(l.b[0] - l.a[0]);
    const div = (l.b[1] - l.a[1]);
    // Relatively horizontal line. This cannot contribute to our winding
    // counts, so we just ignore
    if (@abs(div) < eps) return invalid;
    const t = (y - l.a[1]) / div;

    return .{ std.math.lerp(l.a[0], l.b[0], t), t, true };
}

pub const Line = struct {
    a: @Vector(2, f32),
    b: @Vector(2, f32),

    pub fn dir(self: Line) Vec2 {
        return normalize(self.b - self.a);
    }
};


fn slopePositive(l: Line) bool {
    const right = @Vector(2, f32){ 1, 0 };
    return cross2(right, l.dir()) > 0;
}

const Vec2 = @Vector(2, f32);
pub fn cross2(a: Vec2, b: Vec2) f32 {
    return a[0] * b[1] - a[1] * b[0];
}

pub fn normalize(in: anytype) @TypeOf(in) {
    const l: @TypeOf(in) = @splat(length(in));
    return in / l;
}

pub fn length(in: anytype) f32 {
    return @sqrt(length2(in));
}

pub fn length2(in: anytype) f32 {
    return @reduce(.Add, in * in);
}

pub const CubicBezier = struct {
    start: Vec2,
    c1: Vec2,
    c2: Vec2,
    end: Vec2,
};

fn cubicBezierTForY(cb: CubicBezier, y: f32) CubicSolution(f32) {
    // From wolfram alpha "collect (1-t)^3*a + 3*(1-t)^2*t*b + 3*(1-t)*t^2*c + t^3 * d, t"
    // t^3 (-a + 3b - 3c + d) + t^2 (3a - 6b + 3c) + t (-3a + 3b) + a
    //
    // However the above causes some pretty major numerical instability. If
    // we rewrite as follows we lose a lot less precision (thanks claude)
    const d01 = cb.c1[1] - cb.start[1];
    const d12 = cb.c2[1] - cb.c1[1];
    const d23 = cb.end[1] - cb.c2[1];

    const res = solveCubic(
        f32,
        (d23 - d12) - (d12 - d01),
        3 * (d12 - d01),
        3 * d01,
        cb.start[1] - y,
    );

    //for (res.buf[0..res.len]) |*t| {
    //    t.* = refineBezierSolution(cb, y, t.*);
    //}

    return res;
}

pub fn CubicSolution(comptime T: type) type {
    return struct {
        const empty: @This() = .{
            .a = undefined,
            .b = undefined,
            .c = undefined,
            .len = 0,
        };
        a: T,
        b: T,
        c: T,
        len: u8,
    };
}

pub fn DepressedCubic(comptime T: type) type {
    return struct {
        p: T,
        q: T,
        shift: T,
    };
}

const polynomial_eps: f32 = 1e-6;

pub fn solveLinear(comptime T: type, a: T, b: T) T {
    // ax + b = 0
    return -b / a;
}

pub fn solveQuadratic(comptime T: type, a: T, b: T, c: T) struct {T, T, bool } {
    if (a < polynomial_eps) {
        const res = solveLinear(T, b, c);
        return .{ res, res, true };
    }
    const disc = b * b - 4.0 * a * c;
    if (disc < 0) return .{undefined, undefined, false};
    const sd = @sqrt(disc);
    return .{ (-b + sd) / (2.0 * a), (-b - sd) / (2.0 * a), true};
}

pub fn calcCubicDiscriminant(comptime T: type, p: T, q: T) T {
    // Discriminant of t^3 + p*t + q = 0.
    return -4.0 * p * p * p - 27.0 * q * q;
}

pub fn solveCubicViete(comptime T: type, p: T, q: T) CubicSolution(T) {
    // Three real roots of t^3 + p*t + q = 0 via the trigonometric method.
    // Caller must guarantee disc > 0 (which implies p < 0).
    //
    // https://en.wikipedia.org/wiki/Cubic_equation#Trigonometric_solution_for_three_real_roots
    const snp3 = @sqrt(-p / 3.0); //Sqrt Negative P over 3
    const inv_snp3 = 1 / snp3;
    // Clamp guards against floating point noise pushing the argument just
    // outside [-1, 1] near disc ≈ 0, which would make acos return NaN.
    const arg = std.math.clamp(3 * q / (2 * p) * inv_snp3, -1.0, 1.0);
    const theta = std.math.acos(arg) / 3.0;
    const two_pi_3 = 2.0 * std.math.pi / 3.0;

    return .{
        .a = 2 * snp3 * @cos(theta - two_pi_3 * @as(T, @floatFromInt(0))),
        .b = 2 * snp3 * @cos(theta - two_pi_3 * @as(T, @floatFromInt(1))),
        .c = 2 * snp3 * @cos(theta - two_pi_3 * @as(T, @floatFromInt(2))),
        .len = 3,
    };
}

pub fn solveCubicCardano(comptime T: type, p: T, q: T) CubicSolution(T) {
    // Single real root of t^3 + p*t + q = 0. Caller must guarantee disc < 0.
    // https://en.wikipedia.org/wiki/Cubic_equation#Cardano's_formula
    const sd = @sqrt(q * q / 4.0 + p * p * p / 27.0);
    return .{
        .a = std.math.cbrt(-q / 2.0 + sd) + std.math.cbrt(-q / 2.0 - sd),
        .b = undefined,
        .c = undefined,
        .len = 1,
    };
}

pub fn solveDepressedCubic(comptime T: type, p: T, q: T) CubicSolution(T) {
    // t^3 + p*t + q = 0
    var ret = CubicSolution(T).empty;

    const disc = calcCubicDiscriminant(T, p, q);
    if (disc > polynomial_eps) return solveCubicViete(T, p, q);
    if (disc < -polynomial_eps) return solveCubicCardano(T, p, q);

    // https://en.wikipedia.org/wiki/Cubic_equation#Multiple_root
    if (@abs(p) < polynomial_eps) {
        // 0 is a triple root
        ret.a = 0;
        ret.len = 1;
        return ret;
    }

    ret.a = 3.0 * q / p;
    ret.b = -3.0 * q / (2.0 * p);
    ret.len = 2;
    return ret;
}

pub fn toDepressedCubic(comptime T: type, a: T, b: T, c: T, d: T) DepressedCubic(T) {
    // https://en.wikipedia.org/wiki/Cubic_equation#Depressed_cubic
    // Normalize ax^3 + bx^2 + cx + d by a, then substitute x = t - b/(3a) to
    // remove the t^2 term, yielding t^3 + p*t + q = 0.
    const bn = b / a;
    const cn = c / a;
    const dn = d / a;
    return .{
        .p = cn - bn * bn / 3.0,
        .q = 2.0 * bn * bn * bn / 27.0 - bn * cn / 3.0 + dn,
        .shift = bn / 3.0,
    };
}

pub fn fromDepressedSolution(comptime T: type, sol: CubicSolution(T), shift: T) CubicSolution(T) {
    var ret = sol;
    ret.a -= shift;
    ret.b -= shift;
    ret.c -= shift;
    return ret;
}

pub fn solveCubic(comptime T: type, a: T, b: T, c: T, d: T) CubicSolution(T) {
    // ax^3 + bx^2 + cx + d = 0

    if (@abs(a) >= polynomial_eps) {
        const dep = toDepressedCubic(T, a, b, c, d);
        const sol = solveDepressedCubic(T, dep.p, dep.q);
        return fromDepressedSolution(T, sol, dep.shift);
    }

    var ret = CubicSolution(T).empty;

    if (@abs(b) > polynomial_eps) {
        const roots = solveQuadratic(T, b, c, d);
        if (!roots[2]) return ret;
        ret.a = roots[0];
        ret.b = roots[1];
        ret.len = 2;
    }

    if (@abs(c) > polynomial_eps) {
        ret.a = solveLinear(T, c, d);
        ret.len = 1;
        return ret;
    }

    return ret;
}


fn cubicBezierDirAtT(c: CubicBezier, t: f32) Vec2 {
    // Derivative from https://en.wikipedia.org/wiki/B%C3%A9zier_curve#Cubic_B%C3%A9zier_curves
    const inv_t: Vec2 = @splat(1 - t);
    const inv_t_2 = inv_t * inv_t;
    const t_2: Vec2 = @splat(t * t);
    const t_v: Vec2 = @splat(t);
    return Vec2{ 3, 3 } * inv_t_2 * (c.c1 - c.start) + Vec2{ 6, 6 } * inv_t * t_v * (c.c2 - c.c1) + Vec2{ 3, 3 } * t_2 * (c.end - c.c2);
}

fn cubicBezierXAtT(bez: CubicBezier, t: f32) f32 {
    const a = std.math.lerp(bez.start[0], bez.c1[0], t);
    const b = std.math.lerp(bez.c1[0], bez.c2[0], t);
    const c = std.math.lerp(bez.c2[0], bez.end[0], t);

    const d = std.math.lerp(a, b, t);
    const e = std.math.lerp(b, c, t);

    return std.math.lerp(d, e, t);
}
