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

fn rayCircleIntersection(
    start: Vec2, dir: Vec2,
    center: Vec2, radius: f32,
    ret_buf: *[2]Vec2,
) []sphtud.math.Vec2 {
    const to_midpoint = sphtud.math.dot(center - start, dir);
    const midpoint = start + dir * Vec2{to_midpoint, to_midpoint};

    const r_2 = radius * radius;
    const perp = midpoint - center;
    const perp_len_2 = sphtud.math.length2(perp);

    if (perp_len_2 > r_2)  {
        return &.{};
    }

    const offs = @sqrt(r_2 - perp_len_2);

    const offs_v = Vec2{offs, offs};
    const a = midpoint + dir * offs_v;
    const b = midpoint - dir * offs_v;

    var ret = std.ArrayList(Vec2).initBuffer(ret_buf);
    if (sphtud.math.dot(a - start, dir) >= 0) {
        ret.appendBounded(a) catch unreachable;
    }

    if (sphtud.math.dot(b - start, dir) >= 0) {
        ret.appendBounded(b) catch unreachable;
    }

    return ret.items;
}

fn applyTransformVec2(v: Vec2, transform: sphtud.math.Transform) Vec2 {
    const ret = transform.apply(.{v[0], v[1], 1});
    return .{ ret[0] / ret[2], ret[1] / ret[2] };
}

fn rayEllipseIntersection(
    start: Vec2, dir: Vec2,
    center: Vec2, radius_x: f32, radius_y: f32, rot: f32,
    ret_buf: *[2]Vec2,
) []sphtud.math.Vec2 {
    const radius = radius_y;
    const to_circle =
        sphtud.math.Transform.translate(-center[0], -center[1])
        .then(sphtud.math.Transform.rotate(-rot))
        .then(sphtud.math.Transform.scale(radius / radius_x, 1));

    const old_end = start + dir;
    const new_end = applyTransformVec2(old_end, to_circle);
    const new_start = applyTransformVec2(start, to_circle);
    const new_dir = sphtud.math.normalize(new_end - new_start);

    const ret = rayCircleIntersection(
        new_start,
        new_dir,
        applyTransformVec2(center, to_circle),
        radius,
        ret_buf,
    );

    const from_circle = sphtud.math.Transform.scale(radius_x / radius, 1)
        .then(.rotate(rot))
        .then(.translate(center[0], center[1]));

    for (ret) |*r| {
        r.* = applyTransformVec2(r.*, from_circle);
    }

    return ret;
}

