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
const svg_render_adapter = @import("svg_render_adapter.zig");
const CoordinateConverter = @import("CoordinateConverter.zig");

const Vec2 = sphtud.math.Vec2;

const ColoredPath = struct {
    color: sphtud.math.Vec3,
    path: Renderer.Path,
};

pub const Uniforms = struct {
    path_color: sphtud.math.Vec3,
    cross_enter_color: sphtud.math.Vec3,
    cross_exit_color: sphtud.math.Vec3,
    winding_up_color: sphtud.math.Vec3,
    winding_down_color: sphtud.math.Vec3,
    transform: sphtud.math.Mat3x3,
};

const Vertex = struct {
    vPos: sphtud.math.Vec2,
    vPurpose: u32,
};

pub const debug_vert =
    \\#version 330
    \\in vec2 vPos;
    \\in uint vPurpose;
    \\flat out uint purpose;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\    purpose = vPurpose;
    \\}
;

pub const debug_frag =
    \\#version 330
    \\out vec4 fragment;
    \\flat in uint purpose;
    \\uniform vec3 path_color;
    \\uniform vec3 cross_enter_color;
    \\uniform vec3 cross_exit_color;
    \\uniform vec3 winding_up_color;
    \\uniform vec3 winding_down_color;
    \\void main()
    \\{
    \\    vec3 color;
    \\    switch (purpose) {
    \\        case 0u: color = path_color; break;
    \\        case 1u: color = cross_enter_color; break;
    \\        case 2u: color = cross_exit_color; break;
    \\        case 3u: color = winding_up_color; break;
    \\        case 4u: color = winding_down_color; break;
    \\        default: break;
    \\    }
    \\    fragment = vec4(color, 1.0);
    \\}
;

pub const RenderPurpose = struct {
    const path = 0;
    const cross_enter = 1;
    const cross_exit = 2;
    const winding_up = 3;
    const winding_down = 4;
};

const Colors = struct {
    path: sphtud.ui.Color,
    cross_enter: sphtud.ui.Color,
    cross_exit: sphtud.ui.Color,
    winding_up: sphtud.ui.Color,
    winding_down: sphtud.ui.Color,
};

pub const Options = struct {
    colors: Colors,
    highlighted_line: i32,
    image_width: i32,
    image_height: i32,
    path_mask: std.DynamicBitSet,
    show_outlines: bool,
};

fn colorVec(color: sphtud.ui.Color) sphtud.math.Vec3 {
    return .{
        color.r,
        color.g,
        color.b,
    };
}

const xyt = sphtud.render.xyt_program;
const shader_program = sphtud.render.shader_program;

const LineHighlighter = struct {
    solid_color_program: *xyt.SolidColorProgram,
    highlight_line_source: xyt.RenderSource,

    pub fn init(gl_alloc: *sphtud.render.GlAlloc, solid_color_program: *xyt.SolidColorProgram) !LineHighlighter {
        // Width is in clip space, height is in output pixel space. Odd choice,
        // but it makes sense with how it's used
        //
        // With 1 pixel height, we can just adjust the height in pixel space,
        // however we don't want to hardcode the initial width of the image as
        // it can change
        const highlight_line_buf = try xyt.Buffer.init(gl_alloc, &.{
            .{ .vPos = .{ -1, 0 } },
            .{ .vPos = .{ 1, 0 } },
            .{ .vPos = .{ -1, 1 } },
            .{ .vPos = .{ 1, 1 } },
        });
        var highlight_line_source = try xyt.RenderSource.init(gl_alloc);
        highlight_line_source.bindData(solid_color_program.handle(), highlight_line_buf);

        return .{
            .solid_color_program = solid_color_program,
            .highlight_line_source = highlight_line_source,
        };
    }

    pub fn render(self: LineHighlighter, y: i32, image_height: i32, color: gui.Color, transform: sphtud.math.Transform) void {
        if (y < 0) return;
        const out_px_to_window_clip = sphtud.math.Transform.translate(0, asf32(y))
            .then(.scale(1, 2 / asf32(image_height)))
            .then(.translate(0, -1))
            .then(transform);

        self.solid_color_program.renderLines(self.highlight_line_source, .{
            .color = colorVec(color),
            .transform = out_px_to_window_clip.inner,
        });
    }
};

