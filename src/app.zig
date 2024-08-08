//====================================================================================================
// IMPORTS
//====================================================================================================
const std = @import("std");

// External libraries.
const glfw = @import("zglfw");
const opengl = @import("zopengl");
const gl = opengl.bindings;
const zmath = @import("zmath");
const zgui = @import("zgui");

// Internal.
const sim = @import("simulation/simulation.zig");

const rdr = @import("render/render.zig");
const RenderState = rdr.RenderState;
const Shader = rdr.Shader;

const utils = @import("utils/utils.zig");
const Rect = utils.Rect;
const Timer = utils.Timer;

const ApplicationState = @import("app-state.zig").ApplicationState;
const content_dir = @import("build_options").content_dir;

//====================================================================================================
// GLOBALS
//====================================================================================================
// OpenGL 3.3 for maximal portability.
const GL_MAJOR = 3;
const GL_MINOR = 3;

const WINDOW_TITLE = "Hydraulic Erosion";
const INIT_WINDOW_SIZE_H = 800;
const INIT_WINDOW_SIZE_W = 1000;

const WORLD_AREA = Rect(f32){ .x = 0, .y = 0, .w = 5, .h = 5 };

// To be initialized in `main()`.
// The only reason to have this global is for GLFW callbacks. We generally enforce passing state pointers 
// as arguments in all other situations. Notice that this is not marked `pub` for this reason.
var G_STATE: ApplicationState = undefined;

//====================================================================================================
// CORE LOGIC
//====================================================================================================
pub fn main() !void {
    //==================================================
    // setup
    //==================================================
    var timer_startup = Timer.init();
    std.log.info("Initializing...", .{});

    // Allocators.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    timer_startup.logInfoElapsed(" \tallocators initialized");

    // GLFW window.
    const window = try initWindow();
    defer window.destroy();
    defer glfw.terminate();
    timer_startup.logInfoElapsed(" \tGLFW initialized");

    // Application state.
    G_STATE = try ApplicationState.init(allocator);
    var state = &G_STATE;
    defer state.deinit();
    timer_startup.logInfoElapsed(" \tapplication state initialized");

    // Shader compilation.
    state.render_state = try RenderState.init(allocator, window);
    timer_startup.logInfoElapsed(" \tshaders compiled + rendering state initialized");

    // Simulation setup.
    state.simulation_state = try sim.SimulationState.init(state.arena(), null, &WORLD_AREA, .sphere, .box);
    timer_startup.logInfoElapsed(" \tsimulation state initialized");

    // GUI
    initGui(allocator, window);
    defer zgui.deinit();
    defer zgui.backend.deinit();
    timer_startup.logInfoElapsed(" \tGUI initialized");

    timer_startup.logInfoElapsedTotal(" DONE\n");

    //==================================================
    // application loop
    //==================================================
    while (!window.shouldClose()) {
        try update(state);
        try render(state);
    }
}

/// Handle user-driven events. Progress simulation.
fn update(state: *ApplicationState) !void {
    // Events.
    glfw.pollEvents();
    state.stats.updateClock();
    handleInput(state);
    handleGui(state);

    try state.simulation_state.step(state.stats.delta_time);
}

/// Display current simulation state.
fn render(state: *ApplicationState) !void {
    switch (state.render_state.settings.gl_polygon_mode) {
        .vertices => {
            gl.polygonMode(gl.FRONT_AND_BACK, gl.POINT);
            gl.pointSize(5.0);
        },
        .wireframes => gl.polygonMode(gl.FRONT_AND_BACK, gl.LINE),
        .default => gl.polygonMode(gl.FRONT_AND_BACK, gl.FILL),
    }

    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    // Shared uniforms.
    const view_mat = state.render_state.camera.lookAt();
    const projection_mat = zmath.perspectiveFovRh(
        std.math.degreesToRadians(state.render_state.camera.fov),
        utils.getAspect(state.render_state.window),
        0.1,
        100.0,
    );
    const model_mat = zmath.identity(); // leave model mesh as-is.

    if (state.render_state.settings.is_render_terrain) {
        const shader = &state.render_state.shaders.terrain;
        const heightmap = &state.simulation_state.heightmap;
        var model = &state.render_state.models.terrain;

        // GLSL uniform bindings.
        state.render_state.shaders.terrain.setUniform(zmath.Mat, "uView", view_mat);
        state.render_state.shaders.terrain.setUniform(zmath.Mat, "uProjection", projection_mat);
        state.render_state.shaders.terrain.setUniform(zmath.Mat, "uModel", model_mat);

        // Re-mesh and render the model based on current simulation state.
        try model.remeshHeightmap(heightmap);
        model.draw(shader);
    }

    if (state.render_state.settings.is_render_particles) {
        const shader = &state.render_state.shaders.particles;
        const heightmap = &state.simulation_state.heightmap;
        const particle_manager = &state.simulation_state.particle_manager;
        var model = &state.render_state.models.particles;

        // GLSL uniform bindings.
        state.render_state.shaders.particles.setUniform(zmath.Mat, "uView", view_mat);
        state.render_state.shaders.particles.setUniform(zmath.Mat, "uProjection", projection_mat);
        state.render_state.shaders.particles.setUniform(zmath.Mat, "uModel", model_mat);

        try model.remeshParticles(heightmap, particle_manager);
        model.draw(shader);
    }

    // GUI - always do this at the end to enforce overlay.
    zgui.backend.draw();

    // Swap front/back OpenGL framebuffers for final display.
    state.render_state.window.swapBuffers();
}

