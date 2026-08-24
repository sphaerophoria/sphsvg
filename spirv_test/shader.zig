const std = @import("std");
const sphtud = @import("sphtud");
const render_util = @import("render_util.zig");

const Line = render_util.Line;
const Vec2 = sphtud.math.Vec2;
const CubicBezier = render_util.CubicBezier;
const QuadBezier = render_util.QuadBezier;
const Arc = render_util.Arc;

const Output = extern struct {
    x: f32,
    // FIXME: Y might be implicit
    y: f32,
    in_typ: u32,
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

const math = std.math;
const mem = std.mem;


export fn main() callconv(.{ .spirv_kernel = .{.x = 1, .y = 1, .z = 1} }) void {
    const val = std.spirv.global_invocation_id[0];
    const y_u = std.spirv.global_invocation_id[1];
    const y: f32 = @floatFromInt(y_u);

    // FIXME: Set upper bound
    //if (val > num_segments) return;

    const item = items.data[val];
    const crosses, const output_size: u8 = blk: switch (item.arg_type) {
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

            break :blk .{ render_util.lineCrosses(line, y), 1 };
        },
        1 => {
            const qb = QuadBezier {
                .start = .{
                    f32_storage.data[item.arg_offs + 0],
                    f32_storage.data[item.arg_offs + 1],
                },
                .c = .{
                    f32_storage.data[item.arg_offs + 2],
                    f32_storage.data[item.arg_offs + 3],
                },
                .end = .{
                    f32_storage.data[item.arg_offs + 4],
                    f32_storage.data[item.arg_offs + 5],
                },
            };

            break :blk .{ render_util.quadBezierCrosses(qb, y), 2 };
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
            break :blk .{ render_util.cubicBezierCrosses(c, y), 3 };
        },
        3 => {
            //const arc = Arc {
            //    .rot = f32_storage.data[item.arg_offs + 0],
            //    .rx = f32_storage.data[item.arg_offs + 1],
            //    .ry = f32_storage.data[item.arg_offs + 2],
            //    .center = .{
            //        f32_storage.data[item.arg_offs + 3],
            //        f32_storage.data[item.arg_offs + 4],
            //    },
            //    .start_theta = f32_storage.data[item.arg_offs + 5],
            //    .delta_theta = f32_storage.data[item.arg_offs + 6],
            //};

            //break :blk .{ render_util.arcCrosses(arc, y), 2 };
            break :blk .{ render_util.CrossSolutionArray.init, 2 };
        },
        else => {
            break :blk .{ render_util.CrossSolutionArray.init, 0 };
        },
    };

    for (0..crosses.len) |i| {
        const cross = crosses.buf[i];
        output.data[outputs_per_line.* * y_u + item.out_offs + i] = .{
            .x = cross.x,
            .y = y,
            .in_typ = item.arg_type,
            .positive = @intFromBool(cross.slope_positive),
            .valid = 1,
        };
    }
    for (crosses.len..output_size) |i| {
        output.data[outputs_per_line.* * y_u + item.out_offs + i].valid = 0;
    }

    // FIXME: Sort solutions by t

}

