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

pub const HitTestWidget = struct {
    render_program: sphtud.render.xyt_program.SolidColorProgram,

    ray_buf: sphtud.render.xyt_program.Buffer,
    ray_source: sphtud.render.xyt_program.RenderSource,
    ray_start: sphtud.math.Vec2,
    ray_dir: sphtud.math.Vec2,
    widget: gui.Widget,

    down_mask: u8,

    pub fn init(alloc: sphtud.ui.GuiAlloc) !HitTestWidget {
        var ret = HitTestWidget{
            .render_program = try sphtud.render.xyt_program.solidColorProgram(alloc.gl),
            .ray_buf = try .init(alloc.gl, &.{}),
            .ray_source = try .init(alloc.gl),
            .ray_start = .{ -0.5, 0 },
            .ray_dir = .{ 1.0, 0.0 },
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

        gl.glLineWidth(3.0);
        self.render_program.renderLines(self.ray_source, .{
            .color = .{0, 1, 0 },
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
    }
};

fn asf32(val: anytype) f32 {
    return @floatFromInt(val);
}

pub fn main() !void {
    var allocators: sphtud.render.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    var window: sphtud.window.Window = undefined;
    try window.initPinned("sphui demo", 800, 600);

    try sphtud.render.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.WidgetState.init(
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{},
    );

    const wf = gui.WidgetFactory{
        .alloc = gui_alloc,
        .state = gui_state,
    };

    const controls = try wf.makeLayout();

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


        window.swapBuffers();
    }
}
