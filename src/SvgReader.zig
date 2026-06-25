const std = @import("std");
const sphtud = @import("sphtud");
const pm = @import("parse.zig");

pub const PathParser = @import("PathParser.zig");

xml: sphtud.xml.Parser,

view_box: ViewBox,

const ViewBox = struct {
    min_x: f32,
    min_y: f32,
    width: f32,
    height: f32,

    pub fn parse(s: []const u8) !ViewBox {
        var b = sphtud.lex.Buf.init(s);

        const min_x = pm.number(&b) orelse return error.Invalid;
        const min_y = pm.number(&b) orelse return error.Invalid;
        const width = pm.number(&b) orelse return error.Invalid;
        const height = pm.number(&b) orelse return error.Invalid;

        return .{
            .min_x = try std.fmt.parseFloat(f32, min_x.data(b)),
            .min_y = try std.fmt.parseFloat(f32, min_y.data(b)),
            .width = try std.fmt.parseFloat(f32, width.data(b)),
            .height = try std.fmt.parseFloat(f32, height.data(b)),
        };
    }
};

const SvgReader = @This();

pub fn init(r: *std.Io.Reader) !SvgReader {
    var discarding = std.Io.Writer.Discarding.init(&.{});
    const dw = &discarding.writer;

    var xml = sphtud.xml.Parser.init(r);
    const first = try xml.next(dw);

    const view_box = try parseSvgElem(first);
    return .{
        .xml = xml,
        .view_box = view_box,
    };
}

pub const Item = union(enum) {
    path: Path,
};

pub const Path = struct {
    fill: ?[4]u8,
    stroke: ?[4]u8,
    instructions: []const u8,

    pub fn init(item: sphtud.xml.Item) !Path {
        var it = item.attributeIt();

        const KnownAttrs = enum {
            fill,
            stroke,
            d,
        };

        var fill: ?[4]u8 = null;
        var stroke: ?[4]u8 = null;
        var instructions: ?[]const u8 = null;

        while (try it.next()) |attr| {
            const key = std.meta.stringToEnum(KnownAttrs, attr.key) orelse {
                // FIXME: Scoped logger?
                std.log.warn("Unknown path attribute {s}\n", .{attr.key});
                continue;
            };

            var buf = sphtud.lex.Buf.init(attr.val);
            switch (key) {
                .fill => {
                    fill = try pm.color(&buf);
                },
                .stroke => {
                    stroke = try pm.color(&buf);
                },
                .d => {
                    instructions = attr.val;
                },
            }
        }

        return .{
            .fill = fill,
            .stroke = stroke,
            .instructions = instructions orelse return error.MissingPath,
        };
    }
};

pub fn next(self: *SvgReader) !?Item {
    var discarding = std.Io.Writer.Discarding.init(&.{});
    const dw = &discarding.writer;

    while (true)  {
        const elem = try self.xml.next(dw) orelse return null;
        switch (elem.type) {
            .xml_decl => {},
            .element_start => {
                const KnownElements = enum {
                    path,
                };

                const known = std.meta.stringToEnum(KnownElements, elem.name) orelse return error.Unimplemented;

                switch (known) {
                    .path => return .{ .path = try .init(elem) },
                }
            },
            .element_end => {},
            .element_content => {},
            .comment => {},
        }
    }
}


fn parseSvgElem(first_item: ?sphtud.xml.Item) !ViewBox {
    const unwrapped = first_item orelse return error.Invalid;
    if (unwrapped.type != .element_start) return error.Invalid;
    if (!std.mem.eql(u8, unwrapped.name, "svg")) return error.Invalid;

    const KnownAttrs = enum {
        xmlns,
        viewBox,
    };

    var view_box: ?ViewBox = null;

    var it = unwrapped.attributeIt();
    while (try it.next()) |attr| {
        const key = std.meta.stringToEnum(KnownAttrs, attr.key) orelse {
            // FIXME: Warnings maybe go to diagnostics? Or at least into their own scope?
            std.log.warn("Unknown attribute xmlns\n", .{});
            continue;
        };

        switch (key) {
            .xmlns => {},
            .viewBox => {
                view_box = try ViewBox.parse(attr.val);
            },
        }
    }

    return view_box orelse return error.Unimplemented;
}