pub const HitTestWidget = struct {
    render_program: sphtud.render.xyt_program.SolidColorProgram,

    ray_buf: sphtud.render.xyt_program.Buffer,
    ray_source: sphtud.render.xyt_program.RenderSource,
    ray_start: sphtud.math.Vec2,
    ray_dir: sphtud.math.Vec2,

    circle: struct {
        center: sphtud.math.Vec2,
        radius_x: f32,
        radius_y: f32,
        rot: f32,
    },
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
            .ray_start = .{ -0.5, 0 },
            .ray_dir = .{ 1.0, 0.0 },
            .circle = .{
                .center = .{ 0.0, 0.0 },
                .radius_x = 0.5,
                .radius_y = 0.5,
                .rot = 0,
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
            self.ray_start = mouseToClip(input_state.mouse_pos, widget_bounds);
            self.updateRender();
        }

        if (self.down_mask & 2 != 0) {
            const ray_end = mouseToClip(input_state.mouse_pos, widget_bounds);
            self.ray_dir = sphtud.math.normalize(ray_end - self.ray_start);
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
        var ray_dir_large = self.ray_dir;
        ray_dir_large *= @splat(3);
        points[0] = .{ .vPos = self.ray_start};
        points[1] = .{ .vPos = self.ray_start + ray_dir_large};

        self.ray_buf.updateBuffer(&points);

        self.ray_source.bindData(self.render_program.handle(), self.ray_buf);

        var circle_points: [20]sphtud.render.xyt_program.Vertex = undefined;

        for (&circle_points, 0..) |*cp, i| {
            const theta: f32 = asf32(i) / asf32(circle_points.len) * std.math.pi * 2;
            const x = self.circle.radius_x * @cos(theta);
            const y = self.circle.radius_y * @sin(theta);
            const transform = sphtud.math.Transform.rotate(self.circle.rot).then(.translate(self.circle.center[0], self.circle.center[1]));
            cp.* = .{ .vPos = applyTransformVec2(.{x, y}, transform) };
        }

        self.circle_buf.updateBuffer(&circle_points);
        self.circle_source.bindData(self.render_program.handle(), self.circle_buf);

        var intersection_points_buf: [2]Vec2 = undefined;
        const intersection_points = rayEllipseIntersection(
            self.ray_start, self.ray_dir,
            self.circle.center, self.circle.radius_x, self.circle.radius_y, self.circle.rot,
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

    const controls = try wf.makeLayout();

    const rx_label = try wf.makeLabel("rx", .{});
    try controls.append(&rx_label.widget);

    const rx_value = try wf.makeLabel("", .{});
    const rx_slider = try wf.makeDrag(&rx_value.widget, rx_drag_start, rx_dragged);
    try controls.append(&rx_slider.widget);

    const ry_label = try wf.makeLabel("ry", .{});
    try controls.append(&ry_label.widget);

    const ry_value = try wf.makeLabel("", .{});
    const ry_slider = try wf.makeDrag(&ry_value.widget, ry_drag_start, ry_dragged);
    try controls.append(&ry_slider.widget);

    const rot_label = try wf.makeLabel("rot", .{});
    try controls.append(&rot_label.widget);

    const rot_value = try wf.makeLabel("", .{});
    const rot_slider = try wf.makeDrag(&rot_value.widget, rot_drag_start, rot_dragged);
    try controls.append(&rot_slider.widget);

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
    var hit_test_widget = try HitTestWidget.init(gui_alloc);

    const layout = try wf.makeLayout();
    layout.cursor.direction = .left_to_right;
    try layout.append(&controls_box.widget);
    try layout.append(&hit_test_widget.widget);

    const runner = try wf.makeRunner(&layout.widget);

    const start = try sphtud.io.clock_gettime(.BOOTTIME);

    var rx_ref: f32 = 0;
    var ry_ref: f32 = 0;
    var rot_ref: f32 = 0;

    var rx_label_buf: [128]u8 = undefined;
    try rx_value.setText(try std.fmt.bufPrint(&rx_label_buf, "{d:.3}", .{hit_test_widget.circle.radius_x}));

    var ry_label_buf: [128]u8 = undefined;
    try ry_value.setText(try std.fmt.bufPrint(&ry_label_buf, "{d:.3}", .{hit_test_widget.circle.radius_y}));

    var rot_label_buf: [128]u8 = undefined;
    try rot_value.setText(try std.fmt.bufPrint(&rot_label_buf, "{d:.3}", .{hit_test_widget.circle.rot}));

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
            rx_drag_start => {
                rx_ref = hit_test_widget.circle.radius_x;
            },
            rx_dragged => {
                hit_test_widget.circle.radius_x = rx_ref + rx_slider.drag_delta_px * 0.001;
                try rx_value.setText(try std.fmt.bufPrint(&rx_label_buf, "{d:.3}", .{hit_test_widget.circle.radius_x}));
                hit_test_widget.updateRender();
            },
            ry_drag_start => {
                ry_ref = hit_test_widget.circle.radius_y;
            },
            ry_dragged => {
                hit_test_widget.circle.radius_y = ry_ref + ry_slider.drag_delta_px * 0.001;
                try ry_value.setText(try std.fmt.bufPrint(&ry_label_buf, "{d:.3}", .{hit_test_widget.circle.radius_y}));
                hit_test_widget.updateRender();
            },
            rot_drag_start => {
                rot_ref = hit_test_widget.circle.rot;
            },
            rot_dragged => {
                hit_test_widget.circle.rot = rot_ref + rot_slider.drag_delta_px * 0.001;
                try rot_value.setText(try std.fmt.bufPrint(&rot_label_buf, "{d:.3}", .{hit_test_widget.circle.rot}));
                hit_test_widget.updateRender();
            },
            else => {},
        };
        gui_state.event_queue.clearRetainingCapacity();



        window.swapBuffers();
    }
}
