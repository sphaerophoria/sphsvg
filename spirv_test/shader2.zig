
const U = union(enum) {
    a: u64,
    b: u32,
    d: u32,
    e: u32,
    f: u32,
    g: u32,
    h: u32,
    i: u32,
    j: u32,
    c: u8,
};

export fn main() callconv(.{ .spirv_kernel = .{.x = 1, .y = 1, .z = 1} }) void {
    const val: usize = 0;
    const x = U{ .c = val };
    _ = x;
}
