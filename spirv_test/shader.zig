const std = @import("std");

const F32Array = @SpirvType(.{ .runtime_array = f32 });
const V4Array = @SpirvType(.{ .runtime_array = @Vector(4, f32) });

const F32Buffer = extern struct {
    data: F32Array,
};

const V4Buffer = extern struct {
    data: V4Array,
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

//const f32_storage = @extern(*addrspace(.storage_buffer) F32Buffer, .{
//    .name = "f32_storage",
//    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
//});
//
//const items = @extern(*addrspace(.storage_buffer) ItemBuffer, .{
//    .name = "items",
//    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
//});

const output = @extern(*addrspace(.storage_buffer) V4Buffer, .{
    .name = "output",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

export fn main() callconv(.{ .spirv_kernel = .{.x = 1, .y = 1, .z = 1} }) void {
    const val = std.spirv.global_invocation_id[0];

    // FIXME: Set upper bound
    //if (val > num_segments) return;

    const val_f: f32 = @floatFromInt(val);
    //const item = items.data[val];
    output.data[val]  = .{val_f , val_f, 0, 1};
    if (true) return;
    //switch (item.arg_type) {
    //    // FIXME: named type
    //    // line
    //    0 => {
    //        const line_start_x = f32_storage.data[item.arg_offs + 0];
    //        const line_start_y = f32_storage.data[item.arg_offs + 1];
    //        output.data[item.out_offs]  = .{line_start_x , line_start_y, 0, 1};
    //    },
    //    else => {},
    //}

}
