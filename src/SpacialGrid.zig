const std = @import("std");
pub const Vector2 = struct{
    x: f32, 
    y: f32,

    pub fn eql(v1: Vector2, v2: Vector2) bool {
        return (v1.x == v2.x and v1.y == v2.y);
    }

    pub fn getDistanceSq(v1: Vector2, v2: Vector2) f32 {
        const dx: f32 = v1.x - v2.x;
        const dy: f32 = v1.y - v2.y;
        return (dx * dx + dy * dy);
    }
};

pub const Config = struct {
    width: i32,
    height: i32,
    cell_size: f32,
    ent_count: usize, 
    allocator: std.mem.Allocator,
};

pub const CollisionData = struct {
    indecies: []usize,
    positions: []Vector2, 
    shape_data: []ShapeData,
};

pub const ShapeData = union{
    Point: void,
    Rect: struct {w: f32, h: f32},
    Circle: f32,
};

pub const SpacialGrid = struct {
    pub const CollisionPair = struct {
        a: usize,
        b: usize,
    };

    width: f32,
    height: f32,
    rows: usize, 
    cols: usize,
    cell_size: f32,
    ent_count: usize, 
    allocator: std.mem.Allocator,

    counts: []usize = undefined,
    indecies: []usize = undefined,
    thread_lists: [4]std.ArrayList(CollisionPair) = undefined,
    all_collisions: std.ArrayList(CollisionPair) = .empty,
    query_bufs: [4][]usize = undefined,

    pub fn init (config: Config) !SpacialGrid {
        var self = SpacialGrid {
            .width = config.width,
            .height = config.height,
            .rows = @ceil(@as(f32, @floatFromInt(config.height)) / config.cell_size),
            .cols = @ceil(@as(f32, @floatFromInt(config.width)) / config.cell_size),
            .cell_size = config.cell_size,
            .ent_count = config.ent_count,
            .allocator = config.allocator,
        };

        self.indecies = try self.allocator.alloc(usize, self.ent_count);
        self.counts = try self.allocator.alloc(usize, self.rows * self.cols);
        @memset(self.counts, 0);

        const initial_cap = self.ent_count / 4;
        for(&self.thread_lists) |*list| {
            list.* = .empty;
            try list.ensureTotalCapacity(self.allocator, initial_cap);
        }
        try self.all_collisions.ensureTotalCapacity(self.allocator, self.ent_count);

        for(&self.query_bufs) |*buf| {
            buf.* = try self.allocator.alloc(usize, self.ent_count);
        }

        return self;
    }

    pub fn deinit(self: *SpacialGrid) void {
        self.allocator.free(self.counts);
        self.allocator.free(self.indecies);
        for(&self.thread_lists) |*list| {
            list.deinit(self.allocator);
        }
        self.all_collisions.deinit(self.allocator);
        for(&self.query_bufs) |*buf| {
            self.allocator.free(buf.*);
        }
    }

    fn insert(self: *SpacialGrid, ids: []usize, positions: []Vector2) void {
        @memset(self.counts, 0);
        for(positions) |pos| {
            const cell = self.getCellPos(pos) catch continue;
            self.counts[cell.idx] += 1; 
        } 

        var total: usize = 0;
        for(self.counts) |*count| {
            const placeholder = count.*;
            count.* = total;
            total += placeholder;
        }

        for(positions, ids) |pos, id| {
            const cell = self.getCellPos(pos) catch continue;
            const count_index: *usize = &self.counts[cell.idx];
            self.indecies[count_index.*] = id; 
            count_index.* += 1;
        }
    }

    pub fn query(self: *SpacialGrid, pos: Vector2, buf: []usize) ![]usize {
        const cell_pos = try self.getCellPos(pos);

        var len: usize = 0;
        for(0..3) |dr| {
            for(0..3) |dc| {
                const row_offset: i32 = @as(i32, @intCast(dr)) - 1;
                const col_offset: i32 = @as(i32, @intCast(dc)) - 1;
                const cell_index = self.getNeighborCellIndex(cell_pos.row, row_offset, cell_pos.col, col_offset) catch continue;

                const cell_start = if(cell_index > 0) self.counts[(cell_index - 1)] else 0;
                const cell_end = self.counts[cell_index];

                const slice = self.indecies[cell_start..cell_end];
                @memcpy(buf[len..len + slice.len], slice);
                len += slice.len;
            }
        }

        return buf[0..len];
    }

    fn getCellPos(self: SpacialGrid, pos: Vector2) !struct{row: usize, col: usize, idx: usize} {
        const row: i32 = @intFromFloat(@floor(pos.y / self.cell_size));
        const col: i32 = @intFromFloat(@floor(pos.x / self.cell_size));

        if(row < 0 or row >= self.rows or col < 0 or col >= self.cols) return error.OutOfBounds;
        
        const row_casted: usize = @intCast(row);
        const col_casted: usize = @intCast(col);

        return .{
            .row = row_casted,
            .col = col_casted,
            .idx = (row_casted * self.cols + col_casted),
        };
    }

    fn getNeighborCellIndex(self: SpacialGrid, row: usize, row_offset: i32, col: usize, col_offset: i32) !usize {
        const row_val: i32 = @as(i32, @intCast(row)) + row_offset;
        const col_val: i32 = @as(i32, @intCast(col)) + col_offset;

        if(row_val < 0 or row_val >= @as(i32, @intCast(self.rows)) or col_val < 0 or col_val >= @as(i32, @intCast(self.cols))) return error.OutOfBounds;
        return @as(usize, @intCast(row_val)) * self.cols + @as(usize, @intCast(col_val));
    }

    pub fn update(self: *SpacialGrid, collision_data: CollisionData) ![]CollisionPair{
        const indecies = collision_data.indecies;
        const positions = collision_data.positions;
        
        self.insert(indecies, positions);

        self.all_collisions.clearRetainingCapacity();
        for(&self.thread_lists) |*list| {
            list.clearRetainingCapacity();
        }

        const slice_unit: usize = indecies.len / 4;

        const find_cols = struct {
            fn func(
                grid: *SpacialGrid, 
                chunk_ids: []usize, 
                all_positions: []Vector2, 
                all_radii: []f32, 
                col_list: *std.ArrayList(CollisionPair), 
                query_buf: []usize
            ) void {
                for(chunk_ids) |id_a| {
                    const pos_a = all_positions[id_a];
                    const r_a = all_radii[id_a];

                    const nearby = grid.query(pos_a, query_buf) catch continue;

                    for(nearby) |id_b| {
                        if(id_a >= id_b) continue;

                        const pos_b = all_positions[id_b];
                        const r_b = all_radii[id_b];

                        if(SpacialGrid.colliding(pos_a, r_a, pos_b, r_b)){
                            col_list.append(grid.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                        }
                    }
                }
            }
        };

        const slices = [4][]usize{
            indecies[0..slice_unit],
            indecies[slice_unit..slice_unit * 2],
            indecies[slice_unit * 2..slice_unit * 3],
            indecies[slice_unit * 3..],
        };

        var threads: [4]std.Thread = undefined;
        for(slices, 0..) |chunk, i| {
            threads[i] = try std.Thread.spawn(
                .{.allocator = self.allocator},
                find_cols.func,
                .{self, chunk, positions, radii, &self.thread_lists[i], self.query_bufs[i]}
            );
        }

        for(threads) |t| {
            t.join();
        }

        for(&self.thread_lists) |*list| {
            try self.all_collisions.appendSlice(self.allocator, list.items);
        }

        return try self.all_collisions.toOwnedSlice(self.allocator);
    }

    fn findNeighbors(
        grid: *SpacialGrid, 
        indecies: []usize, 
        positions: []Vector2, 
        shape_data: []ShapeData, 
        col_list: *std.ArrayList(CollisionPair), 
        query_buf: []usize
    ) void {
        for(indecies) |id_a| {
            const pos_a = positions[id_a];
            const shape_a = shape_data[id_a];

            const nearby = grid.query(pos_a, query_buf) catch continue;

            for(nearby) |id_b| {
                if(id_a >= id_b) continue;

                const pos_b = positions[id_b];
                const shape_b = shape_data[id_b];

                if(SpacialGrid.colliding(pos_a, shape_a, pos_b, shape_b)) {
                    col_list.append(grid.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                }
            }
        }
    }

    pub fn checkColliding(pos_a: Vector2, shape_a: ShapeData, pos_b: Vector2, shape_b: ShapeData) bool {
        switch (shape_a) {
            .Circle => |r1| switch(shape_b) {
                .Circle => |r2| circleCollision(pos_a, r1, pos_b, r2), 
                .Rect => |dim| rectCircleCollision(pos_b, dim, pos_a, r1), 
                .Point => pointCircleCollision(pos_a, r1, pos_b),
            },
            .Rect => |dim1| switch(shape_b) {
                .Circle => |r| circleCollision(pos_b, r, pos_a, dim1), 
                .Rect => |dim2| rectCollision(pos_a, dim1, pos_b, dim2), 
                .Point => pointRectCollision(pos_a, dim1, pos_b)
            },
            .Point => switch(shape_b) {
                .Circle => |r| pointCircleCollision(pos_b, r, pos_a),
                .Rect => |dim| pointRectCollision(pos_b, dim, pos_a),
                .Point => pointCollision(pos_b, pos_a),
            }
        }
    }

    /// Get distance between two circles.  
    pub fn circleCollision(pos_a: Vector2, r_a: f32, pos_b: Vector2, r_b: f32) bool {
        const dist = Vector2.getDistanceSq(pos_a, pos_b);
        const r = r_a + r_b;

        return dist < (r * r);
    }

    /// Get distance between two Rectangles.  Assumes coordinates start at top left of rect.
    pub fn rectCollision(pos_a: Vector2, dim_a: Vector2, pos_b: Vector2, dim_b: Vector2) bool {
        return (
            (pos_a.x < pos_b.x + dim_b.x and pos_a.x + dim_a.x > pos_b.x) 
                                         and 
            (pos_a.y < pos_b.y + dim_b.y and pos_a.y + dim_a.y > pos_b.y)
        );
    }

    pub fn pointCollision(point1: Vector2, point2: Vector2) bool {
        return Vector2.eql(point1, point2);
    }

    pub fn rectCircleCollision(rect_pos: Vector2, rect_dim: Vector2, circle_pos: Vector2, r: f32) bool {
        _ = rect_pos; _ = rect_dim; _ = circle_pos; _ = r;
    }

    pub fn pointCircleCollision(pos_a: Vector2, r: f32, point: Vector2) bool {
        const dist = Vector2.getDistanceSq(point, pos_a);
        return (dist < r * r);
    }


    pub fn pointRectCollision(pos_a: Vector2, dim: Vector2, point: Vector2) bool {
        _ = pos_a; _ = r; _ = point;
    }

};


