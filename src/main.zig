const sphtud = @import("sphtud");
const std = @import("std");

fn loadSvg(alloc: std.mem.Allocator) ![]const u8 {
    const f = try sphtud.io.open("blender.svg", .{}, 0);
    defer sphtud.io.close(f);

    var reader_buf: [4096]u8 = undefined;
    var fr = sphtud.io.Reader.init(f, &reader_buf);
    const r = &fr.interface;

    return try r.allocRemaining(alloc, .unlimited);
}

fn ensureIsSvg(first_item: ?sphtud.xml.Item) !void {
    const unwrapped = first_item orelse return error.Invalid;
    if (unwrapped.type != .element_start) return error.Invalid;
    if (!std.mem.eql(u8, unwrapped.name, "svg")) return error.Invalid;
}

const Coord = struct {
    x: f32,
    y: f32,

    pub fn format(self: Coord, w: *std.Io.Writer) !void {

        try w.print("({d},{d})", .{self.x, self.y});
    }
};


const CoordIter = struct {
    inner: PathParser,

    pub fn init(args: []const u8) CoordIter {
        return .{
            .inner = .{
                .buf = args,
                .idx = 0,
            },
        };
    }

    pub fn next(self: *CoordIter) !?Coord {
        if (self.inner.idx >= self.inner.buf.len) return null;

        _ = try self.inner.consumeWs();
        return try self.inner.parseCoord();
    }
};

const FloatIter = struct {
    inner: PathParser,

    pub fn init(args: []const u8) FloatIter {
        return .{
            .inner = .{
                .buf = args,
                .idx = 0,
            },
        };
    }

    pub fn next(self: *FloatIter) !?f32 {
        if (self.inner.idx >= self.inner.buf.len) return null;

        _ = try self.inner.consumeWs();
        return try self.inner.parseCoordSingle();
    }
};

const PathParser = struct {
    buf: []const u8,
    idx: usize,

    const ItemVal = union(enum) {
        abs_move: CoordIter,
        abs_line: CoordIter,
        abs_horizontal_line: FloatIter,
        abs_vertical_line: FloatIter,
        abs_cubic_bezier: CoordIter,
        abs_quad_bezier: CoordIter,
        abs_cubic_bezier_seq: CoordIter,
        abs_arc: CoordIter,
        rel_move: CoordIter,
        rel_line: CoordIter,
        rel_horizontal_line: FloatIter,
        rel_vertical_line: FloatIter,
        rel_cubic_bezier: CoordIter,
        rel_quad_bezier: CoordIter,
        rel_cubic_bezier_seq: CoordIter,
        rel_arc: CoordIter,
        close,
    };

    const Item = struct {
        val: ItemVal,
        args: []const u8,
    };

    pub fn next(self: *PathParser) !?Item {
        if (self.idx >= self.buf.len) return null;

        const command_char = self.buf[self.idx];
        self.idx += 1;
        const args = self.advanceToNextCommandChar();
        const item_type: ItemVal = switch (command_char) {
            'M' => .{ .abs_move = .init(args) },
            'm' => .{ .rel_move = .init(args) },
            'C' => .{ .abs_cubic_bezier = .init(args) },
            'c' => .{ .rel_cubic_bezier = .init(args) },
            'Q' => .{ .abs_quad_bezier = .init(args) },
            'q' => .{ .rel_quad_bezier = .init(args) },
            'Z', 'z' => .close,
            'H' => .{ .abs_horizontal_line = .init(args) },
            'h' => .{ .rel_horizontal_line = .init(args) },
            'V' => .{ .abs_vertical_line = .init(args) },
            'v' => .{ .rel_vertical_line = .init(args) },
            'L' => .{ .abs_line = .init(args) },
            'l' => .{ .rel_line = .init(args) },
            'S' => .{ .abs_cubic_bezier_seq = .init(args) },
            's' => .{ .rel_cubic_bezier_seq = .init(args) },
            'a' => .{ .rel_arc = .init(args) },
            'A' => .{ .abs_arc = .init(args) },
            else => return error.InvalidCommand,
        };

        return .{
            .val = item_type,
            .args = args,
        };
    }

    pub fn advanceToNextCommandChar(self: *PathParser) []const u8 {
        const commands = "MmCcQqZzHhVvLlSsAa";
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.idx, commands) orelse self.buf.len;
        defer self.idx = end;
        return self.buf[self.idx..end];
    }

    fn consumeWs(self: *PathParser) !void {
        const ws_chars: []const u8 = &.{0x9, 0x20, 0xA, 0xC, 0xD};
        _ = try self.consumeMany(ws_chars);
    }

    fn consumeDigits(self: *PathParser) ![]const u8 {
        // FIXME: Range is more efficient
        const digit_chars = "0123456789";
        return self.consumeMany(digit_chars);
    }

    fn consumeMany(self: *PathParser, chars: []const u8) ![]const u8 {
        const start = self.idx;
        if (self.idx >= self.buf.len) return error.EndOfStream;
        self.idx = std.mem.indexOfNonePos(u8, self.buf, self.idx, chars) orelse self.buf.len;

        return self.buf[start..self.idx];
    }

    fn consumeManyOpt(self: *PathParser, chars: []const u8) ![]const u8 {
        if (self.idx >= self.buf.len) return error.EndOfStream;
        self.idx = std.mem.indexOfNonePos(u8, self.buf, self.idx, chars) orelse return "";
    }

    fn consumeOneOpt(self: *PathParser, chars: []const u8) ![]const u8 {
        if (self.idx >= self.buf.len) return "";
        const start = self.idx;

        if (self.idx <= self.buf.len) {
            const c = self.buf[self.idx];
            for (chars) |comp| {
                if (c == comp) {
                    self.idx += 1;
                    break;
                }
            }
        }
        return self.buf[start..self.idx];
    }

    fn parseCoordSingle(self: *PathParser) !f32 {
        const start = self.idx;
        errdefer self.idx = start;

        _ = try self.consumeOneOpt("+-");
        _ = try self.consumeDigits();
        const has_decimal = (try self.consumeOneOpt(".")).len > 0;
        if (has_decimal) {
            _  = try self.consumeDigits();
        }
        const has_exponent = (try self.consumeOneOpt("eE")).len > 0;
        if (has_exponent) {
            _ = try self.consumeOneOpt("+-");
            _  = try self.consumeDigits();
        }

        return try std.fmt.parseFloat(f32, self.buf[start..self.idx]);
    }

    test "parseCoordSingle" {
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
            var pp = PathParser {
                .buf = t[0],
                .idx = 0,
            };

            const val = try pp.parseCoordSingle();
            try std.testing.expectApproxEqAbs(t[1], val, 0.0001);
        }
    }

    fn parseCoord(self: *PathParser) !Coord {
        if (self.idx >= self.buf.len) return error.EndOfStream;

        const x = try self.parseCoordSingle();
        try self.consumeWs();
        const y = try self.parseCoordSingle();

        return .{
            .x = x,
            .y = y,
        };
    }
};

