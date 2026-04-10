const std = @import("std");
const CollisionDetection = @import("CollisionDetection.zig");
const Vector2 = @import("Vector2.zig").Vector2;

pub const ShapeType = enum { Point, Rect, Circle};
pub const ShapeData = union(ShapeType){
    Point: void,
    Rect: Vector2,
    Circle: f32,
};

pub const CollisionData = struct {
    indices: []usize,
    positions: []Vector2,
    shape_data: []ShapeData,
};

pub const CollisionPair = struct {
    a: usize,
    b: usize,
};

pub fn SpacialGrid(comptime thread_count: usize) type {
if(thread_count == 0) @compileError("Thread count must be greater than 0\n");
return struct {
    const Self = @This();

    pub const Config = struct {
        width: f32,
        height: f32,
        cell_size: f32,
        ent_count: usize,
        allocator: std.mem.Allocator,
    };

    const Impl = struct {
        width: f32,
        height: f32,
        rows: usize,
        cols: usize,
        cell_size: f32,
        ent_count: usize,
        allocator: std.mem.Allocator,

        counts: []usize,
        indices: []usize,
        buf_capacity: usize,
        thread_lists: [thread_count]std.ArrayList(CollisionPair),
        query_bufs: [thread_count][]usize,
    };

    impl: Impl,
    results: std.ArrayList(CollisionPair) = .empty,

    pub fn init(config: Config) !Self {
        var self = Self{
            .impl = .{
                .width = config.width,
                .height = config.height,
                .rows = @intFromFloat(@ceil(config.height / config.cell_size)),
                .cols = @intFromFloat(@ceil(config.width / config.cell_size)),
                .cell_size = config.cell_size,
                .ent_count = config.ent_count,
                .allocator = config.allocator,
                .buf_capacity = config.ent_count,
                .counts = undefined,
                .indices = undefined,
                .thread_lists = undefined,
                .query_bufs = undefined,
            },
        };

        self.impl.indices = try self.impl.allocator.alloc(usize, self.impl.buf_capacity);
        self.impl.counts = try self.impl.allocator.alloc(usize, self.impl.rows * self.impl.cols);
        @memset(self.impl.counts, 0);

        const initial_cap = self.impl.ent_count / 4;
        for(&self.impl.thread_lists) |*list| {
            list.* = .empty;
            try list.ensureTotalCapacity(self.impl.allocator, initial_cap);
        }
        try self.results.ensureTotalCapacity(self.impl.allocator, self.impl.ent_count);

        for(&self.impl.query_bufs) |*buf| {
            buf.* = try self.impl.allocator.alloc(usize, self.impl.buf_capacity);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.impl.allocator.free(self.impl.counts);
        self.impl.allocator.free(self.impl.indices);

        for(&self.impl.thread_lists) |*list| {
            list.deinit(self.impl.allocator);
        }

        self.results.deinit(self.impl.allocator);

        for(&self.impl.query_bufs) |*buf| {
            self.impl.allocator.free(buf.*);
        }
    }

    fn insert(self: *Self, ids: []usize, positions: []Vector2) void {
        @memset(self.impl.counts, 0);
        for(positions) |pos| {
            const cell = self.getCellPos(pos) catch continue;
            self.impl.counts[cell.idx] += 1;
        }

        var total: usize = 0;
        for(self.impl.counts) |*count| {
            const placeholder = count.*;
            count.* = total;
            total += placeholder;
        }

        for(positions, ids) |pos, id| {
            const cell = self.getCellPos(pos) catch continue;
            const count_index: *usize = &self.impl.counts[cell.idx];
            self.impl.indices[count_index.*] = id;
            count_index.* += 1;
        }
    }

    fn query(self: *Self, pos: Vector2, buf: []usize) ![]usize {
        const cell_pos = try self.getCellPos(pos);

        var len: usize = 0;
        for(0..3) |dr| {
            for(0..3) |dc| {
                const row_offset: i32 = @as(i32, @intCast(dr)) - 1;
                const col_offset: i32 = @as(i32, @intCast(dc)) - 1;
                const cell_index = self.getNeighborCellIndex(cell_pos.row, row_offset, cell_pos.col, col_offset) catch continue;

                const cell_start = if(cell_index > 0) self.impl.counts[(cell_index - 1)] else 0;
                const cell_end = self.impl.counts[cell_index];

                const slice = self.impl.indices[cell_start..cell_end];
                @memcpy(buf[len..len + slice.len], slice);
                len += slice.len;
            }
        }

        return buf[0..len];
    }

    fn getCellPos(self: Self, pos: Vector2) !struct{row: usize, col: usize, idx: usize} {
        const row: i32 = @intFromFloat(@floor(pos.y / self.impl.cell_size));
        const col: i32 = @intFromFloat(@floor(pos.x / self.impl.cell_size));

        if(row < 0 or row >= self.impl.rows or col < 0 or col >= self.impl.cols) return error.OutOfBounds;

        const row_casted: usize = @intCast(row);
        const col_casted: usize = @intCast(col);

        return .{
            .row = row_casted,
            .col = col_casted,
            .idx = (row_casted * self.impl.cols + col_casted),
        };
    }

    fn getNeighborCellIndex(self: Self, row: usize, row_offset: i32, col: usize, col_offset: i32) !usize {
        const row_val: i32 = @as(i32, @intCast(row)) + row_offset;
        const col_val: i32 = @as(i32, @intCast(col)) + col_offset;

        if(row_val < 0 or row_val >= @as(i32, @intCast(self.impl.rows)) or col_val < 0 or col_val >= @as(i32, @intCast(self.impl.cols))) return error.OutOfBounds;
        return @as(usize, @intCast(row_val)) * self.impl.cols + @as(usize, @intCast(col_val));
    }

    pub fn update(self: *Self, collision_data: CollisionData) !void {
        const indices = collision_data.indices;
        const positions = collision_data.positions;
        const shape_data = collision_data.shape_data;

        if(indices.len > self.impl.buf_capacity) try self.resizeBuffers(indices.len);
        self.insert(indices, positions);

        self.results.clearRetainingCapacity();

        for(&self.impl.thread_lists) |*list| {
            list.clearRetainingCapacity();
        }

        // If the amount of entities is less than the thread count,
        // run single threaded.  Trying to run more threads than entities
        // creates out of bounds arrays during the chunk generation below
        if(indices.len < thread_count or thread_count == 1) {
            findCollisions(self, indices, positions, shape_data, &self.impl.thread_lists[0], self.impl.query_bufs[0]);
            try self.results.appendSlice(self.impl.allocator, self.impl.thread_lists[0].items);
            return;
        }

        // Amount of entities / indices per thread
        const slice_unit: usize = indices.len / thread_count;

        // A chunk is a group of entities / indices to check for collision, separated across threads.
        const chunks = blk: {
            var slices: [thread_count][]usize = undefined;
            for(0..slices.len) |i| {
                const start = slice_unit * i;
                const end = if(i == slices.len - 1) indices.len else slice_unit * (i + 1);
                slices[i] = indices[start..end];
            }
            break :blk slices;
        };

        // Spawn new threads
        var threads: [thread_count]std.Thread = undefined;
        for(chunks, 0..) |chunk, i| {
            threads[i] = try std.Thread.spawn(
                .{.allocator = self.impl.allocator},
                findCollisions,
                .{self, chunk, positions, shape_data, &self.impl.thread_lists[i], self.impl.query_bufs[i]}
            );
        }

        for(threads) |t| {
            t.join();
        }

        for(&self.impl.thread_lists) |*list| {
            try self.results.appendSlice(self.impl.allocator, list.items);
        }
    }

    fn findCollisions(
        grid: *Self,
        indices: []usize,
        positions: []Vector2,
        shape_data: []ShapeData,
        col_list: *std.ArrayList(CollisionPair),
        query_buf: []usize
    ) void {
        for(indices) |id_a| {
            const pos_a = positions[id_a];
            const shape_a = shape_data[id_a];

            const nearby = grid.query(pos_a, query_buf) catch continue;

            for(nearby) |id_b| {
                if(id_a >= id_b) continue;

                const pos_b = positions[id_b];
                const shape_b = shape_data[id_b];

                if(CollisionDetection.checkColliding(pos_a, shape_a, pos_b, shape_b)) {
                    col_list.append(grid.impl.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                }
            }
        }
    }

    /// Allocate new buffers to accommodate new entity count
    fn resizeBuffers(self: *Self, new_len: usize) !void {
        self.impl.allocator.free(self.impl.indices);
        for(&self.impl.query_bufs) |*buf| self.impl.allocator.free(buf.*);

        const new_cap = @max(new_len, self.impl.buf_capacity * 2);
        self.impl.buf_capacity = new_cap;
        self.impl.indices = try self.impl.allocator.alloc(usize, new_cap);
        for(&self.impl.query_bufs) |*buf| buf.* = try self.impl.allocator.alloc(usize, new_cap);
    }

};
}
