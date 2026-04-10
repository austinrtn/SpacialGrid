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


pub const CollisionData = struct {
    indecies: []usize,
    positions: []Vector2, 
    shape_data: []ShapeData,
};

pub const ShapeType = enum { Point, Rect, Circle};
pub const ShapeData = union(ShapeType){
    Point: void,
    Rect: Vector2,
    Circle: f32,
};

pub fn SpacialGrid(comptime thread_count: usize) type {
return struct {
    const Self = @This();
    pub const CollisionPair = struct {
        a: usize,
        b: usize,
    };

    pub const Config = struct {
        width: f32,
        height: f32,
        cell_size: f32,
        ent_count: usize, 
        allocator: std.mem.Allocator,
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
    thread_lists: [thread_count]std.ArrayList(CollisionPair) = undefined,
    all_collisions: std.ArrayList(CollisionPair) = .empty,
    query_bufs: [thread_count][]usize = undefined,

    pub fn init (config: Config) !Self {
        var self = Self {
            .width = config.width,
            .height = config.height,
            .rows = @intFromFloat(@ceil(config.height / config.cell_size)),
            .cols = @intFromFloat(@ceil(config.width / config.cell_size)),
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

    pub fn deinit(self: *Self) void {
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

    fn insert(self: *Self, ids: []usize, positions: []Vector2) void {
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

    pub fn query(self: *Self, pos: Vector2, buf: []usize) ![]usize {
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

    fn getCellPos(self: Self, pos: Vector2) !struct{row: usize, col: usize, idx: usize} {
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

    fn getNeighborCellIndex(self: Self, row: usize, row_offset: i32, col: usize, col_offset: i32) !usize {
        const row_val: i32 = @as(i32, @intCast(row)) + row_offset;
        const col_val: i32 = @as(i32, @intCast(col)) + col_offset;

        if(row_val < 0 or row_val >= @as(i32, @intCast(self.rows)) or col_val < 0 or col_val >= @as(i32, @intCast(self.cols))) return error.OutOfBounds;
        return @as(usize, @intCast(row_val)) * self.cols + @as(usize, @intCast(col_val));
    }

    pub fn update(self: *Self, collision_data: CollisionData) ![]CollisionPair{
        const indecies = collision_data.indecies;
        const positions = collision_data.positions;
        const shape_data = collision_data.shape_data;
        
        self.insert(indecies, positions);

        self.all_collisions.clearRetainingCapacity();
        for(&self.thread_lists) |*list| {
            list.clearRetainingCapacity();
        }

        const slice_unit: usize = indecies.len / thread_count;

        const chunks = blk: {
            const slices: [thread_count][]usize = undefined;
            for(0..slices.len) |i| {
                if(i == slices.len - 1) slices[i] = indecies[slice_unit * i..]
                else if(i == 0) slices[i] = indecies[0..(slice_unit * i + 1)]
                //else 
            }
        };

        const slices = [thread_count][]usize{
            indecies[0..slice_unit],
            indecies[slice_unit..slice_unit * 2],
            indecies[slice_unit * 2..slice_unit * 3],
            indecies[slice_unit * 3..],
        };

        var threads: [thread_count]std.Thread = undefined;
        for(slices, 0..) |chunk, i| {
            threads[i] = try std.Thread.spawn(
                .{.allocator = self.allocator},
                findCollisions,
                .{self, chunk, positions, shape_data, &self.thread_lists[i], self.query_bufs[i]}
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

    fn findCollisions(
        grid: *Self, 
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

                if(checkColliding(pos_a, shape_a, pos_b, shape_b)) {
                    col_list.append(grid.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                }
            }
        }
    }

    pub fn checkColliding(pos_a: Vector2, shape_a: ShapeData, pos_b: Vector2, shape_b: ShapeData) bool {
        return switch (shape_a) {
            .Circle => |r1| switch(shape_b) {
                .Circle => |r2| circleCollision(pos_a, r1, pos_b, r2), 
                .Rect => |dim| rectCircleCollision(pos_b, dim, pos_a, r1), 
                .Point => pointCircleCollision(pos_a, r1, pos_b),
            },
            .Rect => |dim1| switch(shape_b) {
                .Circle => |r| rectCircleCollision(pos_a, dim1, pos_b, r), 
                .Rect => |dim2| rectCollision(pos_a, dim1, pos_b, dim2), 
                .Point => pointRectCollision(pos_a, dim1, pos_b)
            },
            .Point => switch(shape_b) {
                .Circle => |r| pointCircleCollision(pos_b, r, pos_a),
                .Rect => |dim| pointRectCollision(pos_b, dim, pos_a),
                .Point => pointCollision(pos_b, pos_a),
            }
        };
    }

    /// Check collision between two circles.  
    pub fn circleCollision(pos_a: Vector2, r_a: f32, pos_b: Vector2, r_b: f32) bool {
        const dist = Vector2.getDistanceSq(pos_a, pos_b);
        const r = r_a + r_b;

        return dist < (r * r);
    }

    /// Check collision between two Rectangles.  Assumes coordinates start at top left of rect.
    pub fn rectCollision(pos_a: Vector2, dim_a: Vector2, pos_b: Vector2, dim_b: Vector2) bool {
        return (
            (pos_a.x < pos_b.x + dim_b.x and pos_a.x + dim_a.x > pos_b.x) 
                                         and 
            (pos_a.y < pos_b.y + dim_b.y and pos_a.y + dim_a.y > pos_b.y)
        );
    }

    /// Check collision between two points (if both points are equal).
    pub fn pointCollision(point1: Vector2, point2: Vector2) bool {
        return Vector2.eql(point1, point2);
    }

    /// Check collision between a circle and a rectangle.  Assumes coordinates start at top left for rectangle.
    pub fn rectCircleCollision(rect_pos: Vector2, rect_dim: Vector2, circle_pos: Vector2, r: f32) bool {
        const closest_x = @max(rect_pos.x, @min(circle_pos.x, rect_pos.x + rect_dim.x));
        const closest_y = @max(rect_pos.y, @min(circle_pos.y, rect_pos.y + rect_dim.y));

        const dx = circle_pos.x - closest_x;
        const dy = circle_pos.y - closest_y;

        return (dx * dx + dy * dy) < (r * r);
    }

    /// Check collision between a circle and a point
    pub fn pointCircleCollision(pos_a: Vector2, r: f32, point: Vector2) bool {
        const dist = Vector2.getDistanceSq(point, pos_a);
        return (dist < r * r);
    }

    /// Check collision between a rectangle and a point
    pub fn pointRectCollision(pos_a: Vector2, dim: Vector2, point: Vector2) bool {
        return (
            (point.x >= pos_a.x and point.x <= pos_a.x + dim.x)
                                and
            (point.y >= pos_a.y and point.y <= pos_a.y + dim.y)
        );
    }
};
}