pub const DebugWidget = struct {
    options: *Options,

    tex: sphtud.render.Texture,
    zoom: f32,
    pan: sphtud.math.Vec2,
    panning: ?sphtud.ui.MousePos,

    mouse_pos_image_space: sphtud.math.Vec2,
    mouse_pos_changed: usize,
    event_queue: *gui.EventQueue,

    image_program: *sphtud.render.xyuvt_program.ImageRenderer,
    debug_program: shader_program.Program(Uniforms),
    line_highlighter: LineHighlighter,

    path_line_sources: []const shader_program.RenderSource,
    path_point_sources: []const shader_program.RenderSource,
    debug_line_points_buf: shader_program.Buffer(Vertex),
    debug_line_points_source: shader_program.RenderSource,

    solid_color_render_program: *sphtud.render.xyt_program.SolidColorProgram,
    circle_source: sphtud.render.xyt_program.RenderSource,

    widget: gui.Widget,

    pub fn init(
        alloc: sphtud.render.RenderAlloc,
        scratch: sphtud.alloc.LinearAllocator,
        paths: []const ColoredPath,
        options: *Options,
        in_width: f32,
        in_height: f32,
        mouse_pos_changed: usize,
        image_program: *sphtud.render.xyuvt_program.ImageRenderer,
        solid_color_program: *xyt.SolidColorProgram,
        event_queue: *gui.EventQueue,
    ) !DebugWidget {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const debug_program = try shader_program.Program(Uniforms).init(
            alloc.gl,
            debug_vert,
            debug_frag,
        );

        const path_sources = try makePathSources(
            alloc,
            scratch,
            paths,
            in_width,
            in_height,
            debug_program,
        );

        const point_sources = try makePointSources(
            alloc,
            scratch,
            paths,
            in_width,
            in_height,
            debug_program,
        );

        return .{
            .image_program = image_program,
            .debug_program = debug_program,
            .path_line_sources = path_sources,
            .path_point_sources = point_sources,
            .options = options,
            .debug_line_points_buf = try .init(alloc.gl, &.{}),
            .debug_line_points_source = try .init(alloc.gl),
            .tex = try sphtud.render.makeTextureCommon(alloc.gl),
            .line_highlighter = try .init(alloc.gl, solid_color_program),
            .zoom = 1.0,
            .pan = .{ 0, 0 },
            .panning = null,
            .mouse_pos_image_space = .{ 0, 0 },
            .mouse_pos_changed = mouse_pos_changed,
            .event_queue = event_queue,
            .solid_color_render_program = solid_color_program,
            .circle_source = undefined,
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

    fn toVertex(val: sphtud.math.Vec2, in_width: f32, in_height: f32, purpose: u32) Vertex {
        return .{
            .vPos = .{
                (val[0] / in_width) * 2 - 1,
                (val[1] / in_height) * 2 - 1,
            },
            .vPurpose = purpose,
        };
    }

    fn update(widget: *gui.Widget, available: gui.PixelSize, delta_s: f32) anyerror!void {
        const self: *DebugWidget = @alignCast(@fieldParentPtr("widget", widget));
        _ = delta_s;
        self.widget.size = available;
    }

    fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *DebugWidget = @alignCast(@fieldParentPtr("widget", widget));

        gl.glEnable(gl.GL_FRAMEBUFFER_SRGB);
        defer gl.glDisable(gl.GL_FRAMEBUFFER_SRGB);

        const scissor = sphtud.render.TemporaryScissor.init();
        defer scissor.reset();
        scissor.set(widget_bounds.left, window_bounds.bottom - widget_bounds.bottom, widget_bounds.calcWidth(), widget_bounds.calcHeight());

        const transform = self.imageClipToWindowClip(widget_bounds, window_bounds);

        self.image_program.renderTexture(self.tex, transform);

        gl.glLineWidth(5.0);

        //self.solid_color_render_program.renderPoints(self.circle_source, .{
        //    .transform = transform.inner,
        //    .color = .{ 1, 1, 1 },
        //});

        const uniforms = Uniforms{
            .path_color = colorVec(self.options.colors.path),
            .cross_enter_color = colorVec(self.options.colors.cross_enter),
            .cross_exit_color = colorVec(self.options.colors.cross_exit),
            .winding_up_color = colorVec(self.options.colors.winding_up),
            .winding_down_color = colorVec(self.options.colors.winding_down),
            .transform = transform.inner,
        };

        gl.glPointSize(20.0);

        if (self.options.show_outlines) {
            var it = self.options.path_mask.iterator(.{});
            while (it.next()) |path_id| {
                self.debug_program.renderLines(self.path_line_sources[path_id], uniforms);
                self.debug_program.renderPoints(self.path_point_sources[path_id], uniforms);
            }
        }

        self.debug_program.renderPoints(self.debug_line_points_source, uniforms);

        self.line_highlighter.render(
            self.options.highlighted_line,
            self.options.image_height,
            self.options.colors.path,
            transform,
        );
    }

    fn input(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) anyerror!void {
        const self: *DebugWidget = @alignCast(@fieldParentPtr("widget", widget));

        const mouse_in_bounds = input_bounds.containsMousePos(input_state.mouse_pos);

        if (mouse_in_bounds) {
            self.zoom *= std.math.pow(f32, 1.1, input_state.frame_scroll);
            input_state.consumeScroll();

            const window_px_to_output_image_pixel = sphtud.math.Transform.translate(
                // Move position relative to widget
                @floatFromInt(-widget_bounds.left), @floatFromInt(-widget_bounds.top)).then(
                // Move to widget clip width/height
                .scale(2.0 / asf32(widget_bounds.calcWidth()), -2.0 / asf32(widget_bounds.calcHeight())),
            ).then(.translate(-1, 1)) // offset for -1,1 (widget clip space)
                .then(self.imageClipToWidgetClip(widget_bounds).invert()) // move to image clip
                .then(.translate(1, 1)) // [-1,1] -> [0,2]
                // Scale so that [0,2] maps to [w,h]
                .then(.scale(asf32(self.options.image_width) / 2, asf32(self.options.image_height) / 2));

            self.mouse_pos_image_space = window_px_to_output_image_pixel.apply2(.{ input_state.mouse_pos.x, input_state.mouse_pos.y });
            try self.event_queue.appendBounded(self.mouse_pos_changed);
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
            self.pan += .{ x_movement_window * 0.005 / self.zoom, y_movement_window * 0.005 / self.zoom };
            last_pos.* = input_state.mouse_pos;
        }
    }

    fn imageClipToWidgetClip(self: *const DebugWidget, widget_bounds: gui.PixelBBox) sphtud.math.Transform {
        const widget_aspect = asf32(widget_bounds.calcWidth()) / asf32(widget_bounds.calcHeight());
        const image_aspect = asf32(self.options.image_width) / asf32(self.options.image_height);
        const aspect_transform = if (image_aspect < widget_aspect)
            sphtud.math.Transform.scale(image_aspect / widget_aspect, 1)
        else
            sphtud.math.Transform.scale(1, widget_aspect / image_aspect);

        return sphtud.math.Transform.translate(self.pan[0], self.pan[1])
            .then(aspect_transform)
            .then(.scale(1, -1))
            .then(.scale(self.zoom, self.zoom));
    }

    fn imageClipToWindowClip(self: *const DebugWidget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) sphtud.math.Transform {
        return self.imageClipToWidgetClip(widget_bounds)
            .then(sphtud.ui.util.widgetToClipTransform(widget_bounds, window_bounds));
    }

    fn makePathSources(
        alloc: sphtud.render.RenderAlloc,
        scratch: sphtud.alloc.LinearAllocator,
        paths: []const ColoredPath,
        in_width: f32,
        in_height: f32,
        debug_program: shader_program.Program(Uniforms),
    ) ![]const shader_program.RenderSource {
        const path_sources = try alloc.heap.arena().alloc(shader_program.RenderSource, paths.len);

        for (path_sources, paths) |*path_source, path| {
            const cp = scratch.checkpoint();
            defer scratch.restore(cp);

            var path_data = std.ArrayList(Vertex).empty;

            var it = Renderer.PathLineIter.init(&path.path);
            while (it.next()) |l| {
                try path_data.append(
                    scratch.allocator(),
                    DebugWidget.toVertex(l.a, in_width, in_height, RenderPurpose.path),
                );
                try path_data.append(
                    scratch.allocator(),
                    DebugWidget.toVertex(l.b, in_width, in_height, RenderPurpose.path),
                );
            }
            const path_buf = try shader_program.Buffer(Vertex).init(
                alloc.gl,
                path_data.items,
            );
            path_source.* = try shader_program.RenderSource.init(alloc.gl);
            path_source.bindData(Vertex, debug_program.handle, path_buf);
        }

        return path_sources;
    }

    fn makePointSources(
        alloc: sphtud.render.RenderAlloc,
        scratch: sphtud.alloc.LinearAllocator,
        paths: []const ColoredPath,
        in_width: f32,
        in_height: f32,
        debug_program: shader_program.Program(Uniforms),
    ) ![]const shader_program.RenderSource {
        const point_sources = try alloc.heap.arena().alloc(shader_program.RenderSource, paths.len);

        for (point_sources, paths) |*point_source, path| {
            const cp = scratch.checkpoint();
            defer scratch.restore(cp);

            var path_segment_points = std.ArrayList(Vertex).empty;

            var path_it = path.path.iter();
            while (path_it.next()) |contour| {
                var segment_it = contour.iter();
                while (segment_it.next()) |segment| {
                    const l: Renderer.Line = switch (segment.*) {
                        .line => |l| l,
                        .cubic_bezier => |c| .{ .a = c.start, .b = c.end },
                        .quad_bezier => |b| .{ .a = b.start, .b = b.end },
                        .arc => |arc| blk: {
                            const a = arc.applier();
                            break :blk .{
                                .a = a.apply(arc.start_theta),
                                .b = a.apply(arc.start_theta + arc.delta_theta),
                            };
                        },
                    };

                    try path_segment_points.append(
                        scratch.allocator(),
                        toVertex(l.a, in_width, in_height, RenderPurpose.path),
                    );
                    try path_segment_points.append(
                        scratch.allocator(),
                        toVertex(l.b, in_width, in_height, RenderPurpose.path),
                    );
                }
            }

            const point_buf = try shader_program.Buffer(Vertex).init(
                alloc.gl,
                path_segment_points.items,
            );
            point_source.* = try shader_program.RenderSource.init(alloc.gl);
            point_source.bindData(Vertex, debug_program.handle, point_buf);
        }

        return point_sources;
    }
};

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

const Ids = struct {
    output_width: usize,
    output_height: usize,
    gpu_toggle: usize,
    outline_color: usize,
    enters_color: usize,
    exits_color: usize,
    line_debug_changed: usize,
    show_outlines_changed: usize,
    mouse_pos_changed: usize,
    enable_path: sphtud.util.IdAlloc.Range,

    fn init() Ids {
        var alloc = sphtud.util.IdAlloc.init;
        return .{
            .output_width = alloc.allocOne(),
            .output_height = alloc.allocOne(),
            .gpu_toggle = alloc.allocOne(),
            .outline_color = alloc.allocOne(),
            .line_debug_changed = alloc.allocOne(),
            .enters_color = alloc.allocOne(),
            .exits_color = alloc.allocOne(),
            .show_outlines_changed = alloc.allocOne(),
            .mouse_pos_changed = alloc.allocOne(),
            .enable_path = alloc.allocMany(1024),
        };
    }
};

const ids = Ids.init();

pub fn renderSvgGpu(
    scratch: sphtud.alloc.LinearAllocator,
    scratch_gl: *sphtud.render.GlAlloc,
    gen_points_compute_program: gl.GLuint,
    render_program: sphtud.render.xyt_program.SolidColorProgram,
    paths: []const ColoredPath,
    br: Renderer.Point,
    tl: Renderer.Point,
    output_width: u31,
    output_height: u31,
    tex: sphtud.render.Texture,
) !void {
    const gl_cp = scratch_gl.checkpoint();
    defer scratch_gl.restore(gl_cp);

    const cc = CoordinateConverter{
        .in_width = br[0] - tl[0],
        .in_height = br[1] - tl[1],
        .out_width = @floatFromInt(output_width),
        .out_height = @floatFromInt(output_height),
    };

    sphtud.render.setTextureSize(tex, output_width, output_height, .rgbaf32);

    // Once per contour
    const contour = paths[2].path.get(1);
    const f32_storage, const items, const out_len = blk2: {
        const cp = scratch.checkpoint();
        defer scratch.restore(cp);

        const compute_buffers = try ContourComputeBuffers.init(scratch.allocator(), contour);

        break :blk2 .{
            try sphtud.render.shader_program.Buffer(f32).init(scratch_gl, compute_buffers.f32_storage),
            try sphtud.render.shader_program.Buffer(ContourComputeBuffers.Item).init(scratch_gl, compute_buffers.items),
            compute_buffers.out_len,
        };
    };

    const Output = extern struct {
        x: f32,
        // FIXME: Y might be implicit
        y: f32,
        in_typ: u32,
        positive: u16,
        valid: u16,
    };

    const buf = try scratch_gl.createBuffer();
    const num_scanlines = output_height;
    const buf_size_elems = out_len * num_scanlines;
    const buf_size_bytes = buf_size_elems * @sizeOf(Output);
    // FIXME: Surely we should be using the named versions of these right?
    gl.glBindBuffer(gl.GL_SHADER_STORAGE_BUFFER, buf);
    gl.glBufferData(gl.GL_SHADER_STORAGE_BUFFER, buf_size_bytes, null, gl.GL_DYNAMIC_DRAW);

    gl.glUseProgram(gen_points_compute_program);
    gl.glBindBufferBase(gl.GL_SHADER_STORAGE_BUFFER, 0, f32_storage.vertex_buffer);
    gl.glBindBufferBase(gl.GL_SHADER_STORAGE_BUFFER, 1, items.vertex_buffer);
    gl.glBindBufferBase(gl.GL_SHADER_STORAGE_BUFFER, 2, buf);



    gl.glUniform1ui(0, out_len);
    const scanline_height = cc.out_height / cc.in_height;
    gl.glUniform1f(1, scanline_height);

    gl.glDispatchCompute(@intCast(items.len), num_scanlines, 1);
    std.debug.print("Num items: {d}\n", .{items.len});

    // Idiot says we need this, didn't think about it
    gl.glMemoryBarrier(gl.GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT | gl.GL_SHADER_STORAGE_BARRIER_BIT);

    //const read_back = try scratch.allocator().alloc(Output, buf_size_elems);
    //gl.glGetBufferSubData(gl.GL_SHADER_STORAGE_BUFFER, 0, buf_size_bytes, read_back.ptr);

    const image_to_gl_transform = sphtud.math.Transform.scale(
        2.0 / cc.in_width,
        2.0 / cc.in_height,
    ).then(
        .translate(-1, -1),
    );

    //for (read_back) |val| {
    //    if (val.valid == 0) continue;
    //    if (val.in_typ != 3) continue;
    //    const transformed = image_to_gl_transform.apply(.{
    //        val.x, val.y, 1,
    //    });
    //    std.debug.print("{any} ({any}\n", .{val, transformed});
    //}
    //std.debug.print("out len: {d}\n", .{out_len});

    const vao = try scratch_gl.createArray();
    // 0. copy our vertices array in a buffer for OpenGL to use
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buf);
    gl.glBindVertexArray(vao);
    // 1. then set the vertex attributes pointers
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Output), null);
    gl.glEnableVertexAttribArray(0);

    const render_source = sphtud.render.xyt_program.RenderSource{
        .inner = .{
            .vao = vao,
            .index_type = null,
            .len = out_len * num_scanlines,
        },
    };

    //var floats: [20 * 4]f32 = undefined;
    //gl.glGetNamedBufferSubData(buf, 0, 20 * 4 * 4, &floats);
    //for (0..20) |i| {
    //    std.debug.print("{any}\n", .{floats[i * 4..][0..4]});
    //}
    //

    var fb = try sphtud.render.FramebufferRenderContext.init(tex, null);
    defer fb.reset();

    var tmp_viewport = sphtud.render.TemporaryViewport.init();
    defer tmp_viewport.reset();
    tmp_viewport.setViewport(output_width, output_height);

    gl.glClearColor(0, 0, 0, 0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    gl.glPointSize(4.0);

    render_program.renderPoints(render_source, .{
        .color = .{1, 1, 1},
        .transform = image_to_gl_transform.inner,
    });
}

