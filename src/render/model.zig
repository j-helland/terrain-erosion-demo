const std = @import("std");
const gl = @import("zopengl").bindings;
const utils = @import("../utils/utils.zig");

const Shader = @import("shader.zig").Shader;
const Heightmap = @import("../simulation/heightmap.zig").Heightmap;
const ParticleManager = @import("../simulation/particle.zig").ParticleManager;

/// Encapsulation for OpenGL objects associated with a single model to render.
/// It is expected that other structs implement their own adapter methods into this struct if they want to be displayed.
pub const Model = struct {
    const Self = @This();

    vao: u32 = 0,
    vbo: u32 = 0,
    ebo: u32 = 0,
    num_strips: u32 = 0,
    num_verts_per_strip: u32 = 0,
    is_buffered: bool = false,

    vertex_buffer: std.ArrayList(f32),
    index_buffer: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            // Create OpenGL objects.
            .vao = utils.glGen(gl.genVertexArrays),
            .vbo = utils.glGen(gl.genBuffers),
            .ebo = utils.glGen(gl.genBuffers),

            .vertex_buffer = std.ArrayList(f32).init(allocator),
            .index_buffer = std.ArrayList(u32).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free OpenGL objects.
        gl.deleteBuffers(1, &self.ebo);
        gl.deleteBuffers(1, &self.vbo);
        gl.deleteVertexArrays(1, &self.vao);

        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
    }    

    pub fn draw(self: *const Self, shader: *const Shader) void {
        gl.bindVertexArray(self.vao);
        defer gl.bindVertexArray(0);

        shader.use();
        gl.drawElements(gl.TRIANGLE_STRIP, @intCast(self.num_verts_per_strip * self.num_strips), gl.UNSIGNED_INT, null);
    }

    /// Adapter for Heightmap struct into OpenGL data.
    pub fn remeshHeightmap(self: *Self, heightmap: *const Heightmap) !void {
        self.vertex_buffer.clearRetainingCapacity();
        self.index_buffer.clearRetainingCapacity();

        // Generate new mesh.
        // Mesh vertices.
        for (0..heightmap.num_rows) |r| {
            for (0..heightmap.num_cols) |c| {
                const idx = r * heightmap.num_cols + c;
                const height = heightmap.heights[idx];
                const x = heightmap.x0 + heightmap.cell_size * @as(f32, @floatFromInt(c));
                const z = heightmap.y0 + heightmap.cell_size * @as(f32, @floatFromInt(r));

                try self.vertex_buffer.append(x);      // v.x
                try self.vertex_buffer.append(height); // v.y
                try self.vertex_buffer.append(z);      // v.z

                // Gradient vectors.
                const gradient = heightmap.surfaceGradient(x, z);
                try self.vertex_buffer.append(gradient[0]); // n.x
                try self.vertex_buffer.append(gradient[1]); // n.y
                try self.vertex_buffer.append(gradient[2]); // n.z
            }
        }

        // Generate triangle strips.
        for (0..heightmap.num_rows - 1) |r| {
            for (0..heightmap.num_cols) |c| {
                for (0..2) |k| {
                    try self.index_buffer.append(@intCast(c + heightmap.num_cols * (r + k)));
                }
            }
        }

        // Send mesh data back into the rendering pipeline.
        gl.bindVertexArray(self.vao);
        defer gl.bindVertexArray(0); // unbind

        // Vertices and gradients are expected to change frequently (every frame).
        gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(self.vertex_buffer.items.len * @sizeOf(f32)), self.vertex_buffer.items.ptr, gl.STREAM_DRAW);
        // vertices
        gl.vertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 6 * @sizeOf(f32), null);
        gl.enableVertexAttribArray(0);
        // gradients
        gl.vertexAttribPointer(1, 3, gl.FLOAT, gl.FALSE, 6 * @sizeOf(f32), @ptrFromInt(3 * @sizeOf(f32)));
        gl.enableVertexAttribArray(1);

        // Only buffer the index data once since this won't change.
        if (!self.is_buffered) {
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, self.ebo);
            gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(self.index_buffer.items.len * @sizeOf(u32)), self.index_buffer.items.ptr, gl.STATIC_DRAW);
            self.is_buffered = true;
        }

        self.num_strips = @intCast(heightmap.num_rows - 1);
        self.num_verts_per_strip = @intCast(heightmap.num_cols * 2);
    }
};

pub const ModelPoints = struct {
    const Self = @This();

    vao: u32 = 0,
    vbo: u32 = 0,
    num_points: i32 = 0,
    point_size: f32 = 5.0,

    vertex_buffer: std.ArrayList(f32),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            // Create OpenGL objects.
            .vao = utils.glGen(gl.genVertexArrays),
            .vbo = utils.glGen(gl.genBuffers),

            .vertex_buffer = std.ArrayList(f32).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free OpenGL objects.
        gl.deleteBuffers(1, &self.vbo);
        gl.deleteVertexArrays(1, &self.vao);

        self.vertex_buffer.deinit();
    }

    pub fn draw(self: *const Self, shader: *const Shader) void {
        gl.bindVertexArray(self.vao);
        defer gl.bindVertexArray(0);

        gl.pointSize(self.point_size);
        gl.polygonMode(gl.FRONT_AND_BACK, gl.POINTS);

        shader.use();
        gl.drawArrays(gl.POINTS, 0, self.num_points);
    }

    pub fn remeshParticles(self: *Self, heightmap: *const Heightmap, particle_manager: *const ParticleManager) !void {
        self.vertex_buffer.clearRetainingCapacity();

        var it = particle_manager.iterator();
        while (it.next()) |entry| {
            const pos = &entry.value_ptr.*.pos;
            const height = 
                if (heightmap.getCellId(.{pos[0], pos[2]})) |idx|
                    heightmap.heights[idx]
                else 
                    continue;
            try self.vertex_buffer.append(pos[0]);
            try self.vertex_buffer.append(height + 1e-1 * heightmap.cell_size);
            try self.vertex_buffer.append(pos[2]);
        }

        gl.bindVertexArray(self.vao);
        defer gl.bindVertexArray(0);

        gl.bindBuffer(gl.ARRAY_BUFFER, self.vbo);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(self.vertex_buffer.items.len * @sizeOf(f32)), self.vertex_buffer.items.ptr, gl.STREAM_DRAW);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, gl.FALSE, 3 * @sizeOf(f32), null);
        gl.enableVertexAttribArray(0);

        self.num_points = @intCast(particle_manager.count());
    }
};