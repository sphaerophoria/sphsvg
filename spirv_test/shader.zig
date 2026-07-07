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

