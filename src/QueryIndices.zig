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

        pub fn initForShapeQuery(grid: *Grid, x: f32, y: f32, shape_data: Grid.ShapeData) !Self {
            const allocator = grid.impl.allocator;
            var self: Self = undefined;
            self.allocator = allocator;

            self.c_buf = try allocator.alloc(u32, grid.impl.circle_storage.ent_count);
            self.r_buf = try allocator.alloc(u32, grid.impl.rect_storage.ent_count);
            self.p_buf = try allocator.alloc(u32, grid.impl.point_storage.ent_count);

            switch (shape_data) {
                .Circle => |r| {
                    var cells: std.ArrayList(usize) = .empty;
                    defer cells.deinit(allocator);
                    try cells.ensureTotalCapacity(allocator, grid.impl.rows * grid.impl.cols);

                    const pad = grid.impl.cell_size;
                    try appendCellsInBounds(
                        grid,
                        allocator,
                        &cells,
                        x - r - pad,
                        y - r - pad,
                        x + r + pad,
                        y + r + pad,
                    );

                    try self.queryCells(grid, cells.items);
                },
                .Rect => |dim| {
                    var cells: std.ArrayList(usize) = .empty;
                    defer cells.deinit(allocator);
                    try cells.ensureTotalCapacity(allocator, grid.impl.rows * grid.impl.cols);

                    const pad = grid.impl.cell_size;
                    try appendCellsInBounds(
                        grid,
                        allocator,
                        &cells,
                        x - pad,
                        y - pad,
                        x + dim.x + pad,
                        y + dim.y + pad,
                    );

                    try self.queryCells(grid, cells.items);
                },
                .Point => try self.queryPoint(grid, x, y),
            }

            self.total_count = self.c_indices.len + self.r_indices.len + self.p_indices.len;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.c_buf);
            self.allocator.free(self.r_buf);
            self.allocator.free(self.p_buf);
        }

        fn queryPoint(self: *Self, grid: *Grid, x: f32, y: f32) !void {
            self.c_indices = try grid.impl.circle_storage.query(grid, x, y, self.c_buf);
            self.r_indices = try grid.impl.rect_storage.query(grid, x, y, self.r_buf);
            self.p_indices = try grid.impl.point_storage.query(grid, x, y, self.p_buf);
        }

        fn queryCells(self: *Self, grid: *Grid, cell_indexes: []const usize) !void {
            self.c_indices = try grid.impl.circle_storage.queryCells(cell_indexes, self.c_buf);
            self.r_indices = try grid.impl.rect_storage.queryCells(cell_indexes, self.r_buf);
            self.p_indices = try grid.impl.point_storage.queryCells(cell_indexes, self.p_buf);
        }

        fn appendCellsInBounds(
            grid: *Grid,
            allocator: std.mem.Allocator,
            cells: *std.ArrayList(usize),
            top_x: f32,
            top_y: f32,
            bot_x: f32,
            bot_y: f32,
        ) !void {
            if (bot_x < 0 or bot_y < 0 or top_x >= grid.impl.width or top_y >= grid.impl.height) return;

            const min_x = @max(top_x, 0);
            const min_y = @max(top_y, 0);
            const max_x = @min(bot_x, grid.impl.width);
            const max_y = @min(bot_y, grid.impl.height);

            const start_col: usize = @intFromFloat(@floor(min_x / grid.impl.cell_size));
            const start_row: usize = @intFromFloat(@floor(min_y / grid.impl.cell_size));
            const end_col: usize = @min(@as(usize, @intFromFloat(@floor(max_x / grid.impl.cell_size))), grid.impl.cols - 1);
            const end_row: usize = @min(@as(usize, @intFromFloat(@floor(max_y / grid.impl.cell_size))), grid.impl.rows - 1);

            var row = start_row;
            while (row <= end_row) : (row += 1) {
                var col = start_col;
                while (col <= end_col) : (col += 1) {
                    const idx = row * grid.impl.cols + col;
                    if (std.mem.indexOfScalar(usize, cells.items, idx) == null) {
                        try cells.append(allocator, idx);
                    }
                }
            }
        }
    };
}

// Original simple init, before shape-aware query logic:
//
// pub fn init(grid: *Grid, x: f32, y: f32) !Self {
//     const allocator = grid.impl.allocator;
//     var self: Self = undefined;
//     self.allocator = allocator;
//
//     self.c_buf = try allocator.alloc(u32, grid.impl.circle_storage.ent_count);
//     self.r_buf = try allocator.alloc(u32, grid.impl.rect_storage.ent_count);
//     self.p_buf = try allocator.alloc(u32, grid.impl.point_storage.ent_count);
//
//     self.c_indices = try grid.impl.circle_storage.query(grid, x, y, self.c_buf);
//     self.r_indices = try grid.impl.rect_storage.query(grid, x, y, self.r_buf);
//     self.p_indices = try grid.impl.point_storage.query(grid, x, y, self.p_buf);
//
//     self.total_count = self.c_indices.len + self.r_indices.len + self.p_indices.len;
//     return self;
// }