pub fn renderSvg(
    scratch: sphtud.alloc.LinearAllocator,
    renderer: *Renderer,
    paths: []const ColoredPath,
    enable_paths: std.bit_set.DynamicBitSet,
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

    for (paths, 0..) |path, i| {
        if (!enable_paths.isSet(i)) continue;
        try renderer.renderPathToImage(path.path, path.color, img);
    }

    sphtud.render.setTextureFromSrgb(tex, img.data.rgba_8888.data, output_width);
}

fn executeLineDebug(
    scratch: sphtud.alloc.LinearAllocator,
    renderer: *Renderer,
    debug_widget: *DebugWidget,
    paths: []const ColoredPath,
) !void {
    const options = debug_widget.options;
    const highlighted_line = options.highlighted_line;

    const cp = scratch.checkpoint();
    defer scratch.restore(cp);

    var line_gl = std.ArrayList(Vertex).empty;

    const cc = CoordinateConverter{
        .in_width = renderer.br[0] - renderer.tl[0],
        .in_height = renderer.br[1] - renderer.tl[1],
        .out_width = @floatFromInt(options.image_width),
        .out_height = @floatFromInt(options.image_height),
    };

    for (paths, 0..) |path, path_id| {
        if (!options.path_mask.isSet(path_id)) continue;
        var wcc: Renderer.WindingChangeCalculator = undefined;
        wcc.initPinned(
            cc.pixelHeight(),
            cc.outputToInputY(@floatFromInt(highlighted_line)),
            path.path,
        );

        const windings = try wcc.calculateWindingChanges();

        const crosses = wcc.crosses_buf[0..wcc.num_crosses];
        for (crosses) |c| {
            const y = switch (c.how) {
                .enter_top, .leave_top => highlighted_line,
                .enter_bottom, .leave_bottom => highlighted_line + 1,
            };
            const purpose: u32 = switch (c.how) {
                .enter_top, .enter_bottom => RenderPurpose.cross_enter,
                .leave_top, .leave_bottom => RenderPurpose.cross_exit,
            };

            try line_gl.append(scratch.allocator(), DebugWidget.toVertex(
                .{ c.x_pos, @floatFromInt(y) },
                cc.in_width,
                cc.out_height,
                purpose,
            ));
        }

        for (windings) |wc| {
            const purpose: u32 = if (wc.change > 0)
                RenderPurpose.winding_up
            else
                RenderPurpose.winding_down;

            try line_gl.append(scratch.allocator(), DebugWidget.toVertex(
                .{ wc.pos, asf32(highlighted_line) + 0.5 },
                cc.in_width,
                cc.out_height,
                purpose,
            ));
        }
    }

    debug_widget.debug_line_points_buf.updateBuffer(line_gl.items);
    debug_widget.debug_line_points_source.bindData(Vertex, debug_widget.debug_program.handle, debug_widget.debug_line_points_buf);
}