//====================================================================================================
// GLFW CALLBACKS
//====================================================================================================
fn framebufferSizeCallback(_: *glfw.Window, width: i32, height: i32) callconv(.C) void {
    gl.viewport(0, 0, width, height);
}

fn cursorPosCallback(window: *glfw.Window, _x: f64, _y: f64) callconv(.C) void {
    // mutables
    var mouse = &G_STATE.mouse;
    var camera = &G_STATE.render_state.camera;

    const x: f32 = @floatCast(_x);
    const y: f32 = @floatCast(_y);

    // Avoid sudden jump when application starts and mouse enters window area.
    if (mouse.is_mouse_init) {
        mouse.x = x;
        mouse.y = y;
        mouse.is_mouse_init = false;
    }

    var x_offset = x - mouse.x;
    var y_offset = mouse.y - y; // y is bottom to top
    mouse.x = x;
    mouse.y = y;

    if (window.getMouseButton(.right) == .press) {
        x_offset *= mouse.look_sensitivity;
        y_offset *= mouse.look_sensitivity;
        camera.doOrientation(x_offset, y_offset);
    }
}

fn scrollCallback(_: *glfw.Window, _: f64, yoffset: f64) callconv(.C) void {
    G_STATE.render_state.camera.doZoom(@floatCast(yoffset));
}

