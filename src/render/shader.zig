const std = @import("std");

const opengl = @import("zopengl");
const gl = opengl.bindings;
const zmath = @import("zmath");

const shader_dir = @import("build_options").shader_dir;

pub const SHADER_TERRAIN_VERT = "terrain.vs";
pub const SHADER_TERRAIN_FRAG = "terrain.fs";

pub const SHADER_PARTICLES_VERT = "particles.vs";
pub const SHADER_PARTICLES_FRAG = "particles.fs";

pub const ShaderError = error{
    CompilationFailed,
    LinkingFailed,
    IncludeFailed,
};

pub const Shader = struct {
    const Self = @This();

    program_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, shaders: struct { vert: []const u8, frag: []const u8 }) !Self {
        const vert = try buildShader(allocator, shaders.vert, gl.VERTEX_SHADER);
        defer gl.deleteShader(vert.id);
        defer allocator.free(vert.src);

        const frag = try buildShader(allocator, shaders.frag, gl.FRAGMENT_SHADER);
        defer gl.deleteShader(frag.id);
        defer allocator.free(frag.src);

        return .{
            .program_id = try buildShaderProgram(.{ vert.id, frag.id }),
        };
    }

    pub fn deinit(self: *const Self) void {
        gl.deleteProgram(self.program_id);
    }

    pub fn use(self: *const Self) void {
        gl.useProgram(self.program_id);
    }

    pub fn setUniform(self: *const Self, comptime T: type, name: [*c]const u8, value: T) void {
        self.use();

        const uniform_location = gl.getUniformLocation(self.program_id, name);
        switch (T) {
            bool => gl.uniform1i(uniform_location, @intFromBool(value)),
            i32 => gl.uniform1i(uniform_location, value),
            u32 => gl.uniform1ui(uniform_location, value),
            f32 => gl.uniform1f(uniform_location, value),
            zmath.Mat => gl.uniformMatrix4fv(uniform_location, 1, gl.FALSE, &zmath.matToArr(value)),
            [2]f32 => gl.uniform2f(uniform_location, value[0], value[1]),
            [3]f32 => gl.uniform3f(uniform_location, value[0], value[1], value[2]),
            [4]f32, zmath.F32x4 => gl.uniform4f(uniform_location, value[0], value[1], value[2], value[3]),
            else => unreachable,
        }
    }
};

/// Caller is responsible for freeing returned src memory.
fn buildShader(allocator: std.mem.Allocator, shader_src_path: []const u8, shader_type: u32) !struct { id: u32, src: [:0]const u8 } {
    const src: [:0]const u8 = try readShaderSource(allocator, shader_src_path);
    const shader = gl.createShader(shader_type);
    gl.shaderSource(shader, 1, @ptrCast(&src), null);
    gl.compileShader(shader);
    try checkShaderErrors(shader);
    return .{ .id = shader, .src = src };
}

/// Loads GLSL source code from a file.
/// Caller is responsible for freeing the returned buffer.
fn readShaderSource(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const path_shader = try std.fs.path.join(allocator, &.{ shader_dir, path });
    defer allocator.free(path_shader);

    // Need to make sure we're in the directory that contains `shader_dir`.
    chdirExeDir();

    // Read with null terminator for C interop.
    const src: [:0]const u8 = try std.fs.cwd().readFileAllocOptions(
        allocator,
        path_shader,
        std.math.maxInt(usize),
        null,
        @alignOf(u8),
        0,
    );
    return src;
}

fn chdirExeDir() void {
    var buf: [1024]u8 = undefined;
    const exe_path = std.fs.selfExeDirPath(buf[0..]) catch ".";
    std.posix.chdir(exe_path) catch {
        std.log.err("Failed to run std.posix.chdir(\"{s}\")", .{ exe_path });
    };
}

fn checkShaderErrors(shader: u32) !void {
    var success: i32 = 0;
    var info_log: [512]u8 = undefined;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &success);
    if (success == 0) {
        gl.getShaderInfoLog(shader, 512, null, &info_log);
        std.debug.print("{s}\n", .{info_log});
        return ShaderError.CompilationFailed;
    }
}

fn buildShaderProgram(shaders_to_attach: anytype) !u32 {
    const program = gl.createProgram();
    inline for (std.meta.fields(@TypeOf(shaders_to_attach))) |field| {
        const shader = @as(field.type, @field(shaders_to_attach, field.name));
        gl.attachShader(program, shader);
    }
    gl.linkProgram(program);
    try checkProgramErrors(program);
    return program;
}

fn checkProgramErrors(program: u32) !void {
    var success: i32 = 0;
    var info_log: [512]u8 = undefined;
    gl.getProgramiv(program, gl.LINK_STATUS, &success);
    if (success == 0) {
        gl.getProgramInfoLog(program, 512, null, &info_log);
        std.debug.print("{s}\n", .{info_log});
        return ShaderError.LinkingFailed;
    }
}
