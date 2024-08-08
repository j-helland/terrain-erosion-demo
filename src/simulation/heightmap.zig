const std = @import("std");

const gl = @import("zopengl").bindings;
const zmath = @import("zmath");

const Model = @import("../render/render.zig").Model;

const utils = @import("../utils/utils.zig");
const Rect = utils.Rect;

/// All procedural heightmap generating functions must adhere to this interface.
const height_func_t = *const fn(x: f32, y: f32) f32;

pub const HeightmapModelSelection = enum {
    sphere,
    ellipse,
    bar,
    pyramid,
    box,

    pub fn height(self: @This(), x: f32, y: f32) f32 {
        return switch (self) {
            .sphere => heightSphere(x, y),
            .ellipse => heightEllipse(x, y),
            .bar => heightBar(x, y),
            .pyramid => heightPyramid(x, y),
            .box => heightBox(x, y),
        };
    }
};

/// Used to procedurally generate a heightmap using a sphere model.
pub fn heightSphere(x: f32, y: f32) f32 {
    const radius = 1.0;

    const x1 = x - 2.0;
    const y1 = y - 2.0;

    const xx = x1 * x1;
    const yy = y1 * y1;
    const rr = radius * radius;

    // Guard for NaN.
    if (rr < xx + yy) {
        return 0.0;
    }
    return @sqrt(rr - xx - yy);
}

pub fn heightEllipse(x: f32, y: f32) f32 {
    const radius = 1.0;

    const x1 = x - 2.0;
    const y1 = y - 2.0;

    const xx = x1 * x1;
    const yy = y1 * y1;
    const rr = radius * radius;

    // Guard for NaN.
    if (rr < xx + 2*yy) {
        return 0.0;
    }
    return 0.75 * @sqrt(rr - xx - 2*yy);
}

pub fn heightBar(x: f32, y: f32) f32 {
    const radius = 1.0;

    const x1 = x - 2.0;
    const y1 = y - 2.0;

    const xx = x1 * x1;
    const yy = y1 * y1;
    const rr = radius * radius;

    // Guard for NaN.
    if (rr < xx + 0.5*yy) {
        return 0.0;
    }
    return @min(0.7 + 0.1*yy, 0.85 * @sqrt(@sqrt(@sqrt(rr - xx - 0.5*yy))));
}

pub fn heightPyramid(x: f32, y: f32) f32 {
    const x1 = x - 2.0;
    const y1 = y - 2.0;

    return @max(0.0, 1.0 - @abs(x1) - @abs(y1));
}

pub fn heightBox(x: f32, y: f32) f32 {
    if (x >= 1.5 and x <= 2.5 and y >= 1.5 and y <= 2.5) {
        return 1.0;
    }
    return 0.0;
}

