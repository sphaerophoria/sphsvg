const std = @import("std");
const sphtud = @import("sphtud");
const sphtext = sphtud.text;
const sphrender = sphtud.render;
const gui = sphtud.ui;
const RuntimeSegmentedList = sphtud.util.RuntimeSegmentedList;
const TextRenderer = sphtud.text.TextRenderer;
const gl = sphtud.render.gl;
const sphalloc = sphtud.alloc;
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphtud.render.GlAlloc;
const PathParser = @import("PathParser.zig");
const Renderer = @import("Renderer.zig");
const SvgReader = @import("SvgReader.zig");
const SvgRenderer = @import("SvgRenderer.zig");

const Vec2 = sphtud.math.Vec2;

const bezier_resolution = 20;
const ColoredPath = struct {
    color: sphtud.math.Vec3,
    path: Renderer.Path,
};

pub const DebugWidget = struct {
    tex: sphtud.render.Texture,
    image_width: i32,
    image_height: i32,
    zoom: f32,
    point_color: gui.Color,
    enters_color: gui.Color,
    exits_color: gui.Color,
    pan: sphtud.math.Vec2,
    panning: ?sphtud.ui.MousePos,
    render_program: *sphtud.render.xyuvt_program.ImageRenderer,
    path_program: sphtud.render.xyt_program.SolidColorProgram,
    path_buf: sphtud.render.xyt_program.Buffer,
    path_source: sphtud.render.xyt_program.RenderSource,
    point_buf: sphtud.render.xyt_program.Buffer,
    point_source: sphtud.render.xyt_program.RenderSource,
    enters_buf: sphtud.render.xyt_program.Buffer,
    enters_source: sphtud.render.xyt_program.RenderSource,
    exits_buf: sphtud.render.xyt_program.Buffer,
    exits_source: sphtud.render.xyt_program.RenderSource,
    widget: gui.Widget,

    pub fn init(gl_alloc: *sphtud.render.GlAlloc, scratch: sphtud.alloc.LinearAllocator, paths: []const ColoredPath, in_width: f32, in_height: f32, render_program: *sphtud.render.xyuvt_program.ImageRenderer) !DebugWidget {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);


        // FIXME: Upload buffer data without conversion and specify offsets with render source
        var path_data = std.ArrayList(sphtud.render.xyt_program.Vertex).empty;
        var path_segment_points = std.ArrayList(sphtud.render.xyt_program.Vertex).empty;
        {
            const alloc = scratch.allocator();
            for (paths) |path| {
                var it = path.path.iter();
                while (it.next()) |contour| {
                    var contour_it = contour.iter();
                    while (contour_it.next()) |segment| switch (segment.*) {
                        .line => |l| {
                            try path_data.append(alloc,
                                toVertex(l.a, in_width, in_height),
                            );
                            try path_data.append(alloc,
                                toVertex(l.b, in_width, in_height),
                            );

                            try path_segment_points.append(alloc,
                                toVertex(l.a, in_width, in_height),
                            );
                            try path_segment_points.append(alloc,
                                toVertex(l.b, in_width, in_height),
                            );

                        },
                        // FIXME: somewhat duped with Renderer.renderPath...
                        // however that will probably disappear in it's current
                        // form
                        .cubic_bezier => |bezier| {
                            const start = bezier.start;
                            const c1 = bezier.c1;
                            const c2 = bezier.c2;
                            const end = bezier.end;

                            try path_segment_points.append(alloc,
                                toVertex(start, in_width, in_height),
                            );
                            try path_segment_points.append(alloc,
                                toVertex(end, in_width, in_height),
                            );

                            var last = bezier.start;
                            for (0..bezier_resolution) |i| {
                                const t: sphtud.math.Vec2 = @splat(1.0 / @as(f32, bezier_resolution) * @as(f32, @floatFromInt(i + 1)));

                                const a = std.math.lerp(start, c1, t);
                                const b = std.math.lerp(c1, c2, t);
                                const c = std.math.lerp(c2, end, t);

                                const d = std.math.lerp(a, b, t);
                                const e = std.math.lerp(b, c, t);

                                const p = std.math.lerp(d, e, t);

                                try path_data.append(alloc, toVertex(last, in_width, in_height));
                                try path_data.append(alloc, toVertex(p, in_width, in_height));
                                last = p;
                            }
                        },
                        .quad_bezier => {
                            unreachable;
                        },
                        .arc => |arc| {
                            const transform = sphtud.math.Transform.rotate(arc.rot).then(
                                .translate(arc.center[0], arc.center[1]),
                            );

                            var last = transform.apply(.{ arc.rx * @cos(arc.start_theta), arc.ry * @sin(arc.start_theta), 1 });
                            const start_point = transform.apply2(.{ arc.rx * @cos(arc.start_theta), arc.ry * @sin(arc.start_theta)});
                            const end_point = transform.apply2(.{ arc.rx * @cos(arc.start_theta + arc.delta_theta), arc.ry * @sin(arc.start_theta + arc.delta_theta)});
                            try path_segment_points.append(alloc,
                                toVertex(start_point, in_width, in_height),
                            );
                            try path_segment_points.append(alloc,
                                toVertex(end_point, in_width, in_height),
                            );

                            for (0..bezier_resolution) |i| {
                                const t: f32 = 1.0 / @as(f32, bezier_resolution) * @as(f32, @floatFromInt(i + 1));
                                const theta = arc.start_theta + arc.delta_theta * t;

                                const val = transform.apply(.{ arc.rx * @cos(theta), arc.ry * @sin(theta), 1 });

                                try path_data.append(alloc, toVertex(.{ last[0], last[1] }, in_width, in_height) );
                                try path_data.append(alloc, toVertex(.{ val[0], val[1] }, in_width, in_height) );
                                last = val;
                            }
                        },
                    };
                }
            }
        }

        const path_program = try sphtud.render.xyt_program.solidColorProgram(gl_alloc);
        const path_buf = try sphtud.render.xyt_program.Buffer.init(
            gl_alloc,
            path_data.items,
        );
        var path_source = try sphtud.render.xyt_program.RenderSource.init(
            gl_alloc
        );
        path_source.bindData(path_program.handle(), path_buf);

        const point_buf = try sphtud.render.xyt_program.Buffer.init(
            gl_alloc,
            path_segment_points.items,
        );
        var point_source = try sphtud.render.xyt_program.RenderSource.init(
            gl_alloc
        );
        point_source.bindData(path_program.handle(), point_buf);

        return .{
            .render_program = render_program,
            .path_program = path_program,
            .path_buf = path_buf,
            .path_source = path_source,
            .point_buf = point_buf,
            .point_source = point_source,
            .point_color = .white,
            .enters_color = .{ .r = 0, .g = 0, .b = 1, .a = 1 },
            .exits_color = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
            .enters_buf = try .init(gl_alloc, &.{}),
            .enters_source = try .init(gl_alloc),
            .exits_buf = try .init(gl_alloc, &.{}),
            .exits_source = try .init(gl_alloc),
            .tex = try sphtud.render.makeTextureCommon(gl_alloc),
            .image_width = 200,
            .image_height = 200,
            .zoom = 1.0,
            .pan = .{ 0, 0 },
            .panning = null,
            .widget = .{
                .vtable = &.{
                    .render = render,
                    .input = input,
                    .update = update,
                    .reset = null,
                },
                .size = .{},
                .focused = false,
            },
        };
    }

    fn toVertex(val: sphtud.math.Vec2, in_width: f32, in_height: f32) sphtud.render.xyt_program.Vertex {
        return .{
            .vPos = .{
                (val[0] / in_width) * 2 - 1,
                (val[1] / in_height) * 2 - 1,
            },
        };
    }

    fn update(widget: *gui.Widget, available: gui.PixelSize, delta_s: f32) anyerror!void {
        const self: *DebugWidget = @alignCast(@fieldParentPtr("widget", widget));
        _ = delta_s;
        self.widget.size = available;
    }

    fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *DebugWidget = @alignCast(@fieldParentPtr("widget", widget));

        const scissor = sphtud.render.TemporaryScissor.init();
        defer scissor.reset();
        scissor.set(widget_bounds.left, window_bounds.bottom - widget_bounds.bottom, widget_bounds.calcWidth(), widget_bounds.calcHeight());

        const widget_aspect = asf32(widget_bounds.calcWidth()) / asf32(widget_bounds.calcHeight());
        const image_aspect = asf32(self.image_width) / asf32(self.image_height);

        const aspect_transform = if (image_aspect < widget_aspect)
            sphtud.math.Transform.scale(image_aspect / widget_aspect, 1)
        else
            sphtud.math.Transform.scale(1, widget_aspect / image_aspect);

        const transform = sphtud.math.Transform.translate(self.pan[0], self.pan[1])
            .then(aspect_transform)
            .then(.scale(1, -1))
            .then(.scale(self.zoom, self.zoom))
            .then(sphtud.ui.util.widgetToClipTransform(widget_bounds, window_bounds));

        self.render_program.renderTexture(self.tex, transform);

        const color: sphtud.math.Vec3 = .{self.point_color.r, self.point_color.g, self.point_color.b};
        gl.glLineWidth(5.0);
        self.path_program.renderLines(self.path_source, .{
            .color = color,
            .transform = transform.inner,
        });

        gl.glPointSize(20.0);
        self.path_program.renderPoints(self.point_source, .{
            .color = color,
            .transform = transform.inner,
        });

        const enters_color: sphtud.math.Vec3 = .{self.enters_color.r, self.enters_color.g, self.enters_color.b};
        self.path_program.renderPoints(self.enters_source, .{
            .color = enters_color,
            .transform = transform.inner,
        });

        const exits_color: sphtud.math.Vec3 = .{self.exits_color.r, self.exits_color.g, self.exits_color.b};
        self.path_program.renderPoints(self.exits_source, .{
            .color = exits_color,
            .transform = transform.inner,
        });
    }

    fn input(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) anyerror!void {
        const self: *DebugWidget = @alignCast(@fieldParentPtr("widget", widget));

        _ = widget_bounds;
        const mouse_in_bounds = input_bounds.containsMousePos(input_state.mouse_pos);
        if (mouse_in_bounds) {
            self.zoom *= std.math.pow(f32, 1.1, input_state.frame_scroll);
            input_state.consumeScroll();
        }

        if (mouse_in_bounds and input_state.mouse_pressed) {
            self.panning = input_state.mouse_pos;
        }

        if (input_state.mouse_released) {
            self.panning = null;
        }

        if (self.panning) |*last_pos| {
            const x_movement_window = input_state.mouse_pos.x - last_pos.x;
            const y_movement_window = input_state.mouse_pos.y - last_pos.y;

            // FIXME: Finding the proper transform here is way better, but I'm a lazy pos
            self.pan += .{x_movement_window * 0.005 / self.zoom, y_movement_window * 0.005 / self.zoom};
            last_pos.* = input_state.mouse_pos;
        }
    }

    //fn mouseToClip(mouse: sphtud.ui.MousePos, widget_bounds: gui.PixelBBox) sphtud.math.Vec2 {
    //    const x = mouse.x - asf32(widget_bounds.left);
    //    const y = mouse.y - asf32(widget_bounds.top);

    //    return .{
    //        2 * x / asf32(widget_bounds.calcWidth()) - 1.0,
    //        -(2 * y / asf32(widget_bounds.calcHeight()) - 1.0),
    //    };
    //}

};

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

