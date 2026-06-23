const sphtud = @import("sphtud");
const std = @import("std");
const PathParser = @import("PathParser.zig");

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

fn handlePath(xml_item: sphtud.xml.Item) !void {
    var attr_it = xml_item.attributeIt();

    while (try attr_it.next()) |attr| {
        if (std.mem.eql(u8, attr.key, "d")) {
            std.debug.print("\n\nnew path\n", .{});
            var pp = PathParser.init(attr.val);

            while (try pp.next()) |item| {
                std.debug.print("{any}\n", .{item});
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
                },
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
