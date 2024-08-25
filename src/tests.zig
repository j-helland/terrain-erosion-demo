// This is a central location where we import all files that contain unit tests. 
// Any file here will automatically be covered by the `zig build test` runner.
comptime {
    _ = @import("simulation/heightmap.zig");
    _ = @import("simulation/particle.zig");
    _ = @import("utils/timer.zig");
}