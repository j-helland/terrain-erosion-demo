const std = @import("std");
const zmath = @import("zmath");

pub const MovementDirection = enum {
    forward,
    backward,
    left,
    right,
};

/// Simulation viewport control.
pub const Camera = struct {
    const Self = @This();

    pos: zmath.F32x4,
    up: zmath.F32x4,
    front: zmath.F32x4,
    speed: zmath.F32x4,
    yaw: f32,
    pitch: f32,
    fov: f32,

    /// Return the projection matrix into view space.
    pub inline fn lookAt(self: *Self) zmath.Mat {
        return zmath.lookAtRh(self.pos, self.pos + self.front, self.up);
    }

    /// Move the camera in world space.
    pub fn doMovement(self: *Self, direction: MovementDirection, delta_time: f32) void {
        const speed = self.speed * zmath.f32x4s(delta_time);
        self.pos += switch (direction) {
            .forward => speed * zmath.normalize3(self.front),
            .backward => -speed * zmath.normalize3(self.front),
            .left => -speed * zmath.normalize3(zmath.cross3(self.front, self.up)),
            .right => speed * zmath.normalize3(zmath.cross3(self.front, self.up)),
        };
    }

    /// Modify orientation of camera using Euler angles (roll, pitch, yaw).
    pub fn doOrientation(self: *Self, xoffset: f32, yoffset: f32) void {
        self.yaw += xoffset;
        self.pitch += yoffset;
        self.pitch = std.math.clamp(self.pitch, -89.0, 89.0);

        const ryaw = std.math.degreesToRadians(self.yaw);
        const rpitch = std.math.degreesToRadians(self.pitch);
        const x = @cos(ryaw) * @cos(rpitch);
        const y = @sin(rpitch);
        const z = @sin(ryaw) * @cos(rpitch);

        self.front = zmath.normalize3(zmath.f32x4(x, y, z, 0.0));

        // New up vector.
        const v1 = zmath.cross3(self.front, zmath.f32x4(0.0, 1.0, 0.0, 0.0));
        self.up = zmath.normalize3(zmath.cross3(v1, self.front));
    }

    pub fn doZoom(self: *Self, zoom: f32) void {
        self.fov -= zoom;
        self.fov = std.math.clamp(self.fov, 1.0, 45.0);
    }
};