const Ids = struct {
    output_width: usize,
    output_height: usize,
    point_color: usize,
    enters_color: usize,
    exits_color: usize,
    line_debug_changed: usize,

    fn init() Ids {
        var alloc = sphtud.util.IdAlloc.init;
        return .{
            .output_width = alloc.allocOne(),
            .output_height = alloc.allocOne(),
            .point_color = alloc.allocOne(),
            .line_debug_changed = alloc.allocOne(),
            .enters_color = alloc.allocOne(),
            .exits_color = alloc.allocOne(),
        };

    }
};

const ids = Ids.init();

pub fn renderSvg(
    scratch: sphtud.alloc.LinearAllocator,
    renderer: *Renderer,
    paths: []const ColoredPath,
    output_width: usize,
    output_height: usize,
    tex: sphtud.render.Texture,
) !void {
    const cp = scratch.checkpoint();
    defer scratch.restore(cp);

    const data_buf = try scratch.allocator().alloc(u8, 4 * output_width * output_height);
    @memset(data_buf, 0);

    const img = sphtud.img.Image{
        .colorspace = .srgb,
        .transfer_fn = .srgb,
        .data = .init(.rgba_8888, data_buf),
        .width = @intCast(output_width),
    };

    for (paths) |path| {
        try renderer.renderPathToImage(path.path, path.color, img);
    }

    sphtud.render.setTextureFromSrgb(tex, img.data.rgba_8888.data, output_width);
}