const Gui = struct {
    debug_widget: *DebugWidget,
    enters_color_picker: *gui.ColorPicker,
    exits_color_picker: *gui.ColorPicker,
    path_color_picker: *gui.ColorPicker,
    width_slider: gui.DragI32,
    height_slider: gui.DragI32,
    line_debug_drag: gui.DragI32,
    show_outlines: *gui.Checkbox,
    gui_state: *gui.WidgetState,
    mouse_pos_in_label: *gui.Label,
    mouse_pos_out_label: *gui.Label,
    gpu_checkbox: *gui.Checkbox,
    runner: *gui.Runner,

    pub fn init(
        alloc: gui.GuiAlloc,
        scratch: *sphtud.alloc.BufAllocator,
        scratch_gl: *sphtud.render.GlAlloc,
        paths: []const ColoredPath,
        options: *Options,
        view_box: SvgReader.ViewBox,
    ) !Gui {
        const font_size = 16;
        const gui_state = try gui.WidgetState.init(
            alloc,
            scratch,
            scratch_gl,
            .{
                .font_size = font_size,
            },
        );

        const wf = gui.WidgetFactory{
            .alloc = alloc,
            .state = gui_state,
        };

        const solid_color_program = try alloc.heap.arena().create(xyt.SolidColorProgram);
        solid_color_program.* = try xyt.solidColorProgram(alloc.gl);

        const debug_widget = try alloc.heap.arena().create(DebugWidget);
        debug_widget.* = try DebugWidget.init(
            alloc,
            scratch.linear(),
            paths,
            options,
            view_box.width,
            view_box.height,
            ids.mouse_pos_changed,
            &gui_state.image_renderer,
            solid_color_program,
            &gui_state.event_queue,
        );

        var layout = try wf.makeLayout();
        layout.cursor.direction = .left_to_right;

        var prop_grid = try wf.makeGrid(&.{
            .{ .width = .{ .fixed = 100 }, .horizontal_justify = .left, .vertical_justify = .center },
            .{ .width = .{ .ratio = 1.0 }, .horizontal_justify = .center, .vertical_justify = .center },
        });

        const sidebar = try wf.makeBox(
            .asWidget(try wf.makeStack(
                try alloc.heap.arena().dupe(
                    gui.Stack.StackItem,
                    &.{ .{ .widget = .asWidget(try wf.makeRect(gui.WidgetState.StyleColors.background_color)) }, .{
                        .widget = &prop_grid.widget,
                    } },
                ),
            )),
            .{ .width = font_size * 20, .height = 0 },
            .fill_height,
        );
        try layout.append(.asWidget(sidebar));

        try prop_grid.append(.asWidget(try wf.makeLabel("width", .{})));

        const width_slider = try wf.makeDragI32(options.image_width, ids.output_width);
        try prop_grid.append(&width_slider.drag.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("height", .{})));

        var height_slider = try wf.makeDragI32(options.image_height, ids.output_height);
        try prop_grid.append(&height_slider.drag.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("gpu", .{})));
        const gpu_checkbox = try wf.makeCheckbox(false, ids.gpu_toggle);
        try prop_grid.append(&gpu_checkbox.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("outline", .{})));
        var path_color_picker = try wf.makeColorPicker(.white, ids.outline_color);
        try prop_grid.append(&path_color_picker.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("line enter", .{})));
        var enters_color_picker = try wf.makeColorPicker(.white, ids.enters_color);
        try prop_grid.append(&enters_color_picker.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("line exit", .{})));
        var exits_color_picker = try wf.makeColorPicker(.white, ids.exits_color);
        try prop_grid.append(&exits_color_picker.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("line debug", .{})));

        const line_debug_drag = try wf.makeDragI32(options.highlighted_line, ids.line_debug_changed);
        try prop_grid.append(&line_debug_drag.drag.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("show outlines", .{})));
        const show_outlines = try wf.makeCheckbox(options.show_outlines, ids.show_outlines_changed);
        try prop_grid.append(&show_outlines.widget);

        for (0..paths.len) |i| {
            var label_buf: [128]u8 = undefined;
            try prop_grid.append(.asWidget(try wf.makeLabel(
                try std.fmt.bufPrint(&label_buf, "path {d}", .{i}),
                .{},
            )));

            try prop_grid.append(.asWidget(
                try wf.makeCheckbox(true, ids.enable_path.start + i),
            ));
        }

        try prop_grid.append(.asWidget(try wf.makeLabel("hovered pixel (in)", .{})));
        const mouse_pos_in_label = try wf.makeLabel("", .{});
        try prop_grid.append(&mouse_pos_in_label.widget);

        try prop_grid.append(.asWidget(try wf.makeLabel("hovered pixel (out)", .{})));
        const mouse_pos_out_label = try wf.makeLabel("", .{});
        try prop_grid.append(&mouse_pos_out_label.widget);

        try layout.append(&debug_widget.widget);

        const runner = try wf.makeRunner(&layout.widget);

        enters_color_picker.color = options.colors.cross_enter;
        exits_color_picker.color = options.colors.cross_exit;
        path_color_picker.color = options.colors.path;

        return .{
            .gui_state = gui_state,
            .width_slider = width_slider,
            .height_slider = height_slider,
            .line_debug_drag = line_debug_drag,
            .debug_widget = debug_widget,
            .exits_color_picker = exits_color_picker,
            .enters_color_picker = enters_color_picker,
            .path_color_picker = path_color_picker,
            .show_outlines = show_outlines,
            .mouse_pos_in_label = mouse_pos_in_label,
            .mouse_pos_out_label = mouse_pos_out_label,
            .gpu_checkbox = gpu_checkbox,
            .runner = runner,
        };
    }
};

