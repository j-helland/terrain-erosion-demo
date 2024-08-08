const std = @import("std");
const zmath = @import("zmath");

const utils = @import("../utils/utils.zig");
const Rect = utils.Rect;
const Pool = utils.Pool;

pub const ParticleID = usize;
pub const ParticleIDMap = std.AutoArrayHashMap(ParticleID, *Particle);

/// Particle of fluid that can transport material dissolved from a surface.
/// NOTE: Particle mass is defined implicitly via volume and simulation fluid_density parameter.
pub const Particle = struct {
    // NOTE: position and velocity are specified as 4D vectors purely for SIMD purposes.
    pos: zmath.Vec,
    velocity: zmath.Vec,

    volume: f32 = 1.0,
    sediment: f32 = 0.0,
};

pub const ParticleSpawnerContext = struct {
    world_area: Rect(f32),
    max_volume: f32,
};

pub const ParticleSpawner = enum {
    world,
    box,

    pub fn spawn(self: @This(), rng: std.Random, ctx: ParticleSpawnerContext) Particle {
        // Hit surface with random velocity.
        const initial_velocity_global = zmath.f32x4(0, -1, 0, 0);
        const initial_velocity = initial_velocity_global + blk: {
            const z = utils.sampleUnitGaussian(rng);
            break :blk zmath.f32x4(
                z[0] * 5e-2,
                0,
                z[1] * 5e-2,
                0,
            );
        };

        return .{
            // Hit surface with random volume. This implies random mass.
            .volume = rng.float(f32) * ctx.max_volume,
            .velocity = initial_velocity,

            // Random spawn position. Height doesn't matter; we snap particles to the surface. 
            .pos = switch (self) {
                .world => .{
                    rng.float(f32) * ctx.world_area.w + ctx.world_area.x,
                    1, // height
                    rng.float(f32) * ctx.world_area.h + ctx.world_area.y,
                    0,
                },

                .box => .{
                    rng.float(f32) * 1.0 + ctx.world_area.x + 1.5,
                    1, // height
                    rng.float(f32) * 1.0 + ctx.world_area.y + 1.5,
                    0,
                },
            },
        };
    }
};

/// Manager for population of fluid particles. Abstracts responsibilities of efficient (de)allocation of particles.
pub const ParticleManager = struct {
    const Self = @This();

    pool: Pool(Particle),
    particles: ParticleIDMap,
    next_id: ParticleID = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            // TODO: Need to make sure page allocator is performant enough. Expect significant hangs when new pages are requested. Might switch to FixedBufferAllocator instead.
            .pool = Pool(Particle).init(std.heap.page_allocator),
            .particles = ParticleIDMap.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.particles.deinit();
        self.pool.deinit();
    }

    pub fn clearRetainingCapacity(self: *Self) void {
        var it = self.iterator();
        while (it.next()) |entry| {
            self.pool.free(entry.value_ptr.*);
        }
        self.particles.clearRetainingCapacity();
    }

    pub fn spawn(self: *Self) !struct{ id: ParticleID, particle: *Particle } {
        defer self.next_id += 1;
        const particle = try self.pool.alloc();
        try self.particles.put(self.next_id, particle);
        return .{ .id = self.next_id, .particle = particle };
    }

    pub fn get(self: *const Self, id: ParticleID) ?*Particle {
        return self.particles.get(id);
    }

    pub fn remove(self: *Self, id: ParticleID) void {
        if (self.particles.fetchSwapRemove(id)) |entry| {
            self.pool.free(entry.value);
        }
    }

    pub fn iterator(self: *const Self) ParticleIDMap.Iterator {
        return self.particles.iterator();
    }

    pub fn count(self: *const Self) usize {
        return self.particles.count();
    }
};

test "ParticleManager" {
    var manager = ParticleManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(0, manager.count());

    const id1 = (try manager.spawn()).id;
    try std.testing.expectEqual(1, manager.count());
    try std.testing.expect(manager.get(id1) != null);

    const id2 = (try manager.spawn()).id;
    try std.testing.expect(id2 != id1);
    try std.testing.expectEqual(2, manager.count());
    try std.testing.expect(manager.get(id2) != null);

    // Check iterator consistency.
    var it = manager.iterator();
    var count: usize = 0;
    var id1_seen = false;
    var id2_seen = false;
    while (it.next()) |*entry| : (count += 1) { 
        const id = entry.key_ptr.*;
        id1_seen = id1_seen or (id == id1);
        id2_seen = id2_seen or (id == id2);
    }
    try std.testing.expectEqual(count, manager.count());
    try std.testing.expect(id1_seen);
    try std.testing.expect(id2_seen);

    // Remove entries.
    manager.remove(id2);
    try std.testing.expectEqual(1, manager.count());
    try std.testing.expect(manager.get(id2) == null);

    manager.remove(id1);
    try std.testing.expectEqual(0, manager.count());
    try std.testing.expect(manager.get(id1) == null);
}