// FIXME: Why the F is this here. Renderer should have an init function
pub const solid_color_frag =
    \\#version 330
    \\out vec4 fragment;
    \\uniform vec3 color;
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;


pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 800, 800);

    try sphtud.render.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
    gl.glEnable(gl.GL_FRAMEBUFFER_SRGB);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.WidgetState.init(
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{
            .font_size = 16,
        },
    );

    const wf = gui.WidgetFactory{
        .alloc = gui_alloc,
        .state = gui_state,
    };

    const view_box, const paths = blk: {
        var paths = std.ArrayList(ColoredPath).empty;

        const f = try sphtud.io.open("blender.svg", .{}, 0);
        defer sphtud.io.close(f);

        var buf: [4096]u8 = undefined;
        var data_r = sphtud.io.Reader.init(f, &buf);

        var reader = try SvgReader.init(&data_r.interface);

        while (try reader.next()) |item| switch (item) {
            .path => |p| {
                const render_path = try SvgRenderer.svgPathToRenderPath(allocators.root.arena(), allocators.root.expansion(), p);

                // FIXME: Default color maybe comes from renderer?
                // FIXME: Duplicated with actual render lol
                var color = sphtud.math.Vec3{ 1, 1, 1 };
                if (p.fill) |fc| {
                    color = .{
                        @as(f32, @floatFromInt(fc[0])) / 255.0,
                        @as(f32, @floatFromInt(fc[1])) / 255.0,
                        @as(f32, @floatFromInt(fc[2])) / 255.0,
                    };
                }
                try paths.append(allocators.root.general(), .{
                    .color = color,
                    .path = render_path
                });
            },
        };

        break :blk .{ reader.view_box, paths };
    };

    var debug_widget = try DebugWidget.init(&allocators.root_gl, allocators.scratch.linear(), paths.items, view_box.width, view_box.height, &gui_state.image_renderer);

    var layout = try wf.makeLayout();
    // FIXME: Implement int dragger
    var width_slider = try wf.makeDragI32(&debug_widget.image_width, ids.output_width);
    try layout.append(&width_slider.widget);

    var height_slider = try wf.makeDragI32(&debug_widget.image_height, ids.output_height);
    try layout.append(&height_slider.widget);

    var point_color_picker = try wf.makeColorPicker(.white, ids.point_color);
    try layout.append(&point_color_picker.widget);

    var enters_color_picker = try wf.makeColorPicker(.white, ids.enters_color);
    try layout.append(&enters_color_picker.widget);

    var exits_color_picker = try wf.makeColorPicker(.white, ids.exits_color);
    try layout.append(&exits_color_picker.widget);

    const line_debug_label = try wf.makeLabel("line debug", .{});
    try layout.append(&line_debug_label.widget);

    var line_debug: i32 = 0;
    const line_debug_drag = try wf.makeDragI32(&line_debug, ids.line_debug_changed);
    try layout.append(&line_debug_drag.widget);

    try layout.append(&debug_widget.widget);

    const runner = try wf.makeRunner(&layout.widget);

    const start = try sphtud.io.clock_gettime(.BOOTTIME);

    var renderer = Renderer{
        .prog = try .init(&allocators.root_gl, solid_color_frag),
        .scratch_gl = &allocators.scratch_gl,
        .tl = .{ view_box.min_x, view_box.min_y },
        .br = .{ view_box.min_x + view_box.width, view_box.min_y + view_box.height },
    };


    enters_color_picker.color = debug_widget.enters_color;
    exits_color_picker.color = debug_widget.exits_color;

    try renderSvg(allocators.scratch.linear(), &renderer, paths.items, @intCast(debug_widget.image_width), @intCast(debug_widget.image_height), debug_widget.tex);

    while (!window.closed()) {
        allocators.resetScratch();

        gl.glClearColor(0, 0, 0, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const now = try sphtud.io.clock_gettime(.BOOTTIME);
        const elapsed_ns = start.durationTo(now).toNanoseconds();
        var elapsed_s: f32 = @floatFromInt(elapsed_ns);
        elapsed_s /= std.time.ns_per_s;

        try runner.step(elapsed_s, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        for (gui_state.event_queue.items) |event| switch (event) {
            ids.output_height, ids.output_width => {
                debug_widget.image_width = @max(0, debug_widget.image_width);
                debug_widget.image_height = @max(0, debug_widget.image_height);
                try renderSvg(allocators.scratch.linear(), &renderer, paths.items, @intCast(debug_widget.image_width), @intCast(debug_widget.image_height), debug_widget.tex);

            },
            ids.point_color => {
                debug_widget.point_color = point_color_picker.color;
            },
            ids.enters_color => {
                debug_widget.enters_color = enters_color_picker.color;
            },
            ids.exits_color => {
                debug_widget.exits_color = exits_color_picker.color;
            },
            ids.line_debug_changed => {
                std.debug.print("Hi\n\n\n", .{});
                // FIXME: So fricken heavily duped with Renderer
                const in_height_f = renderer.br[1] - renderer.tl[1];

                const out_height_f: f32 = @floatFromInt(debug_widget.image_height);

                const max_crosses = 1024;
                var cross_buf: [max_crosses]Renderer.PixelCross = undefined;
                var windings_buf: [max_crosses]Renderer.WindingChange = undefined;

                const cp = allocators.scratch.checkpoint();
                defer allocators.scratch.restore(cp);

                var enters_gl = std.ArrayList(sphtud.render.xyt_program.Vertex).empty;
                var exits_gl = std.ArrayList(sphtud.render.xyt_program.Vertex).empty;

                var in_y: f32 = @floatFromInt(line_debug);
                in_y *= in_height_f / out_height_f;

                for (paths.items) |path| {
                    var windings: std.ArrayList(Renderer.WindingChange) = .initBuffer(&windings_buf);
                    var contour_it = path.path.iter();
                    while (contour_it.next()) |contour| {
                        var sampler = Renderer.Sampler {
                            // FIXME: This may be unnecessary
                            .hysterisis_size = 0, //pixel_height / 8,
                            // FIXME: All of this should be initialized in a common way
                            // so we don't have to dupe everything here
                            .pixel_height = in_height_f / out_height_f,
                            .buf = &cross_buf,
                            .windings = &windings,
                            .contour = contour.*,
                        };

                        var segment_it = contour.iter();
                        while (segment_it.next()) |segment| {
                            std.debug.print("{any}\n", .{segment});
                        }
                        try sampler.executeScanline(in_y);

                        const crosses = sampler.buf[0..sampler.num_crosses];
                        for (crosses) |c| {
                            const y = switch (c.how) {
                                .enter_top, .leave_top => line_debug,
                                .enter_bottom, .leave_bottom => line_debug + 1,
                            };
                            const arr = switch (c.how) {
                                .enter_top, .enter_bottom => &enters_gl,
                                .leave_top, .leave_bottom => &exits_gl,
                            };

                            try arr.append(
                                allocators.scratch.allocator(),
                                DebugWidget.toVertex(.{c.x_pos, @floatFromInt(y)},
                                    view_box.width,
                                    out_height_f,
                            ));
                        }
                    }
                }

                debug_widget.enters_buf.updateBuffer(enters_gl.items);
                debug_widget.enters_source.bindData(debug_widget.path_program.handle(), debug_widget.enters_buf);
                debug_widget.exits_buf.updateBuffer(exits_gl.items);
                debug_widget.exits_source.bindData(debug_widget.path_program.handle(), debug_widget.exits_buf);
            },
            else => {},
        };

        gui_state.event_queue.clearRetainingCapacity();

        window.swapBuffers();
    }
}
