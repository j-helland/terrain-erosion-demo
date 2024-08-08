const std = @import("std");

/// Generic pool allocator on top of an arena.
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        const List = std.DoublyLinkedList(T);

        arena: std.heap.ArenaAllocator,
        freelist: List = .{},

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn alloc(self: *Self) !*T {
            const node = 
                if (self.freelist.popFirst()) |free_node|
                    free_node
                else
                    try self.arena.allocator().create(List.Node);
            return &node.data;
        }

        pub fn free(self: *Self, data: *T) void {
            const node = @as(*List.Node, @alignCast(@fieldParentPtr("data", data)));
            self.freelist.append(node);
        }
    };
}

test "Pool" {
    var pool = Pool(u32).init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expectEqual(0, pool.freelist.len);
    const n1 = try pool.alloc();
    _ = try pool.alloc();
    try std.testing.expectEqual(0, pool.freelist.len);

    pool.free(n1);
    try std.testing.expectEqual(1, pool.freelist.len);

    const n3 = try pool.alloc();
    try std.testing.expectEqual(0, pool.freelist.len);
    try std.testing.expectEqual(n1, n3);
}