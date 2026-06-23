const sphtud = @import("sphtud");
const std = @import("std");

buf: sphtud.lex.Buf,
state: ?ItemType = null,

pub const Coord = struct {
    x: f32,
    y: f32,

    pub fn format(self: Coord, w: *std.Io.Writer) !void {
        try w.print("({d},{d})", .{ self.x, self.y });
    }
};

pub const ItemVal = union(enum) {
    abs_move: Coord,
    abs_line: Coord,
    abs_horizontal_line: f32,
    abs_vertical_line: f32,
    abs_cubic_bezier: [3]Coord,
    abs_quad_bezier: [2]Coord,
    abs_cubic_bezier_seq: [2]Coord,
    abs_arc,
    rel_move: Coord,
    rel_line: Coord,
    rel_horizontal_line: f32,
    rel_vertical_line: f32,
    rel_cubic_bezier: [3]Coord,
    rel_quad_bezier: [2]Coord,
    rel_cubic_bezier_seq: [2]Coord,
    rel_arc,
    close,
};

const ItemType = @typeInfo(ItemVal).@"union".tag_type.?;
const PathParser = @This();

const Item = struct {
    val: ItemVal,
    args: []const u8,
};

pub fn init(data: []const u8) PathParser {
    return .{
        .buf = .init(data),
    };
}

pub fn next(self: *PathParser) !?ItemVal {
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
            'Z', 'z' => {
                self.state = null;
                return .close;
            },
            else => unreachable,
        }
    }

    const state = self.state orelse return error.InvalidCommand;

    switch (state) {
        inline .abs_move,
        .abs_line,
        .rel_move,
        .rel_line,
        => |t| {
            return @unionInit(ItemVal, @tagName(t), try coord(&self.buf));
        },
        inline .abs_horizontal_line,
        .abs_vertical_line,
        .rel_horizontal_line,
        .rel_vertical_line,
        => |t| {
            return @unionInit(ItemVal, @tagName(t), try coordElem(&self.buf));
        },
        inline .abs_quad_bezier,
        .rel_quad_bezier,
        .abs_cubic_bezier_seq,
        .rel_cubic_bezier_seq,
        => |t| {
            return @unionInit(ItemVal, @tagName(t), .{
                try coord(&self.buf),
                try coord(&self.buf),
            });
        },
        inline .abs_cubic_bezier, .rel_cubic_bezier => |t| {
            return @unionInit(ItemVal, @tagName(t), .{
                try coord(&self.buf),
                try coord(&self.buf),
                try coord(&self.buf),
            });
        },
        .close => unreachable,
        inline else => |t| {
            _ = args(&self.buf);
            return t;
        },
    }
}

fn digits(buf: *sphtud.lex.Buf) ?sphtud.lex.Range {
    const digit_chars = "0123456789";
    return buf.takeWhileAny(digit_chars);
}

fn wsp(buf: *sphtud.lex.Buf) void {
    const ws_chars: []const u8 = &.{ 0x9, 0x20, 0xA, 0xC, 0xD };
    _ = buf.takeWhileAny(ws_chars);
}

fn sign(buf: *sphtud.lex.Buf) ?sphtud.lex.Idx {
    return buf.takeOne("+-");
}

fn coordElem(buf: *sphtud.lex.Buf) !f32 {
    wsp(buf);
    var tmp = buf.tmp();

    _ = sign(&tmp);
    _ = digits(&tmp);
    const has_decimal = tmp.takeOne(".") != null;
    if (has_decimal) {
        _ = digits(&tmp);
    }
    const has_exponent = tmp.takeOne("eE") != null;
    if (has_exponent) {
        _ = sign(&tmp);
        _ = digits(&tmp);
    }

    const r = buf.commit(tmp) orelse return error.Invalid;

    return try std.fmt.parseFloat(f32, r.data(buf.*));
}

test coordElem {
    const tests: []const struct { []const u8, f32 } = &.{
        .{ ".1234", 0.1234 },
        .{ ".1234.123490812309581", 0.1234 },
        .{ "0.1234.123490812309581", 0.1234 },
        .{ "1..123490812309581", 1 },
        .{ "1..", 1 },
        .{ "1.2.", 1.2 },
        .{ "+1.2.", 1.2 },
        .{ "-1.2.", -1.2 },
        .{ "-1.2e10", -1.2e10 },
        .{ "-1.2e-10", -1.2e-10 },
    };

    for (tests) |t| {
        var buf = sphtud.lex.Buf.init(t[0]);

        const val = try coordElem(&buf);
        try std.testing.expectApproxEqAbs(t[1], val, 0.0001);
    }
}

fn coord(buf: *sphtud.lex.Buf) !Coord {
    const x = try coordElem(buf);
    const y = try coordElem(buf);

    return .{
        .x = x,
        .y = y,
    };
}

const command_chars = "MmCcQqZzHhVvLlSsAa";
fn args(buf: *sphtud.lex.Buf) ?sphtud.lex.Range {
    return buf.takeUntilAny(command_chars);
}

