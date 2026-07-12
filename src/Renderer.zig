const sphtud = @import("sphtud");
const std = @import("std");
const PathParser = @import("PathParser.zig");
const xyt = sphtud.render.xyt_program;
const CoordinateConverter = @import("CoordinateConverter.zig");
const render_util = @import("render_util.zig");

tl: Point,
br: Point,

const Renderer = @This();

pub const Contour = sphtud.util.RuntimeSegmentedList(ContourSegment);
pub const Path = sphtud.util.RuntimeSegmentedList(Contour);
pub const Point = render_util.Point;

pub const CubicBezier = render_util.CubicBezier;
pub const QuadBezier = render_util.QuadBezier;
pub const Arc = render_util.Arc;
pub const Line = render_util.Line;

pub const ContourSegment = render_util.ContourSegment;

pub const PixelCross = struct {
    x_pos: f32,
    how: How,

    pub const How = enum {
        leave_top,
        enter_top,
        leave_bottom,
        enter_bottom,

        fn isEnter(self: How) bool {
            switch (self) {
                .enter_top, .enter_bottom => return true,
                .leave_top, .leave_bottom => return false,
            }
        }
    };
};

pub const WindingChange = struct {
    pos: f32,
    change: i8,
};

pub const WindingChangeCalculator = struct {
    pixel_height: f32,
    y: f32,
    crosses_buf: [max_crosses]PixelCross,
    windings_buf: [max_crosses]WindingChange,
    num_crosses: usize = 0,
    num_windings: usize = 0,
    path: Path,

    // FIXME: Calculate based off max contour size * max crosses per segment or something
    const max_crosses = 1024;

    pub fn initPinned(
        self: *WindingChangeCalculator,
        pixel_height: f32,
        y: f32,
        path: Path,
    ) void {
        self.* = .{
            .pixel_height = pixel_height,
            .y = y,
            .crosses_buf = undefined,
            .windings_buf = undefined,
            .path = path,
        };
    }

    pub fn calculateWindingChanges(self: *WindingChangeCalculator) ![]const WindingChange {
        var windings = std.ArrayList(WindingChange).initBuffer(&self.windings_buf);
        defer self.num_windings = windings.items.len;

        var it = self.path.iter();
        while (it.next()) |contour| {
            var contour_it = contour.iter();

            // Keep all crosses around for inspection if something goes wrong
            var crosses = std.ArrayList(PixelCross).initBuffer(self.crosses_buf[self.num_crosses..]);
            defer self.num_crosses += crosses.items.len;

            while (contour_it.next()) |segment| {
                try appendSortedSegmentCrosses(segment.*, self.y, self.pixel_height, &crosses);
            }

            if (crosses.items.len < 1) continue;

            var winding_it = WindingChangeIter{
                .crosses = crosses.items,
                .idx = 1,
                .last = crosses.items[0].how,
            };

            while (winding_it.next()) |change| {
                try windings.appendBounded(change);
            }
        }

        std.mem.sort(WindingChange, windings.items, {}, struct {
            fn f(_: void, a: WindingChange, b: WindingChange) bool {
                return a.pos < b.pos;
            }
        }.f);

        return windings.items;
    }

    fn appendSortedSegmentCrosses(segment: ContourSegment, y: f32, pixel_height: f32, crosses: *std.ArrayList(PixelCross)) !void {
        var unsorted_buf: [12]CrossWithT = undefined;
        const events = calcUnsortedSegmentCrosses(segment, y, pixel_height, &unsorted_buf);

        std.mem.sort(CrossWithT, events, {}, struct {
            fn f(_: void, a: CrossWithT, b: CrossWithT) bool {
                return a.t < b.t;
            }
        }.f);

        for (events) |ev| {
            try crosses.appendBounded(ev.cross);
        }
    }

    const CrossWithT = struct {
        t: f32,
        cross: PixelCross,
    };

    fn calcUnsortedSegmentCrosses(segment: ContourSegment, y: f32, pixel_height: f32, events_buf: []CrossWithT) []CrossWithT {
        var events = std.ArrayList(CrossWithT).initBuffer(events_buf);

        const Case = struct {
            y: f32,
            how_map: [2]PixelCross.How,
        };

        const cases: []const Case = &.{
            .{ .y = y, .how_map = .{ .leave_top, .enter_top } },
            .{ .y = y + pixel_height, .how_map = .{ .enter_bottom, .leave_bottom } },
        };

        for (cases) |case| {
            const crosses = switch (segment) {
                .line => |line| render_util.lineCrosses(line, case.y),
                .quad_bezier => |qb| render_util.quadBezierCrosses(qb, case.y),
                .cubic_bezier => |c| render_util.cubicBezierCrosses(c, case.y),
                .arc => |arc| render_util.arcCrosses(arc, case.y),
            };

            for (0..crosses.len) |i| {
                const res = crosses.buf[i];
                events.appendBounded(.{
                    .t = res.t,
                    .cross = .{
                        .x_pos = res.x,
                        .how = case.how_map[@intFromBool(res.slope_positive)],
                    },
                }) catch unreachable;
            }
        }

        return events.items;
    }

    const WindingChangeIter = struct {
        crosses: []const PixelCross,
        idx: usize,
        last: PixelCross.How,

        pub fn next(self: *WindingChangeIter) ?WindingChange {
            // Note we have to check the wraparound case
            while (self.idx < self.crosses.len + 1) {
                defer self.idx += 1;

                const val = self.crosses[self.idx % self.crosses.len];

                defer self.last = val.how;

                if (val.how == .leave_top and self.last == .enter_bottom) {
                    return .{
                        .pos = val.x_pos,
                        .change = 1,
                    };
                } else if (val.how == .leave_bottom and self.last == .enter_top) {
                    return .{
                        .pos = val.x_pos,
                        .change = -1,
                    };
                }
            }

            return null;
        }
    };
};