const compute_shader_src =
    \\#version 430 core
    \\layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
    \\layout(std430, binding = 0) buffer vertOut {
    \\    vec4 pos[]; // xyz = position, w = 1
    \\};
    \\
    \\const int num_segments = 20;
    \\const float radius = 0.5;
    \\void main() {
    \\    uint i = gl_GlobalInvocationID.x;
    \\
    \\    if (i > num_segments) return;
    \\
    \\    float t = float(i) / float(num_segments) * 6.28318530718; // 2*pi
    \\    vec3 p = vec3(cos(t) * radius, sin(t) * radius, 0.0);
    \\
    \\    pos[i] = vec4(p, 1.0);
    \\}
;

const ContourComputeBuffers = struct {
    f32_storage: []f32,
    items: []Item,
    out_len: u32,

    // max params Arc == 7

    pub fn init(alloc: std.mem.Allocator, contour: Renderer.Contour) !ContourComputeBuffers {
        // Max floats per item is 8 by cubic bezier
        var f32_storage = try std.ArrayList(f32).initCapacity(alloc, 8 * contour.len);
        var items = try std.ArrayList(Item).initCapacity(alloc, contour.len);

        var out_idx: u32 = 0;

        var it = contour.iter();
        while (it.next()) |segment| switch (segment.*) {
            .line => |l| {
                items.appendBounded(.{
                    .arg_start_offs = @intCast(f32_storage.items.len),
                    // FIXME: Shared constants somewhere?
                    .typ = 0,
                    .out_idx = out_idx,
                }) catch unreachable;
                f32_storage.appendBounded(l.a[0]) catch unreachable;
                f32_storage.appendBounded(l.a[1]) catch unreachable;
                f32_storage.appendBounded(l.b[0]) catch unreachable;
                f32_storage.appendBounded(l.b[1]) catch unreachable;
                // FIXME: Shared constants somewhere?
                out_idx += 1;
            },
            .quad_bezier => |qb| {
                items.appendBounded(.{
                    .arg_start_offs = @intCast(f32_storage.items.len),
                    .typ = 1,
                    .out_idx = out_idx,
                }) catch unreachable;
                f32_storage.appendBounded(qb.start[0]) catch unreachable;
                f32_storage.appendBounded(qb.start[1]) catch unreachable;
                f32_storage.appendBounded(qb.c[0]) catch unreachable;
                f32_storage.appendBounded(qb.c[1]) catch unreachable;
                f32_storage.appendBounded(qb.end[0]) catch unreachable;
                f32_storage.appendBounded(qb.end[1]) catch unreachable;

                // FIXME: Shared constants somewhere?
                out_idx += 2;
            },
            .cubic_bezier => |cb| {
                items.appendBounded(.{
                    .arg_start_offs = @intCast(f32_storage.items.len),
                    // FIXME: Shared constants somewhere?
                    .typ = 2,
                    .out_idx = out_idx,
                }) catch unreachable;
                f32_storage.appendBounded(cb.start[0]) catch unreachable;
                f32_storage.appendBounded(cb.start[1]) catch unreachable;
                f32_storage.appendBounded(cb.c1[0]) catch unreachable;
                f32_storage.appendBounded(cb.c1[1]) catch unreachable;
                f32_storage.appendBounded(cb.c2[0]) catch unreachable;
                f32_storage.appendBounded(cb.c2[1]) catch unreachable;
                f32_storage.appendBounded(cb.end[0]) catch unreachable;
                f32_storage.appendBounded(cb.end[1]) catch unreachable;

                // FIXME: Shared constants somewhere?
                out_idx += 3;
            },
            .arc => |arc| {
                items.appendBounded(.{
                    .arg_start_offs = @intCast(f32_storage.items.len),
                    // FIXME: Shared constants somewhere?
                    .typ = 3,
                    .out_idx = out_idx,
                }) catch unreachable;
                f32_storage.appendBounded(arc.rot) catch unreachable;
                f32_storage.appendBounded(arc.rx) catch unreachable;
                f32_storage.appendBounded(arc.ry) catch unreachable;
                f32_storage.appendBounded(arc.center[0]) catch unreachable;
                f32_storage.appendBounded(arc.center[1]) catch unreachable;
                f32_storage.appendBounded(arc.start_theta) catch unreachable;
                f32_storage.appendBounded(arc.delta_theta) catch unreachable;

                // FIXME: Shared constants somewhere?
                out_idx += 2;
            },
        };

        return .{
            .f32_storage = f32_storage.items,
            .items = items.items,
            .out_len = out_idx,
        };
    }

    // FIXME: Arguably this should pack the same no matter what architecture
    // we're on
    const Item = extern struct {
        arg_start_offs: u32,
        typ: u32,
        out_idx: u32,
    };

    comptime {
        std.debug.assert(@offsetOf(Item, "arg_start_offs") == 0);
        std.debug.assert(@offsetOf(Item, "typ") == 4);
        std.debug.assert(@offsetOf(Item, "out_idx") == 8);
    }
};