fn handlePath(xml_item: sphtud.xml.Item) !void {
    var attr_it = xml_item.attributeIt();

    while (try attr_it.next()) |attr| {
        if (std.mem.eql(u8, attr.key, "d")) {
            std.debug.print("\n\nnew path\n", .{});
            var pp = PathParser {
                .buf = attr.val,
                .idx = 0,
            };

            while (try pp.next()) |item| {
                std.debug.print("{t}: {s}\n", .{item.val, item.args});
                switch (item.val) {
                    .abs_move, .rel_move => |it_c| {
                        // FIXME: Find nicer interface
                        var it = it_c;
                        while (true) {
                            const p = try it.next() orelse break;
                            std.debug.print("move: {f}\n", .{p});
                        }
                    },
                    .rel_horizontal_line, .abs_horizontal_line => |it_c| {
                        // FIXME: Find nicer interface
                        var it = it_c;

                        while (try it.next()) |val| {
                            std.debug.print("h: {d}\n", .{val});
                        }
                    },
                    .abs_cubic_bezier, .rel_cubic_bezier => |it_c| {
                        // FIXME: Find nicer interface
                        var it = it_c;
                        while (true) {
                            const c1 = try it.next() orelse break;
                            const c2 = try it.next() orelse return error.MissingCoord;
                            const end = try it.next() orelse return error.MissingCoord;
                            std.debug.print("rc: {f} {f} {f}\n", .{c1, c2, end});
                        }

                    },
                    else => {},
                }
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const svg_data = try loadSvg(init.arena.allocator());
    var svg_reader = std.Io.Reader.fixed(svg_data);

    var parser = sphtud.xml.Parser.init(&svg_reader);

    var discarding = std.Io.Writer.Discarding.init(&.{});
    const dw = &discarding.writer;

    try ensureIsSvg(try parser.next(dw));

    while (try parser.next(&discarding.writer)) |elem| switch (elem.type) {
        .xml_decl => {},
        .element_start => {
            const KnownElements = enum {
                path,
            };

            const known = std.meta.stringToEnum(KnownElements, elem.name) orelse return error.Unimplemented;

            switch (known) {
                .path => {
                    try handlePath(elem);
                }
            }
        },
        .element_end => {},
        .element_content => {},
        .comment => {},
    };

    //std.debug.print("{s}\n", .{svg_data});
}

test {
    std.testing.refAllDecls(@This());
}
