const sphtud = @import("sphtud");
const std = @import("std");
const parse = @import("parse.zig");

buf: sphtud.lex.Buf,
state: ?ItemType = null,

pub const Coord = sphtud.math.Vec2;

pub const Arc = struct {
    rx: f32,
    ry: f32,
    x_rot: f32,
    large_arc: bool,
    sweep_flag: bool,
    end: Coord,
};

pub const Item = union(enum) {
    abs_move: Coord,
    abs_line: Coord,
    abs_horizontal_line: f32,
    abs_vertical_line: f32,
    abs_cubic_bezier: [3]Coord,
    abs_quad_bezier: [2]Coord,
    abs_cubic_bezier_seq: [2]Coord,
    abs_arc: Arc,
    rel_move: Coord,
    rel_line: Coord,
    rel_horizontal_line: f32,
    rel_vertical_line: f32,
    rel_cubic_bezier: [3]Coord,
    rel_quad_bezier: [2]Coord,
    rel_cubic_bezier_seq: [2]Coord,
    rel_arc: Arc,
    close,
};

const ItemType = std.meta.Tag(Item);
const PathParser = @This();

pub fn init(data: []const u8) PathParser {
    return .{
        .buf = .init(data),
    };
}

pub fn next(self: *PathParser) !?Item {
    if (self.buf.empty()) return null;

    if (self.buf.takeOne(command_chars)) |idx| {
        switch (idx.data(self.buf)) {
            'M' => self.state = .abs_move,
            'm' => self.state = .rel_move,
            'C' => self.state = .abs_cubic_bezier,
            'c' => self.state = .rel_cubic_bezier,
            'Q' => self.state = .abs_quad_bezier,
            'q' => self.state = .rel_quad_bezier,
            'H' => self.state = .abs_horizontal_line,
            'h' => self.state = .rel_horizontal_line,
            'V' => self.state = .abs_vertical_line,
            'v' => self.state = .rel_vertical_line,
            'L' => self.state = .abs_line,
            'l' => self.state = .rel_line,
            'S' => self.state = .abs_cubic_bezier_seq,
            's' => self.state = .rel_cubic_bezier_seq,
            'a' => self.state = .rel_arc,
            'A' => self.state = .abs_arc,
            'Z', 'z' => self.state = .close,
            else => unreachable,
        }
    }

    const state = self.state orelse return error.InvalidCommand;

    switch (state) {
        inline else => |t| {
            const FT = @FieldType(Item, @tagName(t));
            const ret: FT = switch (FT) {
                Coord => try coord(&self.buf),
                f32 => try coordElem(&self.buf),
                [2]Coord => .{
                    try coord(&self.buf),
                    try coord(&self.buf),
                },
                [3]Coord => .{
                    try coord(&self.buf),
                    try coord(&self.buf),
                    try coord(&self.buf),
                },
                Arc => blk: {

                    break :blk .{
                        .rx = try coordElem(&self.buf),
                        .ry = try coordElem(&self.buf),
                        .x_rot = try coordElem(&self.buf),
                        .large_arc = try flag(&self.buf),
                        .sweep_flag = try flag(&self.buf),
                        .end = try coord(&self.buf),
                    };
                },
                void => {
                    _ = args(&self.buf);
                },
                else => @compileError("Unhandled type " ++ @typeName(FT)),
            };
            return @unionInit(Item, @tagName(t), ret);
        },
    }
}

fn flag(buf: *sphtud.lex.Buf) !bool {
    parse.wsp(buf);
    const idx = buf.takeOne("01") orelse return error.Invalid;
    switch (idx.data(buf.*)) {
        '0' => return false,
        '1' => return true,
        else => return error.Invalid,
    }
}

fn coordElem(buf: *sphtud.lex.Buf) !f32 {
    const r = parse.number(buf) orelse return error.Invalid;
    return try std.fmt.parseFloat(f32, r.data(buf.*));
}

fn coord(buf: *sphtud.lex.Buf) !Coord {
    const x = try coordElem(buf);
    const y = try coordElem(buf);

    return .{ x, y };
}

const command_chars = "MmCcQqZzHhVvLlSsAa";
fn args(buf: *sphtud.lex.Buf) ?sphtud.lex.Range {
    return buf.takeUntilAny(command_chars);
}