fn genGenPointsComputeProgram(gl_alloc: *sphtud.render.GlAlloc) !gl.GLuint {
    // FIXME: does it make sense to have gl_alloc.createShader() + batch free
    // eh it's probably fine
    const compute_shader = gl.glCreateShader(gl.GL_COMPUTE_SHADER);
    defer gl.glDeleteShader(compute_shader);

    gl.glShaderSource(compute_shader, 1, @ptrCast(&compute_shader_src), null);
    const shader_binary = @embedFile("shader.spv");
    gl.glShaderBinary(1, &compute_shader, gl.GL_SHADER_BINARY_FORMAT_SPIR_V_ARB, shader_binary, shader_binary.len);
    gl.glCompileShader(compute_shader);
    gl.glSpecializeShader(compute_shader, "main", 0, 0, 0);

    var compiled: c_int = 0;
    gl.glGetShaderiv(compute_shader, gl.GL_COMPILE_STATUS, &compiled);
    if (compiled == 0)
        return error.CompilationFailed;

    const program = try gl_alloc.createProgram();
    gl.glAttachShader(program, compute_shader);
    gl.glLinkProgram(program);
    try sphtud.render.checkProgramLink(program);

    return program;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const filename = args.next() orelse return error.NoFile;

    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 1100, 800);

    try sphtud.render.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const view_box, const paths = blk: {
        var paths = std.ArrayList(ColoredPath).empty;

        const f = try sphtud.io.open(filename, .{}, 0);
        defer sphtud.io.close(f);

        var buf: [4096]u8 = undefined;
        var data_r = sphtud.io.Reader.init(f, &buf);

        var reader = try SvgReader.init(&data_r.interface);

        //var path = ColoredPath {
        //    .color = .{1, 1, 1},
        //    .path = try .init(allocators.root.arena(), allocators.root.expansion(), 1, 1),
        //};
        //var contour = try Renderer.Contour.init(allocators.root.arena(), allocators.root.expansion(), 1, 20);
        //try contour.append(
        //    .{ .cubic_bezier = .{
        //        .start = .{ 1.3983617, 95.18179 },
        //        .c1 = .{ 4.173891, 98.73849 },
        //        .c2 = .{ 10.066898, 98.741554 },
        //        .end = .{ 14.451845, 95.19817 },
        //    } });
        //try path.path.append(contour);
        //try paths.append(allocators.root.general(), path);

        while (try reader.next()) |item| switch (item) {
            .path => |p| {
                const render_path = try svg_render_adapter.svgPathToRenderPath(allocators.root.arena(), allocators.root.expansion(), p);

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
                try paths.append(allocators.root.general(), .{ .color = color, .path = render_path });
            },
        };

        break :blk .{ reader.view_box, paths };
    };

    for (paths.items) |path| {
        var it = path.path.iter();
        while (it.next()) |contour| {
            var contour_it = contour.iter();
            while (contour_it.next()) |segment| {
                std.debug.print("{any}\n", .{segment});
            }
        }
    }

    const gen_points_compute_program = try genGenPointsComputeProgram(&allocators.root_gl);

    const generated_circle = blk: {

        // Once per contour
        const contour = paths.items[2].path.get(1);
        const f32_storage, const items, const out_len = blk2: {
            const cp = allocators.scratch.checkpoint();
            defer allocators.scratch.restore(cp);

            const compute_buffers = try ContourComputeBuffers.init(allocators.scratch.allocator(), contour);

            break :blk2 .{
                try sphtud.render.shader_program.Buffer(f32).init(&allocators.root_gl, compute_buffers.f32_storage),
                try sphtud.render.shader_program.Buffer(ContourComputeBuffers.Item).init(&allocators.root_gl, compute_buffers.items),
                compute_buffers.out_len,
            };
        };

        const Output = extern struct {
            x: f32,
            // FIXME: Y might be implicit
            y: f32,
            in_typ: u32,
            positive: u16,
            valid: u16,
        };

        const buf = try allocators.root_gl.createBuffer();
        const num_scanlines = 100;
        const buf_size_elems = out_len * num_scanlines;
        const buf_size_bytes = buf_size_elems * @sizeOf(Output);
        // FIXME: Surely we should be using the named versions of these right?
        gl.glBindBuffer(gl.GL_SHADER_STORAGE_BUFFER, buf);
        gl.glBufferData(gl.GL_SHADER_STORAGE_BUFFER, buf_size_bytes, null, gl.GL_DYNAMIC_DRAW);

        gl.glUseProgram(gen_points_compute_program);
        gl.glBindBufferBase(gl.GL_SHADER_STORAGE_BUFFER, 0, f32_storage.vertex_buffer);
        gl.glBindBufferBase(gl.GL_SHADER_STORAGE_BUFFER, 1, items.vertex_buffer);
        gl.glBindBufferBase(gl.GL_SHADER_STORAGE_BUFFER, 2, buf);
        gl.glUniform1ui(0, out_len);

        gl.glDispatchCompute(@intCast(items.len), num_scanlines, 1);
        std.debug.print("Num items: {d}\n", .{items.len});

        // Idiot says we need this, didn't think about it
        gl.glMemoryBarrier(gl.GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT | gl.GL_SHADER_STORAGE_BARRIER_BIT);

        const read_back = try allocators.scratch.allocator().alloc(Output, buf_size_elems);
        gl.glGetBufferSubData(gl.GL_SHADER_STORAGE_BUFFER, 0, buf_size_bytes, read_back.ptr);

        for (read_back) |val| {
            if (val.valid == 0) continue;
            if (val.in_typ != 3) continue;
            std.debug.print("{any}\n", .{val});
        }
        std.debug.print("out len: {d}\n", .{out_len});

        const vao = try allocators.root_gl.createArray();
        // 0. copy our vertices array in a buffer for OpenGL to use
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, buf);
        gl.glBindVertexArray(vao);
        // 1. then set the vertex attributes pointers
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, @sizeOf(Output), null);
        gl.glEnableVertexAttribArray(0);

        break :blk sphtud.render.xyt_program.RenderSource{
            .inner = .{
                .vao = vao,
                .index_type = null,
                .len = out_len * num_scanlines,
            },
        };

        //var floats: [20 * 4]f32 = undefined;
        //gl.glGetNamedBufferSubData(buf, 0, 20 * 4 * 4, &floats);
        //for (0..20) |i| {
        //    std.debug.print("{any}\n", .{floats[i * 4..][0..4]});
        //}
        //
    };

    var renderer = Renderer{
        .tl = .{ view_box.min_x, view_box.min_y },
        .br = .{ view_box.min_x + view_box.width, view_box.min_y + view_box.height },
    };

    var options = Options{
        .colors = .{
            .path = .white,
            .cross_enter = .{ .r = 1, .g = 0, .b = 1, .a = 1 },
            .cross_exit = .{ .r = 0, .g = 0, .b = 1, .a = 1 },
            .winding_up = .{ .r = 0, .g = 1, .b = 0, .a = 1 },
            .winding_down = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
        },
        .image_width = 200,
        .image_height = 200,
        .highlighted_line = -1,
        .path_mask = try std.DynamicBitSet.initFull(allocators.root.arena(), paths.items.len),
        .show_outlines = false,
    };

    const ui = try Gui.init(
        try allocators.root_render.makeSubAlloc("gui"),
        &allocators.scratch,
        &allocators.scratch_gl,
        paths.items,
        &options,
        view_box,
    );

    const start = try sphtud.io.clock_gettime(.BOOTTIME);

    try renderSvg(
        allocators.scratch.linear(),
        &renderer,
        paths.items,
        options.path_mask,
        @intCast(options.image_width),
        @intCast(options.image_height),
        ui.debug_widget.tex,
    );

    ui.debug_widget.circle_source = generated_circle;

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

        try ui.runner.step(elapsed_s, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        var wants_rerender = false;
        var wants_line_debug = false;
        for (ui.gui_state.event_queue.items) |event| switch (event) {
            ids.output_width => {
                if (try ui.width_slider.update(&options.image_width)) {
                    options.image_width = @max(0, options.image_width);
                    wants_rerender = true;
                }
            },
            ids.output_height => {
                if (try ui.height_slider.update(&options.image_height)) {
                    options.image_height = @max(0, options.image_height);
                    wants_rerender = true;
                }
            },
            ids.outline_color => {
                options.colors.path = ui.path_color_picker.color;
            },
            ids.enters_color => {
                options.colors.cross_enter = ui.enters_color_picker.color;
            },
            ids.exits_color => {
                options.colors.cross_exit = ui.exits_color_picker.color;
            },
            ids.line_debug_changed => {
                if (try ui.line_debug_drag.update(&options.highlighted_line)) {
                    options.highlighted_line = @max(-1, options.highlighted_line);
                    wants_line_debug = true;
                }
            },
            ids.enable_path.start...ids.enable_path.end => {
                const idx = event - ids.enable_path.start;
                options.path_mask.toggle(idx);
                wants_rerender = true;
            },
            ids.show_outlines_changed => {
                options.show_outlines = ui.show_outlines.checked;
            },
            ids.mouse_pos_changed => {
                var buf: [128]u8 = undefined;
                var text = try std.fmt.bufPrint(&buf, "{d:.2},{d:.2}", .{ ui.debug_widget.mouse_pos_image_space[0], ui.debug_widget.mouse_pos_image_space[1] });
                try ui.mouse_pos_out_label.setText(text);

                const cc = CoordinateConverter{
                    .in_width = renderer.br[0] - renderer.tl[0],
                    .in_height = renderer.br[1] - renderer.tl[1],
                    .out_width = @floatFromInt(options.image_width),
                    .out_height = @floatFromInt(options.image_height),
                };

                const in_x = cc.outputToInputY(ui.debug_widget.mouse_pos_image_space[0]);
                const in_y = cc.outputToInputY(ui.debug_widget.mouse_pos_image_space[1]);

                text = try std.fmt.bufPrint(&buf, "{d:.2},{d:.2}", .{ in_x, in_y });
                try ui.mouse_pos_in_label.setText(text);
            },
            ids.gpu_toggle => {
                wants_rerender |= true;
                std.debug.print("{any}\n", .{ui.gpu_checkbox.checked});
            },
            else => unreachable,
        };

        wants_line_debug |= wants_rerender;

        ui.gui_state.event_queue.clearRetainingCapacity();
        if (wants_rerender) {
            if (ui.gpu_checkbox.checked) {
                try renderSvgGpu(
                    allocators.scratch.linear(),
                    &allocators.scratch_gl,
                    gen_points_compute_program,
                    ui.debug_widget.solid_color_render_program.*,
                    paths.items,
                    renderer.br,
                    renderer.tl,
                    @intCast(options.image_width),
                    @intCast(options.image_height),
                    ui.debug_widget.tex,
                );
            } else {
                try renderSvg(
                    allocators.scratch.linear(),
                    &renderer,
                    paths.items,
                    options.path_mask,
                    @intCast(options.image_width),
                    @intCast(options.image_height),
                    ui.debug_widget.tex,
                );
            }
        }

        if (wants_line_debug) {
            try executeLineDebug(
                allocators.scratch.linear(),
                &renderer,
                ui.debug_widget,
                paths.items,
            );
        }

        window.swapBuffers();
    }
}
