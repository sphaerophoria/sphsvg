const std = @import("std");
const sphtud = @import("sphtud");
const render_util = @import("render_util.zig");

const Line = render_util.Line;
const Vec2 = sphtud.math.Vec2;
const CubicBezier = render_util.CubicBezier;
const QuadBezier = render_util.QuadBezier;
const Arc = render_util.Arc;

const Output = extern struct {
    x_positions: [6]f32,
    how: [6]u8,
    ts: [6]f32,
    crosses_len: u8,
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

const outputs_per_line = @extern(*addrspace(.constant) u32, .{
    .name = "outputs_per_line",
    .decoration = .{ .location = 0 },
});

const scanline_height = @extern(*addrspace(.constant) f32, .{
    .name = "scanline_height",
    .decoration = .{ .location = 1 },
});

const math = std.math;
const mem = std.mem;

//fn atan2(x: f32, y: f32) f32 {
//    return asm volatile (
//        \\%inst_set = OpExtInstImport "GLSL.std.450"
//        \\%ret = OpExtInst %Result %inst_set 25 %y %x
//        : [ret] "" (-> f32),
//        : [Result] "t" (f32),
//          [x] "" (x),
//          [y] "" (y),
//    );
//}

export fn main() callconv(.{ .spirv_kernel = .{.x = 1, .y = 1, .z = 1} }) void {
    const val = std.spirv.global_invocation_id[0];
    const y_u = std.spirv.global_invocation_id[1];

    var y: f32 = @floatFromInt(y_u);
    y *= scanline_height.*;

    // FIXME: Set upper bound
    //if (val > num_segments) return;

    const item = items.data[val];

    // FIXME: For everyone in a warp
    const segment: render_util.ContourSegment = blk: switch (item.arg_type) {
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

            break :blk .{ .line = line };
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

            break :blk .{ .quad_bezier = qb };
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
            break :blk .{ .cubic_bezier = c };
        },
        3 => {
            const arc = Arc {
                .rot = f32_storage.data[item.arg_offs + 0],
                .rx = f32_storage.data[item.arg_offs + 1],
                .ry = f32_storage.data[item.arg_offs + 2],
                .center = .{
                    f32_storage.data[item.arg_offs + 3],
                    f32_storage.data[item.arg_offs + 4],
                },
                .start_theta = f32_storage.data[item.arg_offs + 5],
                .delta_theta = f32_storage.data[item.arg_offs + 6],
            };

            break :blk .{ .arc = arc };
        },
        else => {
            break :blk .{ .line = .{ .a = .{0, 0}, .b = .{0, 0} }};
        },
    };

    var events: [6]render_util.CrossWithT = undefined;
    const len = render_util.calcUnsortedSegmentCrosses(segment, y, scanline_height.*, &events);

    const od = &output.data[outputs_per_line.* * y_u + item.out_offs];
    od.crosses_len = @intCast(len);
    for (0..len) |i| {
        od.x_positions[i] = events[i].cross.x_pos;
        od.ts[i] = events[i].t;
        od.how[i] = @intCast(@intFromEnum(events[i].cross.how));
    }
}

