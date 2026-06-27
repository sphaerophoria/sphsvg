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

const Vec2 = sphtud.math.Vec2;

fn applyTransformVec2(v: Vec2, transform: sphtud.math.Transform) Vec2 {
    const ret = transform.apply(.{v[0], v[1], 1});
    return .{ ret[0] / ret[2], ret[1] / ret[2] };
}

pub const HitTestWidget = struct {
    render_program: sphtud.render.xyt_program.SolidColorProgram,

    ray_buf: sphtud.render.xyt_program.Buffer,
    ray_source: sphtud.render.xyt_program.RenderSource,
    ray: sphtud.geometry.Ray2,

    circle: sphtud.geometry.Ellipse,
    circle_buf: sphtud.render.xyt_program.Buffer,
    circle_source: sphtud.render.xyt_program.RenderSource,

    intersections_buf: sphtud.render.xyt_program.Buffer,
    intersections_source: sphtud.render.xyt_program.RenderSource,

    widget: gui.Widget,

    down_mask: u8,

    pub fn init(alloc: sphtud.ui.GuiAlloc) !HitTestWidget {
        var ret = HitTestWidget{
            .render_program = try sphtud.render.xyt_program.solidColorProgram(alloc.gl),
            .ray_buf = try .init(alloc.gl, &.{}),
            .ray_source = try .init(alloc.gl),
            .ray = .{
                .start = .{ -0.5, 0 },
                .dir = .{ 1.0, 0.0 },
            },
            .circle = .{
                .center = .{ 0.0, 0.0 },
                .rx = 0.5,
                .ry = 0.5,
                .rotation = 0,
            },
            .circle_buf = try .init(alloc.gl, &.{}),
            .circle_source = try .init(alloc.gl),
            .intersections_buf = try .init(alloc.gl, &.{}),
            .intersections_source = try .init(alloc.gl),
            .down_mask = 0,
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
        ret.updateRender();

        return ret;
    }

    fn update(widget: *gui.Widget, available: gui.PixelSize, delta_s: f32) anyerror!void {
        const self: *HitTestWidget = @alignCast(@fieldParentPtr("widget", widget));
        _ = delta_s;
        self.widget.size = available;
    }

    fn render(widget: *gui.Widget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *HitTestWidget = @alignCast(@fieldParentPtr("widget", widget));
        const transform = sphtud.ui.util.widgetToClipTransform(widget_bounds, window_bounds);

        const scissor = sphtud.render.TemporaryScissor.init();
        defer scissor.reset();
        scissor.set(widget_bounds.left, window_bounds.bottom - widget_bounds.bottom, widget_bounds.calcWidth(), widget_bounds.calcHeight());

        gl.glLineWidth(5.0);
        gl.glPointSize(20.0);

        self.render_program.renderLineLoop(self.circle_source, .{
            .color = .{1, 1, 1 },
            .transform = transform.inner,
        });

        self.render_program.renderLines(self.ray_source, .{
            .color = .{0, 1, 0 },
            .transform = transform.inner,
        });

        self.render_program.renderPoints(self.intersections_source, .{
            .color = .{1, 0, 0 },
            .transform = transform.inner,
        });
    }

    fn input(widget: *gui.Widget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: *gui.InputState) anyerror!void {
        const self: *HitTestWidget = @alignCast(@fieldParentPtr("widget", widget));
        if (input_bounds.containsMousePos(input_state.mouse_pos)) {
            if (input_state.mouse_pressed) {
                self.down_mask |= 1;
            }

            if (input_state.mouse_right_pressed) {
                self.down_mask |= 2;
            }


            if (input_state.mouse_middle_pressed) {
                self.circle.center = mouseToClip(input_state.mouse_pos, widget_bounds);
                self.updateRender();
            }
        }

        if (input_state.mouse_released) {
            self.down_mask &= ~@as(u8, 1);
        }

        if (input_state.mouse_right_released) {
            self.down_mask &= ~@as(u8, 2);
        }


        if (self.down_mask & 1 != 0) {
            self.ray.start = mouseToClip(input_state.mouse_pos, widget_bounds);
            self.updateRender();
        }

        if (self.down_mask & 2 != 0) {
            const ray_end = mouseToClip(input_state.mouse_pos, widget_bounds);
            self.ray.dir = sphtud.math.normalize(ray_end - self.ray.start);
            self.updateRender();
        }
    }

    fn mouseToClip(mouse: sphtud.ui.MousePos, widget_bounds: gui.PixelBBox) sphtud.math.Vec2 {
        const x = mouse.x - asf32(widget_bounds.left);
        const y = mouse.y - asf32(widget_bounds.top);

        return .{
            2 * x / asf32(widget_bounds.calcWidth()) - 1.0,
            - (2 * y / asf32(widget_bounds.calcHeight()) - 1.0),
        };
    }

    fn updateRender(self: *HitTestWidget) void {
        var points: [2]sphtud.render.xyt_program.Vertex = undefined;
        var ray_dir_large = self.ray.dir;
        ray_dir_large *= @splat(3);
        points[0] = .{ .vPos = self.ray.start};
        points[1] = .{ .vPos = self.ray.start + ray_dir_large};

        self.ray_buf.updateBuffer(&points);

        self.ray_source.bindData(self.render_program.handle(), self.ray_buf);

        var circle_points: [20]sphtud.render.xyt_program.Vertex = undefined;

        for (&circle_points, 0..) |*cp, i| {
            const theta: f32 = asf32(i) / asf32(circle_points.len) * std.math.pi * 2;
            const x = self.circle.rx * @cos(theta);
            const y = self.circle.ry * @sin(theta);
            const transform = sphtud.math.Transform.rotate(self.circle.rotation).then(.translate(self.circle.center[0], self.circle.center[1]));
            cp.* = .{ .vPos = applyTransformVec2(.{x, y}, transform) };
        }

        self.circle_buf.updateBuffer(&circle_points);
        self.circle_source.bindData(self.render_program.handle(), self.circle_buf);

        var intersection_points_buf: [2]Vec2 = undefined;
        const intersection_points = sphtud.geometry.rayEllipseIntersection(
            self.ray, self.circle,
            &intersection_points_buf,
        );

        var intersection_points_gpu: [2]sphtud.render.xyt_program.Vertex = undefined;
        for (intersection_points, 0..) |p, i| {
            intersection_points_gpu[i] = .{ .vPos = p };
        }
        self.intersections_buf.updateBuffer(intersection_points_gpu[0..intersection_points.len]);
        self.intersections_source.bindData(self.render_program.handle(), self.intersections_buf);
    }
};

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

const ignore = 0;
const rx_dragged = 1;
const rx_drag_start = 2;
const ry_dragged = 3;
const ry_drag_start = 4;
const rot_dragged = 5;
const rot_drag_start = 6;

const Ids = struct {
    rx: DragIds,
    ry: DragIds,
    rot: DragIds,

    fn init() Ids {
        var alloc = sphtud.util.IdAlloc.init;
        return .{
            .rx = .init(&alloc),
            .ry = .init(&alloc),
            .rot = .init(&alloc),
        };
    }
};

const ids = Ids.init();

fn onDrag(ref: f32, drag: *gui.Drag) f32 {
    return ref + drag.drag_delta_px * 0.001;
}

fn dragText(buf: []u8, val: f32) ![]const u8 {
    return try std.fmt.bufPrint(buf, "{d:.3}", .{val});
}

const DragIds = struct {
    on_start: usize,
    on_dragged: usize,
    total: sphtud.util.IdAlloc.Range,

    pub fn init(alloc: *sphtud.util.IdAlloc) DragIds {
        const mark = alloc.mark();
        return .{
            .on_start = alloc.allocOne(),
            .on_dragged = alloc.allocOne(),
            .total = mark.range(),
        };
    }
};

const DragF32 = struct {
    // We are probably only dragging one widget at a time, so share the
    // reference between all of them
    var shared_ref: f32 = 0;

    label: *gui.Label,
    drag: *gui.Drag,
    source: *f32,

    fn init(wf: gui.WidgetFactory, source: *f32, comptime drag_ids: DragIds) !DragF32 {
        var buf: [10]u8 = undefined;
        const label = try wf.makeLabel(try dragText(&buf, source.*), .{});
        const drag = try wf.makeDrag(&label.widget, drag_ids.on_start, drag_ids.on_dragged);
        return .{
            .label = label,
            .drag = drag,
            .source = source,
        };
    }

    fn service(self: DragF32, event: usize, comptime drag_ids: DragIds) !bool {
        switch (event) {
            drag_ids.on_start => {
                self.onDragStart();
                return false;
            },
            drag_ids.on_dragged => {
                try self.onDrag();
                return true;
            },
            else => unreachable,
        }
    }

    fn onDragStart(self: DragF32) void {
        shared_ref = self.source.*;
    }

    fn onDrag(self: DragF32) !void {
        var buf: [10]u8 = undefined;
        self.source.* = shared_ref + self.drag.drag_delta_px * 0.001;
        try self.label.setText(try dragText(&buf, self.source.*));
    }
};

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 1200, 900);

    try sphtud.render.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

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

    var hit_test_widget = try HitTestWidget.init(gui_alloc);

    const controls = try wf.makeLayout();

    const rx_label = try wf.makeLabel("rx", .{});
    try controls.append(&rx_label.widget);

    const rx = try DragF32.init(wf, &hit_test_widget.circle.rx, ids.rx);
    try controls.append(&rx.drag.widget);

    const ry_label = try wf.makeLabel("ry", .{});
    try controls.append(&ry_label.widget);

    const ry = try DragF32.init(wf, &hit_test_widget.circle.ry, ids.ry);
    try controls.append(&ry.drag.widget);

    const rot_label = try wf.makeLabel("rot", .{});
    try controls.append(&rot_label.widget);

    const rot = try DragF32.init(wf, &hit_test_widget.circle.rotation, ids.rot);
    try controls.append(&rot.drag.widget);

    const controls_background = try wf.makeRect(gui.WidgetState.StyleColors.background_color);
    const controls_stack_items = try gui_alloc.heap.arena().dupe(
        gui.Stack.StackItem,
        &.{
            .{ .widget = &controls_background.widget },
            .{ .widget = &controls.widget },
        },
    );
    const controls_stack = try wf.makeStack(controls_stack_items);
    const controls_box = try wf.makeBox(&controls_stack.widget, .{ .width = 300, .height = 0 }, .fill_height );

    const layout = try wf.makeLayout();
    layout.cursor.direction = .left_to_right;
    try layout.append(&controls_box.widget);
    try layout.append(&hit_test_widget.widget);

    const runner = try wf.makeRunner(&layout.widget);

    const start = try sphtud.io.clock_gettime(.BOOTTIME);

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

        var needs_render = false;
        for (gui_state.event_queue.items) |event| switch (event) {
            ids.rx.total.start...ids.rx.total.end => {
                needs_render |= try rx.service(event, ids.rx);
            },
            ids.ry.total.start...ids.ry.total.end => {
                needs_render |= try ry.service(event, ids.ry);
            },
            ids.rot.total.start...ids.rot.total.end => {
                needs_render |= try rot.service(event, ids.rot);
            },
            else => {},
        };

        gui_state.event_queue.clearRetainingCapacity();

        if (needs_render) {
            hit_test_widget.updateRender();
        }



        window.swapBuffers();
    }
}
