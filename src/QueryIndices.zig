const std = @import("std");

pub fn QueryIndices(comptime Grid: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        c_buf: []u32,
        c_indices: []u32,

        r_buf: []u32,
        r_indices: []u32,

        p_buf: []u32,
        p_indices: []u32,
        total_count: usize = 0,

        pub fn init(grid: *Grid, x: f32, y: f32) !Self {
            const allocator = grid.impl.allocator;
            var self: Self = undefined;
            self.allocator = allocator;

            self.c_buf = try allocator.alloc(u32, grid.impl.circle_storage.ent_count);
            self.r_buf = try allocator.alloc(u32, grid.impl.rect_storage.ent_count);
            self.p_buf = try allocator.alloc(u32, grid.impl.point_storage.ent_count);

            self.c_indices = try grid.impl.circle_storage.query(grid, x, y, self.c_buf);
            self.r_indices = try grid.impl.rect_storage.query(grid, x, y, self.r_buf);
            self.p_indices = try grid.impl.point_storage.query(grid, x, y, self.p_buf);

            self.total_count = self.c_indices.len + self.r_indices.len + self.p_indices.len;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.c_buf);
            self.allocator.free(self.r_buf);
            self.allocator.free(self.p_buf);
        }
    };
}
