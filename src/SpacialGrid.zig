const std = @import("std");
const Ball = @import("./Ball.zig").Ball;

pub const Vector2 = struct{x: f32, y: f32};

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
    Rect: struct {w: f32, h: f32},
    Circle: f32,
};

pub const SpacialGrid = struct {
    pub const CollisionPair = struct {
        a: usize,
        b: usize,
    };

    width: i32,
    height: i32,
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
            .rows = @intFromFloat(@ceil(@as(f32, @floatFromInt(config.height)) / config.cell_size)),
            .cols = @intFromFloat(@ceil(@as(f32, @floatFromInt(config.width)) / config.cell_size)),
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

    pub fn colliding(pos_a: Vector2, r_a: f32, pos_b: Vector2, r_b: f32) bool {
        const dist = pos_a.distance(pos_b);
        return (dist <= (r_a + r_b));
    }

    pub fn collidingRectCircle(rect_pos: Vector2, rect_dim: Vector2, circle_pos: Vector2, r: f32) bool {
        const rect = raylib.Rectangle.init(rect_pos.x - rect_dim.x / 2, rect_pos.y - rect_dim.y / 2, rect_dim.x, rect_dim.y);
        return raylib.checkCollisionCircleRec(circle_pos, r, rect);
    }
};


