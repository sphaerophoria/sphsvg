const std = @import("std");

const Pass1Output = @import("Pass1Output.zig");

const Pass2Output = extern struct {
    hows: [6]u32,
    idx: u32,
};

comptime {
    std.debug.assert(@sizeOf(Pass2Output) == 28);
    std.debug.assert(@offsetOf(Pass2Output, "idx") == 24);
    std.debug.assert(@offsetOf(Pass2Output, "hows") == 0);
}

const InputArray = @SpirvType(.{ .runtime_array = Pass1Output });
const OutputArray = @SpirvType(.{ .runtime_array = Pass2Output });

const InputBuffer = extern struct {
    data: InputArray,
};

const OutputBuffer = extern struct {
    data: OutputArray,
};

const input = @extern(*addrspace(.storage_buffer) InputBuffer, .{
    .name = "input",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

const output = @extern(*addrspace(.storage_buffer) OutputBuffer, .{
    .name = "output",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});

const items_per_line = @extern(*addrspace(.constant) u32, .{
    .name = "items_per_line",
    .decoration = .{ .location = 0 },
});


export fn main() callconv(.{ .spirv_kernel = .{.x = 1, .y = 1, .z = 1} }) void {
    const val = std.spirv.global_invocation_id[0];
    if (val >= 1) return;
    const y_u = std.spirv.global_invocation_id[1];
    const idx = y_u * items_per_line.* + val;
    output.data[idx].idx = 10;
    output.data[idx].hows = .{
        @intCast(items_per_line.*),
        @intCast(y_u),
        @intCast(items_per_line.*),
        @intCast(y_u),
        @intCast(items_per_line.*),
        @intCast(y_u),
        //input.data[y_u * items_per_line.* + val].how[1],
        //input.data[y_u * items_per_line.* + val].how[2],
        //input.data[y_u * items_per_line.* + val].how[3],
        //input.data[y_u * items_per_line.* + val].how[4],
        //input.data[y_u * items_per_line.* + val].how[5],
    };
}