//====================================================================================================
// EVENT HANDLERS
//====================================================================================================
fn handleGui(state: *ApplicationState) void {
    const fb_size = state.render_state.window.getFramebufferSize();
    const camera = &state.render_state.camera;
    
    var render_settings = &state.render_state.settings;

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

    zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .always });
    if (zgui.begin("Monitor", .{ .flags = .{} })) {
        zgui.bulletText("Average FPS: {d:.1}", .{state.stats.fps});
        zgui.bulletText("Average Sim Step: {d:.1} ms", .{state.simulation_state.stats.simulation_step_time});

        zgui.bulletText("Particles Active: {d}", .{state.simulation_state.stats.num_particles_active});
        zgui.bulletText("Particles Killed: {d}", .{state.simulation_state.stats.num_particles_killed});

        if (zgui.collapsingHeader("Camera State", .{})) {
            zgui.bulletText("Camera Position : {d:.2}, {d:.2}, {d:.2}", .{ camera.pos[0], camera.pos[1], camera.pos[2] });
            zgui.bulletText("Camera Direction: {d:.2}, {d:.2}, {d:.2}", .{ camera.front[0], camera.front[1], camera.front[2] });
            zgui.bulletText("Camera pitch: {d:.2}, yaw: {d:.2}", .{ camera.pitch, camera.yaw });
        }

        zgui.end();
    }

    zgui.setNextWindowPos(.{ .x = 20.0, .y = 200.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
    if (zgui.begin("Simulation Settings", .{ .flags = .{} })) {
        _ = zgui.checkbox("Paused", .{ .v = &state.simulation_state.is_simulation_paused });

        _ = zgui.comboFromEnum("Model", &state.simulation_state.heightmap_model_gui);
        _ = zgui.comboFromEnum("Particle Spawner", &state.simulation_state.particle_spawner_gui);

        _ = zgui.dragInt("Particle Gen Size", .{ .v = &state.simulation_state.particle_generation_size, .min = 1, .max = 100000 });
        _ = zgui.checkbox("Mass Transfer", .{ .v = &state.simulation_state.do_mass_transfer });
        _ = zgui.sliderFloat("Max Particle Volume", .{ .v = &state.simulation_state.max_particle_volume, .min = 0.01, .max = 10.0 });
        _ = zgui.sliderFloat("Fluid Density", .{ .v = &state.simulation_state.fluid_density, .min = 0.1, .max = 2000.0 });
        _ = zgui.sliderFloat("Surface Friction", .{ .v = &state.simulation_state.surface_friction, .min = 0.0, .max = 1.0 });
        _ = zgui.sliderFloat("Surface Roughness", .{ .v = &state.simulation_state.surface_roughness, .min = 0.0, .max = 1.0 });
        _ = zgui.sliderFloat("Deposition Rate", .{ .v = &state.simulation_state.deposition_rate, .min = 0.0, .max = 1.0 });
        _ = zgui.sliderFloat("Dissolution Rate", .{ .v = &state.simulation_state.dissolution_rate, .min = 0.0, .max = 1.0 });
        _ = zgui.sliderFloat("Evaporation Rate", .{ .v = &state.simulation_state.evaporation_rate, .min = 0.0, .max = 1.0 });

        zgui.end();
    }

    zgui.setNextWindowPos(.{ .x = 1650, .y = 20.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });
    if (zgui.begin("Render Settings", .{ .flags = .{} })) {
        _ = zgui.checkbox("Render Terrain", .{ .v = &render_settings.is_render_terrain });
        _ = zgui.checkbox("Render Particles", .{ .v = &render_settings.is_render_particles });

        if (zgui.collapsingHeader("GL Polygon Mode", .{})) {
            _ = zgui.radioButtonStatePtr("Full", .{ .v = @ptrCast(&render_settings.gl_polygon_mode), .v_button = 0 });
            _ = zgui.radioButtonStatePtr("Wireframes", .{ .v = @ptrCast(&render_settings.gl_polygon_mode), .v_button = 1 });
            _ = zgui.radioButtonStatePtr("Vertices", .{ .v = @ptrCast(&render_settings.gl_polygon_mode), .v_button = 2 });
        }

        zgui.end();
    }
}

fn handleInput(state: *ApplicationState) void {
    var window = state.render_state.window;
    var camera = &state.render_state.camera;

    // Exit application.
    if (window.getKey(.escape) == .press) {
        window.setShouldClose(true);
        return;
    }

    // Movement.
    if (window.getKey(.w) == .press) {
        camera.doMovement(.forward, state.stats.delta_time);
    }
    if (window.getKey(.s) == .press) {
        camera.doMovement(.backward, state.stats.delta_time);
    }
    if (window.getKey(.a) == .press) {
        camera.doMovement(.left, state.stats.delta_time);
    }
    if (window.getKey(.d) == .press) {
        camera.doMovement(.right, state.stats.delta_time);
    }
}

//====================================================================================================
// INITIALIZATION HELPERS
//====================================================================================================
fn initWindow() !*glfw.Window {
    // GLFW
    const window = try initGlfw();

    // Window callbacks.
    _ = window.setFramebufferSizeCallback(framebufferSizeCallback);
    _ = window.setCursorPosCallback(cursorPosCallback);
    _ = window.setScrollCallback(scrollCallback);

    // OpenGL
    const fb_size = window.getFramebufferSize();
    try opengl.loadCoreProfile(glfw.getProcAddress, GL_MAJOR, GL_MINOR);
    gl.viewport(0, 0, fb_size[0], fb_size[1]);

    gl.enable(gl.DEPTH_TEST);

    // Backface culling (assume CCW winding order on vertices).
    gl.enable(gl.CULL_FACE);
    gl.cullFace(gl.BACK);

    return window;
}

fn initGlfw() !*glfw.Window {
    try glfw.init();

    glfw.windowHint(.context_version_major, GL_MAJOR);
    glfw.windowHint(.context_version_minor, GL_MINOR);
    glfw.windowHintTyped(.opengl_profile, .opengl_core_profile);
    // Required on macos.
    glfw.windowHintTyped(.opengl_forward_compat, true);
    glfw.windowHintTyped(.client_api, .opengl_api);
    glfw.windowHintTyped(.doublebuffer, true);

    const window = try glfw.Window.create(INIT_WINDOW_SIZE_W, INIT_WINDOW_SIZE_H, WINDOW_TITLE, null);
    glfw.makeContextCurrent(window);

    return window;
}

fn initGui(allocator: std.mem.Allocator, window: *glfw.Window) void {
    zgui.init(allocator);
    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };
    _ = zgui.io.addFontFromFile(content_dir ++ "FiraCode-Medium.ttf", 16.0 * scale_factor);
    zgui.getStyle().scaleAllSizes(scale_factor);
    zgui.backend.init(window);
}
