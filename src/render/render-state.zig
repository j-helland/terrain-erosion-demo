const std = @import("std");
const zmath = @import("zmath");
const glfw = @import("zglfw");

const Camera = @import("camera.zig").Camera;
const Model = @import("model.zig").Model;
const ModelPoints = @import("model.zig").ModelPoints;

const shd = @import("shader.zig");
const Shader = shd.Shader;
const ShaderInfo = shd.ShaderInfo;

/// Dictates how OpenGL should draw models.
pub const GLPolygonMode = enum(i32) {
    /// Full mesh shading.
    default = 0,

    /// Only draw triangle edges between vertices.
    wireframes = 1,

    /// Only draw vertices as points.
    vertices = 2,
};

pub const RenderState = struct {
    const Self = @This();    

    window: *glfw.Window,
    camera: Camera,    
    shaders: ShadersState,

    // Rendering models.
    models: struct {
        terrain: Model,
        particles: ModelPoints,

        pub fn deinit(self: *@This()) void {
            // Call deinit on all shaders declared as fields in this struct.
            inline for (std.meta.fields(@This())) |f| {
                var shader = @as(f.type, @field(self, f.name));
                shader.deinit();
            }
        }
    },    

    /// Misc. application configuration for the GUI.
    settings: struct {
        gl_polygon_mode: GLPolygonMode = .default,
        is_render_terrain: bool = true,
        is_render_particles: bool = true,
    } = .{},

    pub fn init(allocator: std.mem.Allocator, window: *glfw.Window) !Self {
        return .{
            .window = window,
            .shaders = try ShadersState.init(allocator),
            .models = .{
                .terrain = Model.init(allocator),
                .particles = ModelPoints.init(allocator),
            },

            // TODO: Make camera + mouse initialization config driven.
            .camera = .{
                .pos = .{ 1.13, 2.14, 5.03, 0 },
                .up = .{ 0, 1, 0, 0 },
                .front = .{ 0.25, -0.51, -0.83, 0 },
                .pitch = -30.34,
                .yaw = -73.10,
                .fov = 45.0,
                .speed = zmath.f32x4s(4.0),
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.models.deinit();
        self.shaders.deinit();
    }
};

/// Contains compiled OpenGL shaders. These can be passed to models to shade them accordingly.
const ShadersState = struct {
    terrain: Shader,
    particles: Shader,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .terrain = try Shader.init(allocator, &.{
                .vertex_path = shd.SHADER_TERRAIN_VERT,
                .fragment_path = shd.SHADER_TERRAIN_FRAG,
            }),

            .particles = try Shader.init(allocator, &.{
                .vertex_path = shd.SHADER_PARTICLES_VERT,
                .fragment_path = shd.SHADER_PARTICLES_FRAG,
            }),
        };
    }

    pub fn deinit(self: *const @This()) void {
        // Call deinit on all shaders declared as fields in this struct.
        inline for (std.meta.fields(@This())) |f| {
            var shader = @as(f.type, @field(self, f.name));
            shader.deinit();
        }
    }
};