pub fn renderPathToImage(self: *Renderer, path: Path, color: sphtud.math.Vec3, out: sphtud.img.Image) !void {
    if (path.len == 0) return;

    const cc = CoordinateConverter{
        .in_width = self.br[0] - self.tl[0],
        .in_height = self.br[1] - self.tl[1],
        .out_width = @floatFromInt(out.width),
        .out_height = @floatFromInt(out.calcHeight()),
    };

    const pixel_height = cc.pixelHeight();

    for (0..out.calcHeight()) |out_y| {
        var sampler: WindingChangeCalculator = undefined;
        sampler.initPinned(
            pixel_height,
            cc.outputToInputY(@floatFromInt(out_y)),
            path,
        );

        const windings = try sampler.calculateWindingChanges();

        var x_idx: usize = 0;
        var winding_count: i32 = 0;
        const px = sphtud.img.RgbF32Pixel{
            .r = color[0],
            .g = color[1],
            .b = color[2],
        };

        for (windings) |winding| {
            const prev_count = winding_count;
            winding_count += winding.change;

            const out_x: i64 = @intFromFloat(cc.inputToOutputX(winding.pos));
            if (out_x < 0) continue;

            // Clamp so the fill loop never walks past the row into the
            // next one when paths extend beyond the canvas right edge.
            const out_x_u: usize = @intCast(@min(out_x, @as(i64, @intCast(out.width))));
            defer x_idx = out_x_u;

            // We have the following cases
            //  1. non-zero to non-zero -> fill with color
            //  2. zero to non-zero -> do nothing
            //  3. non-zero to zero -> fill with color
            //
            // i.e. fill iff the span we just walked across was inside,
            // which is determined by the winding count BEFORE this event,
            // not after.
            if (prev_count == 0) continue;

            // FIXME: SVG spec defines multiple fill rules
            switch (out.data) {
                inline else => |d| {
                    // FIXME: We need some memset API on the color data
                    for (x_idx..out_x_u) |x| {
                        d.write(out_y * out.width + x, .from(px));
                    }
                },
            }
        }
    }
}

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

pub const PathLineIter = struct {
    contours: Path.Iter,
    segments: ?Contour.Iter,
    current_segment: ContourSegment,
    t_idx: usize,
    last: sphtud.math.Vec2,

    const line_segments = 20;

    pub fn init(path: *const Path) PathLineIter {
        return .{
            .contours = path.iter(),
            .segments = null,
            .current_segment = undefined,
            .t_idx = line_segments,
            .last = undefined,
        };
    }

    pub fn next(self: *PathLineIter) ?Line {
        while (true) {
            if (self.t_idx < line_segments) {
                switch (self.current_segment) {
                    .line => |m| {
                        self.t_idx = line_segments;
                        return m;
                    },
                    .cubic_bezier => |bezier| {
                        defer self.t_idx += 1;

                        if (self.t_idx == 0) {
                            self.last = bezier.start;
                        }

                        const t: f32 = 1.0 / @as(f32, line_segments) * @as(f32, @floatFromInt(self.t_idx + 1));

                        const p = sampleCubicBezier(bezier, t);

                        defer self.last = p;
                        return .{
                            .a = self.last,
                            .b = p,
                        };
                    },
                    .quad_bezier => |bezier| {
                        defer self.t_idx += 1;

                        if (self.t_idx == 0) {
                            self.last = bezier.start;
                        }

                        const t: f32 = 1.0 / @as(f32, line_segments) * @as(f32, @floatFromInt(self.t_idx + 1));

                        const p = sampleQuadBezier(bezier, t);

                        defer self.last = p;
                        return .{
                            .a = self.last,
                            .b = p,
                        };
                    },
                    .arc => |arc| {
                        defer self.t_idx += 1;

                        const applier = arc.applier();

                        if (self.t_idx == 0) {
                            self.last = applier.apply(arc.start_theta);
                        }

                        const t: f32 = 1.0 / @as(f32, line_segments) * @as(f32, @floatFromInt(self.t_idx + 1));
                        const theta = arc.start_theta + arc.delta_theta * t;

                        const val = applier.apply(theta);

                        defer self.last = val;
                        return .{
                            .a = self.last,
                            .b = val,
                        };
                    },
                }
            }

            if (self.segments) |*s| blk: {
                self.current_segment = (s.next() orelse break :blk).*;
                self.t_idx = 0;
                continue;
            }

            const segments = self.contours.next() orelse return null;
            self.segments = segments.iter();
        }
    }

    fn sampleCubicBezier(bezier: CubicBezier, t: f32) Point {
        const t_v = sphtud.math.Vec2{ t, t };
        const a = std.math.lerp(bezier.start, bezier.c1, t_v);
        const b = std.math.lerp(bezier.c1, bezier.c2, t_v);
        const c = std.math.lerp(bezier.c2, bezier.end, t_v);

        const d = std.math.lerp(a, b, t_v);
        const e = std.math.lerp(b, c, t_v);

        return std.math.lerp(d, e, t_v);
    }

    fn sampleQuadBezier(bezier: QuadBezier, t: f32) Point {
        const t_v = sphtud.math.Vec2{ t, t };
        const a = std.math.lerp(bezier.start, bezier.c, t_v);
        const b = std.math.lerp(bezier.c, bezier.end, t_v);

        return std.math.lerp(a, b, t_v);
    }
};

test {
    _ = WindingChangeCalculator;
    std.testing.refAllDecls(@This());
}