pub const Heightmap = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    num_rows: usize,
    num_cols: usize,
    cell_size: f32,
    x0: f32, 
    y0: f32,
    heights: []f32, // row-major order


    pub fn init(
        allocator: std.mem.Allocator, 
        heightmap_model: HeightmapModelSelection,
        rect: *const Rect(f32), 
        cell_size: f32,
    ) !Self {
        const cols = @as(usize, @intFromFloat(rect.w / cell_size));
        const rows = @as(usize, @intFromFloat(rect.h / cell_size));

        const heights = try allocator.alloc(f32, cols * rows);
        var new = Self{
            .allocator = allocator,
            .num_rows = rows,
            .num_cols = cols,
            .cell_size = cell_size,
            .x0 = rect.x,
            .y0 = rect.y,
            .heights = heights,
        };
        new.remap(heightmap_model);
        return new;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.heights);
    }

    pub fn remap(self: *Self, model: HeightmapModelSelection) void {
       // x <=> columns, y <=> rows
        var i: usize = 0;
        var y: f32 = self.y0 + self.cell_size / 2;
        while (i < self.num_rows) : ({
            i += 1;
            y += self.cell_size;
        }) {
            var j: usize = 0;
            var x: f32 = self.x0 + self.cell_size / 2;
            while (j < self.num_cols) : ({
                j += 1;
                x += self.cell_size;
            }) {
                const idx = i * self.num_cols + j;
                self.heights[idx] = model.height(x, y);
            }
        } 
    }

    pub fn getHeight(self: *const Self, p: [2]f32) f32 {
        if (self.getCellId(p)) |idx| return self.heights[idx];
        return 0.0;
    }

    pub fn getCellId(self: *const Self, p: [2]f32) ?usize {
        if (p[0] < self.x0 or p[1] < self.y0) {
            return null;
        }

        // x <=> columns, y <=> rows
        const x = @as(usize, @intFromFloat((p[0] - self.x0) / self.cell_size));
        const y = @as(usize, @intFromFloat((p[1] - self.y0) / self.cell_size));
        if (y >= self.num_rows or x >= self.num_cols) {
            return null;
        }

        return y * self.num_cols + x;
    }

    pub fn surfaceGradient(self: *const Self, x: f32, y: f32) zmath.Vec {
        // x <=> columns, y <=> rows
        const idxd = self.getCellId(.{x, y + self.cell_size});
        const idxu = self.getCellId(.{x, y - self.cell_size});
        const idxr = self.getCellId(.{x + self.cell_size, y});
        const idxl = self.getCellId(.{x - self.cell_size, y});

        // We handle grid boundary by taking height as 0. This is a sensible choice for a heightmap.
        const hd = if (idxd) |idx| self.heights[idx] else 0.0;
        const hu = if (idxu) |idx| self.heights[idx] else 0.0;
        const hr = if (idxr) |idx| self.heights[idx] else 0.0;
        const hl = if (idxl) |idx| self.heights[idx] else 0.0;

        // Finite central difference on 2D grid.
        return zmath.f32x4(
            (hr - hl) / (2 * self.cell_size),
            0,
            (hd - hu) / (2 * self.cell_size),
            0,
        );
    }
};

test "generateHeightmap - sphere" {
    var heightmap = try Heightmap.init(
        std.testing.allocator,
        .sphere,
        &Rect(f32){ .x = 0, .y = 0, .w = 10, .h = 10 },
        1.0,
    );
    defer heightmap.deinit();

    try std.testing.expect(heightmap.num_cols == 10);
    try std.testing.expect(heightmap.num_rows == 10);
    for (heightmap.heights) |h| {
        try std.testing.expect(h >= 0.0);
    }

    // in bounds
    try std.testing.expect(heightmap.getCellId(.{0, 0}).? == 0);
    try std.testing.expect(heightmap.getCellId(.{1, 1}).? == heightmap.num_cols + 1);
    try std.testing.expect(heightmap.getCellId(.{9.9, 9.9}).? == 10*10-1);
    // out of bounds
    try std.testing.expect(heightmap.getCellId(.{-1, -1}) == null);
    try std.testing.expect(heightmap.getCellId(.{10, 10}) == null);
}

test "generateHeightmap - sphere offset" {
    var heightmap = try Heightmap.init(
        std.testing.allocator,
        .sphere,
        &Rect(f32){ .x = 5, .y = 5, .w = 10, .h = 10 },
        1.0,
    );
    defer heightmap.deinit();

    // Should have same number of cells despite (x,y) being offset.
    try std.testing.expect(heightmap.num_cols == 10);
    try std.testing.expect(heightmap.num_rows == 10);
    for (heightmap.heights) |h| {
        try std.testing.expect(h >= 0.0);
    }

    // in bounds - shifted by offset
    try std.testing.expect(heightmap.getCellId(.{5, 5}).? == 0);
    try std.testing.expect(heightmap.getCellId(.{6, 6}).? == heightmap.num_cols + 1);
    try std.testing.expect(heightmap.getCellId(.{14.9, 14.9}).? == 10*10-1);
    // out of bounds - shifted by offset
    try std.testing.expect(heightmap.getCellId(.{0, 0}) == null);
    try std.testing.expect(heightmap.getCellId(.{15, 15}) == null);
}
