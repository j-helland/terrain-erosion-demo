const std = @import("std");
const glfw = @import("zglfw");
const zmath = @import("zmath");

const sim = @import("simulation/simulation.zig");

const rdr = @import("render/render.zig");
const RenderState = rdr.RenderState;
const Model = rdr.Model;
const ModelPoints = rdr.ModelPoints;
const Shader = rdr.Shader;
const Camera = rdr.Camera;

/// Mega struct containing rendering and simulation state. Powers the GUI.
/// We directly define sub-structs in here when we don't need to broadly refer to their types elsewhere.
pub const ApplicationState = struct {
    const Self = @This();

    // Primarily use an arena allocator for random allocations.
    // This can be wasteful in cases where a container resizes, but not a big deal for a small app like this.
    arena_state: std.heap.ArenaAllocator,
    simulation_state: sim.SimulationState = undefined,
    render_state: RenderState = undefined,
    
    /// Cursor state. 
    mouse: struct {
        x: f32,
        y: f32,
        look_sensitivity: f32,
        rotate_sensitivity: f32,
        is_mouse_init: bool = true,
    },    

    /// Application monitoring stuff.
    stats: struct {
        delta_time: f32 = 0.0,
        last_frame_time: f32 = 0.0,
        fps: f32 = 0.0,

        pub fn updateClock(self: *@This()) void {
            const time: f32 = @floatCast(glfw.getTime());
            self.delta_time = time - self.last_frame_time;
            self.last_frame_time = time;

            // exponential moving average
            self.fps *= 0.95;
            self.fps += 0.05 / self.delta_time;
        }
    } = .{},

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .mouse = .{
                .x = 400.0,
                .y = 300.0,
                .rotate_sensitivity = 0.0025,
                .look_sensitivity = 0.05,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.render_state.deinit();
        self.arena_state.deinit();
    }

    /// Retrieve the primary application arena allocator.
    pub fn arena(self: *Self) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};