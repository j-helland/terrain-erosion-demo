const std = @import("std");
const gl = @import("zopengl").bindings;
const zmath = @import("zmath");
const hm = @import("heightmap.zig");

const utils = @import("../utils/utils.zig");
const Rect = utils.Rect;
const Timer = utils.Timer;

const ModelPoints = @import("../render/render.zig").ModelPoints;

const Particle = @import("particle.zig").Particle;
const ParticleID = @import("particle.zig").ParticleID;
const ParticleManager = @import("particle.zig").ParticleManager;
const ParticleSpawner = @import("particle.zig").ParticleSpawner;
const ParticleSpawnerContextWorld = @import("particle.zig").ParticleSpawnerContextWorld;

pub const SimulationState = struct {
    const Self = @This();

    rng: std.Random.DefaultPrng,

    // Core simulation state.
    world_area: Rect(f32),
    heightmap: hm.Heightmap,
    particle_manager: ParticleManager,
    particles_to_cull: std.ArrayList(ParticleID),

    // GUI controllable fields.
    particle_spawner: ParticleSpawner,
    particle_spawner_gui: ParticleSpawner,

    heightmap_model: hm.HeightmapModelSelection,
    heightmap_model_gui: hm.HeightmapModelSelection,

    // Simulation physical parameters.
    particle_generation_size: i32 = 64,
    max_particle_volume: f32 = 5.0,
    fluid_density: f32 = 1000.0,  // (pure water) examples: https://www.engineeringtoolbox.com/liquids-densities-d_743.html
    surface_friction: f32 = 0.01,
    surface_roughness: f32 = 0.05,
    deposition_rate: f32 = 0.1,
    dissolution_rate: f32 = 0.5,
    evaporation_rate: f32 = 0.001,
    min_particle_volume: f32 = 0.01,

    // Extra flags.
    do_mass_transfer: bool = true,
    is_simulation_paused: bool = true,

    /// Simulation monitoring.
    stats: struct {
        simulation_step_time: f64 = 0.0,
        num_particles_active: usize = 0,
        num_particles_killed: usize = 0,
    } = .{},

    pub fn init(
        allocator: std.mem.Allocator, 
        rng_seed: ?u64, 
        world_area: *const Rect(f32), 
        heightmap_model: hm.HeightmapModelSelection,
        particle_spawner: ParticleSpawner,
    ) !Self {
        return .{
            // Random seed if none was specified.
            .rng = std.Random.DefaultPrng.init(
                if (rng_seed) |seed| 
                    seed
                else blk: {
                    var seed: u64 = 0;
                    try std.posix.getrandom(std.mem.asBytes(&seed));
                    std.log.debug("\t\tSimulation RNG seed: {d}", .{seed});
                    break :blk seed;
                }
            ),

            .world_area = .{ .x = world_area.x, .y = world_area.y, .w = world_area.w, .h = world_area.h },
            .heightmap = try hm.Heightmap.init(
                allocator,
                heightmap_model,
                world_area,
                1.0 / 64.0,
            ),
            .particle_manager = ParticleManager.init(allocator),
            .particles_to_cull = std.ArrayList(ParticleID).init(allocator),

            .heightmap_model = heightmap_model,
            .heightmap_model_gui = heightmap_model,

            .particle_spawner = particle_spawner,
            .particle_spawner_gui = particle_spawner,
        };
    }

    pub fn deinit(self: *Self) void {
        self.heightmap.deinit();
        self.particle_manager.deinit();
        self.particles_to_cull.deinit();
    }

    pub fn step(self: *Self, delta_time: f32) !void {
        var timer = Timer.init();
        defer {
            // exponential moving average
            self.stats.simulation_step_time *= 0.95;
            self.stats.simulation_step_time += 0.05 * @as(f64, @floatFromInt(timer.elapsedTotal()));
        }

        self.handleGUIUpdate();
        if (self.is_simulation_paused) {
            return;
        }

        // For SIMD.
        const dt = zmath.f32x4s(delta_time);

        // Spawn new particles.
        for (0..@intCast(self.particle_generation_size)) |_| {
            const new = try self.particle_manager.spawn();
            new.particle.* = self.particle_spawner.spawn(self.rng.random(), .{
                .world_area = self.world_area,
                .max_volume = self.max_particle_volume,
            });
        }

        // Running for cycles before rendering improves framerate significantly.
        // Assuming that particles are non-interacting, this produces the same results asymptotically.
        const num_cycles = 1;
        for (0..num_cycles) |_| {
            if (self.particle_manager.count() == 0) break;

            self.particles_to_cull.clearRetainingCapacity();

            var it = self.particle_manager.iterator();
            while (it.next()) |entry| {
                const particle_id = entry.key_ptr.*;
                var drop = entry.value_ptr.*;
                
                // x <=> columns, y <=> rows
                // NOTE: "x" and "y" refer to the heightmap plane coordinate system, not OpenGL coordinates.
                //       Recall that for OpenGL, z is the camera-aligned axis.
                const x = drop.pos[0];
                const y = drop.pos[2];

                // Cull particle if out of bounds.
                const idx = self.heightmap.getCellId(.{x, y}) orelse {
                    try self.particles_to_cull.append(particle_id);
                    continue;
                };

                // Cull particle if height is too low.
                const height_start = self.heightmap.heights[idx];
                if (height_start <= 1e-6) {
                    self.heightmap.heights[idx] = 0.0;
                    try self.particles_to_cull.append(particle_id);
                    continue;
                }

                // NOTE: gradient is only in xy.
                const gradient = self.heightmap.surfaceGradient(x, y);
                if (zmath.length3(gradient)[0] < 1e-8) {
                    // Particle does nothing if it can't move.
                    try self.particles_to_cull.append(particle_id);
                    continue;
                }
                const force = zmath.f32x4(gradient[0], 0, gradient[1], 0);
                const mass = zmath.f32x4s(drop.volume * self.fluid_density);

                // Newtonian mechanics to move particle along surface. F = ma  <=>  a = F / m.
                // NOTE: The normal vector dictates force. However, we don't need the vertical force component since we've 
                //       snapped particles onto the surface at this point. The height gradient gives us the planar force components.
                const z = utils.sampleUnitGaussian(self.rng.random());
                const noise = zmath.f32x4s(self.surface_roughness) * zmath.f32x4(z[0], 0, z[1], 0);

                drop.velocity -= dt * (force / mass) + noise; 
                drop.pos += dt * drop.velocity;
                drop.velocity *= zmath.f32x4s(1.0 - delta_time * self.surface_friction);

                // Mass transfer.
                if (self.do_mass_transfer) {
                    const height_next = if (self.heightmap.getCellId(.{drop.pos[0], drop.pos[2]})) |i| self.heightmap.heights[i] else 0.0;
                    const velocity_norm = zmath.length2(zmath.f32x4(drop.velocity[0], drop.velocity[2], 0, 0))[0];
                    const c_eq = @max(0.0, drop.volume * velocity_norm * (height_start - height_next));
                    const driving_force = (c_eq - drop.sediment);

                    if (driving_force < 0) {
                        // deposit
                        self.transferMassWindow(drop, x, y, delta_time * self.deposition_rate * driving_force);
                    } else {
                        // dissolve
                        self.transferMassWindow(drop, x, y, delta_time * self.dissolution_rate * driving_force);
                    }

                } else {
                    // Rudimentary erosion model.
                    // Randomly reduce heightmap at each particle location while on the surface.
                    if (self.heightmap.getCellId(.{x, y})) |i| {
                        const amount = self.rng.random().float(f32) * delta_time * drop.volume * 1e-2;
                        self.heightmap.heights[i] = @max(0.0, self.heightmap.heights[i] - amount);
                    }
                }

                // Particle evaporation.
                drop.volume *= (1.0 - delta_time * self.evaporation_rate);
                if (drop.volume < self.min_particle_volume) {
                    try self.particles_to_cull.append(particle_id);
                    continue;
                }
            }

            // Cull dead particles.
            for (self.particles_to_cull.items) |id| {
                self.particle_manager.remove(id);
            }
            self.stats.num_particles_killed += self.particles_to_cull.items.len;
        }

        self.stats.num_particles_active = self.particle_manager.count();
    }

    fn handleGUIUpdate(self: *Self) void {
        // Regenerate heightmap if model change is detected.
        if (self.heightmap_model != self.heightmap_model_gui) {
            self.heightmap_model = self.heightmap_model_gui;
            self.heightmap.remap(self.heightmap_model);

            // Reset particles.
            self.particles_to_cull.clearRetainingCapacity();
            self.particle_manager.clearRetainingCapacity();

            // Reset stats.
            self.stats.num_particles_active = 0;
            self.stats.num_particles_killed = 0;
        }

        if (self.particle_spawner != self.particle_spawner_gui) {
            self.particle_spawner = self.particle_spawner_gui;
        }
    }

    fn transferMassWindow(self: *Self, particle: *Particle, x: f32, y: f32, amount: f32) void {
        if (self.heightmap.getCellId(.{x, y})) |i| {
            particle.sediment += amount;
            self.heightmap.heights[i] = @max(0.0, self.heightmap.heights[i] - amount * particle.volume);
        }
    }
};
