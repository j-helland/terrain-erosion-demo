const std = @import("std");
const glfw = @import("zglfw");
const opengl = @import("zopengl");
const gl = opengl.bindings;
const zmath = @import("zmath");

pub const Pool = @import("pool.zig").Pool;
pub const Timer = @import("timer.zig").Timer;

pub fn Rect(comptime T: type) type {
    return struct {
        x: T, y: T, w: T, h: T,
    };
}

/// Returns w / h aspect ratio for the GLFW window object.
pub inline fn getAspect(window: *glfw.Window) f32 {
    const fb_size = window.getFramebufferSize();
    return @as(f32, @floatFromInt(fb_size[0])) / @as(f32, @floatFromInt(fb_size[1]));
}

pub inline fn glGen(gen_func: *const fn (c_int, *c_uint) callconv(.C) void) u32 {
    var id: u32 = 0;
    gen_func(1, &id);
    return id;
}

/// Box-Muller transform: https://en.wikipedia.org/wiki/Box%E2%80%93Muller_transform
pub fn sampleUnitGaussian(rng: std.Random) [2]f32 {
    const U1 = rng.float(f32);
    const U2 = rng.float(f32);
    const z1 = @sqrt(-2*@log(U1)) * @cos(2.0 * std.math.pi * U2);
    const z2 = @sqrt(-2*@log(U1)) * @sin(2.0 * std.math.pi * U2);
    return .{z1, z2};
}