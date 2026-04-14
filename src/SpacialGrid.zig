const std = @import("std");
const CollisionDetection = @import("CollisionDetection.zig").CollisionDetection;
const Vector2 = @import("Vector2.zig").Vector2;
const Worker = @import("Worker.zig").Worker;
const WorkQueue = @import("WorkQueue.zig").WorkQueue;
const Setup = @import("ZigGridLib.zig").Setup;
const ShapeTypeMod = @import("ShapeType.zig");
const ShapeType = ShapeTypeMod.ShapeType;
const ShapeData = ShapeTypeMod.ShapeData;


pub fn CollisionData(comptime Vec2: type) type { 
    if(!@hasField(Vec2, "x") or !@hasField(Vec2, "y")) {
        @compileError("Vector2 type must contain both fields x and y");
    }

    return struct {
        indices: []usize,
        positions: []Vec2,
        shape_data: []ShapeData(Vec2),
    };
}

pub const CollisionPair = struct {
    a: usize,
    b: usize,
};

pub fn SpacialGrid(comptime setup: Setup) type {
    const Vec2 = setup.Vector2;
    const Shape = ShapeData(Vec2);
    const CollisionD = CollisionData(Vec2);

    if(!@hasField(Vec2, "x") or !@hasField(Vec2, "y")) {
        @compileError("Vector2 type must contain both fields x and y");
    }

return struct {
    const Self = @This();
    pub const Vector2 = Vec2;
    pub const ShapeData = Shape;
    
    /// A struct that represents an entity and 
    /// contains all necessary data for collision
    pub const Entity = struct {
        pos: Vec2,
        shape_data: Shape,
        id: usize,

        pub fn init(pos: Vec2, shape_data: Shape, id: usize) Entity {
            return .{.pos = pos, .shape_data = shape_data, .id = id};
        }
    };

    /// Necessary for initing a SpacialGrid instance
    pub const Config = struct {
        width: f32,
        height: f32,
        cell_size: f32,
        allocator: std.mem.Allocator,
        io: std.Io,
        ent_count: usize = 0,
        multi_threaded: bool = false,
        auto_cell_resize: bool = true,
    };

    const Impl = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        width: f32,
        height: f32,
        rows: usize,
        cols: usize,
        cell_size: f32 = 1.0,
        cell_size_set: bool = false,
        ent_count: usize,

        counts: []usize,
        multi_threaded: bool = false,
        indices: []usize,
        buf_capacity: usize,
        auto_cell_resize: bool = true,
        workers: []Worker(setup) = undefined,
        work_queue: WorkQueue = undefined,

        col_list: std.ArrayList(CollisionPair) = .empty,
        query_buf: []usize = undefined
    };

    impl: Impl,
    results: std.ArrayList(CollisionPair) = .empty,

    /// Create a new instance of SpacialGrid
    pub fn init(config: Config) !*Self {
        const self = try config.allocator.create(Self);
        self.* = Self {
            .impl = .{
                .allocator = config.allocator,
                .io = config.io,
                .width = config.width,
                .height = config.height,
                .rows = @intFromFloat(@ceil(config.height / config.cell_size)),
                .cols = @intFromFloat(@ceil(config.width / config.cell_size)),
                .ent_count = config.ent_count,
                .buf_capacity = config.ent_count,
                .counts = undefined,
                .indices = undefined,
                .workers = undefined,
                .multi_threaded = config.multi_threaded,
                .auto_cell_resize = config.auto_cell_resize,
            },
        };

        self.impl.indices = try self.impl.allocator.alloc(usize, self.impl.buf_capacity);
        self.impl.counts = try self.impl.allocator.alloc(usize, self.impl.rows * self.impl.cols);
        @memset(self.impl.counts, 0);

        self.impl.query_buf = try config.allocator.alloc(usize, self.impl.buf_capacity);

        if(config.multi_threaded) {  
            const thread_count = try std.Thread.getCpuCount();
            self.impl.workers = try config.allocator.alloc(Worker(setup), thread_count);

            // Init worker threads. 
            for(&self.impl.workers) |*w| {
                w.* = try Worker(setup).init(self, self.impl.buf_capacity);
                try w.spawn();
            }

            self.impl.work_queue = .init(config.allocator, config.io);
        }
        try self.results.ensureTotalCapacity(self.impl.allocator, self.impl.ent_count);

        return self;
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.impl.allocator;
        allocator.free(self.impl.counts);
        allocator.free(self.impl.indices);

        // Deinit workers and free memory
        for(&self.impl.workers) |*w| w.deinit();
        allocator.free(self.impl.workers);

        self.results.deinit(self.impl.allocator);
        allocator.destroy(self);
    }

    /// Constructs SpacialGrid cells using entity data
    fn insert(self: *Self, ids: []usize, positions: []Vec2) void {
        // Reset counts slice
        @memset(self.impl.counts, 0); 

        // For each entity position find the cell the ent 
        // exist in and increase the cell's count.
        for(positions) |pos| {
            const cell = self.getCellPos(pos) catch continue;
            self.impl.counts[cell.idx] += 1;
        }

        // Prefix-sum pass: rewrite counts[i] from "entity count in cell i"
        // to "start offset of cell i in the indices array".
        var total: usize = 0;
        for(self.impl.counts) |*count| {
            const placeholder = count.*;
            count.* = total;
            total += placeholder;
        }

        // Scatter pass: write each entity id into its cell's slot in indices,
        // advancing the cell's write cursor so consecutive ids pack contiguously.
        for(positions, ids) |pos, id| {
            const cell = self.getCellPos(pos) catch continue;
            const count_index: *usize = &self.impl.counts[cell.idx];
            self.impl.indices[count_index.*] = id;
            count_index.* += 1;
        }
    }

    fn query(self: *Self, pos: Vec2, buf: []usize) ![]usize {
        const cell_pos = try self.getCellPos(pos);

        var len: usize = 0;
        for(0..3) |dr| {
            for(0..3) |dc| {
                const row_offset: i32 = @as(i32, @intCast(dr)) - 1;
                const col_offset: i32 = @as(i32, @intCast(dc)) - 1;
                const cell_index = self.getCellIndex(
                    cell_pos.row, row_offset, cell_pos.col, col_offset
               ) catch continue;


                const slice = self.getEntsFromCell(cell_index); 
                @memcpy(buf[len..len + slice.len], slice);
                len += slice.len;
            }
        }

        return buf[0..len];
    }

    pub fn getEntsFromCell(self: *Self, cell_index: usize) []usize {
                const cell_start = if(cell_index > 0) self.impl.counts[(cell_index - 1)] else 0;
                const cell_end = self.impl.counts[cell_index];
                return self.impl.indices[cell_start..cell_end];
    }

    fn getCellPos(self: Self, pos: Vec2) !struct{row: usize, col: usize, idx: usize} {
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

    pub fn getCellIndex(self: Self, row: usize, row_offset: i32, col: usize, col_offset: i32) !usize {
        const row_val: i32 = @as(i32, @intCast(row)) + row_offset;
        const col_val: i32 = @as(i32, @intCast(col)) + col_offset;

        if(row_val < 0 or row_val >= @as(i32, @intCast(self.impl.rows)) or
           col_val < 0 or col_val >= @as(i32, @intCast(self.impl.cols))) 
            return error.OutOfBounds;

        return @as(usize, @intCast(row_val)) * self.impl.cols + @as(usize, @intCast(col_val));
    }

    pub fn update(self: *Self, collision_data: CollisionD, profiler: anytype) !void {
        const workers = &self.impl.workers;
        
        if(!self.impl.auto_cell_resize and !self.impl.cell_size_set) {
            std.log.err(
            "Must call SpacialGrid.setCellSize before calling SpacialGrid.update"
            , .{});
            return error.CellSizeNotSet;
        }

        const indices = collision_data.indices;
        const positions = collision_data.positions;
        const shape_data = collision_data.shape_data;

        if(indices.len > self.impl.buf_capacity or (self.impl.auto_cell_resize and !self.impl.cell_size_set)) {
            try self.resizeBuffers(indices.len);
            if(self.impl.auto_cell_resize) try self.setCellSize(shape_data, 2);
        }

        self.results.clearRetainingCapacity();

        const insert_start = std.Io.Clock.Timestamp.now(self.impl.io, .awake);
        self.insert(indices, positions);
        const insert_end = insert_start.durationTo(std.Io.Clock.Timestamp.now(self.impl.io, .awake));
        if(@hasField(@TypeOf(profiler.*), "insert"))
            profiler.insert.append(self.impl.allocator, insert_end.raw.toNanoseconds()) catch @panic("Profiler\n");

        if(@hasField(@TypeOf(profiler.*), "cell_max")) {
            var max: usize = 0;
            for(0..self.impl.counts.len) |ci| {
                const start = if(ci > 0) self.impl.counts[ci - 1] else 0;
                const count = self.impl.counts[ci] - start;
                if(count > max) max = count;
            }
            profiler.cell_max.append(self.impl.allocator, max) catch @panic("Profiler\n");
        }

        if(!self.impl.multi_threaded) {
            const col_list = &workers[0].col_list;
            const query_buf = workers[0].query_buf;

            col_list.clearRetainingCapacity();
            
            findCollisions(self, indices, positions, shape_data, col_list, query_buf, profiler);

            try self.results.appendSlice(self.impl.allocator, col_list.items);
            return;
        }

        self.impl.work_queue.reset();
        for(workers) |*w| {
            w.col_list.clearRetainingCapacity();

            w.set(positions, shape_data);
            w.work_semaphore.post(self.impl.io);
        }

        for(workers) |*w| {
            w.done_semaphore.wait(self.impl.io) catch continue; 
            try self.results.appendSlice(self.impl.allocator, w.col_list.items);
        }
    }

    pub fn findCollisions(
        grid: *Self,
        indices: []usize,
        positions: []Vec2,
        shape_data: []Shape,
        col_list: *std.ArrayList(CollisionPair),
        query_buf: []usize,
        profiler: anytype,
    ) void {
        for(indices) |id_a| {
            const pos_a = positions[id_a];
            const shape_a = shape_data[id_a];

            const query_start = std.Io.Clock.Timestamp.now(grid.impl.io, .awake);
            const nearby = grid.query(pos_a, query_buf) catch continue;
            const query_end = query_start.durationTo(std.Io.Clock.Timestamp.now(grid.impl.io, .awake));
            if(@hasField(@TypeOf(profiler.*), "query"))
                profiler.query.append(grid.impl.allocator, query_end.raw.toNanoseconds()) catch @panic("Profiler\n");

            for(nearby) |id_b| {
                if(id_a >= id_b) continue;

                const pos_b = positions[id_b];
                const shape_b = shape_data[id_b];

                const col_time_start = std.Io.Clock.Timestamp.now(grid.impl.io, .awake);
                const colliding = CollisionDetection(Vec2).checkColliding(pos_a, shape_a, pos_b, shape_b);
                const col_end = col_time_start.durationTo(std.Io.Clock.Timestamp.now(grid.impl.io, .awake));
                if(@hasField(@TypeOf(profiler.*), "collision"))
                    profiler.collision.append(grid.impl.allocator, col_end.raw.toNanoseconds()) catch @panic("Profiler\n");

                if(colliding) {
                    if(@hasField(@TypeOf(profiler.*), "hits")) profiler.hits += 1;
                    col_list.append(grid.impl.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                }
            }
        }
    }

    /// Allocate new buffers to accommodate new entity count
    fn resizeBuffers(self: *Self, new_len: usize) !void {
        self.impl.allocator.free(self.impl.indices);
        for(&self.impl.workers) |*w| w.allocator.free(w.query_buf);

        const new_cap = @max(new_len, self.impl.buf_capacity * 2);
        self.impl.buf_capacity = new_cap;
        self.impl.indices = try self.impl.allocator.alloc(usize, new_cap);
        for(&self.impl.workers) |*w| w.query_buf = try w.allocator.alloc(usize, new_cap);
    }
    
    /// Set the size of the SpacialGrid's cells to largest entity multiplied by N 
    pub fn setCellSize(self: *Self, shape_data: []Shape, n: f32) !void {
        if(n < 1) @panic("n is less than 1\n");

        const cell_size: f32 = blk: {
            var largest: f32 = 0.0;
            for(shape_data) |shape| {
                const size = switch(shape) {
                    .Circle => |r| r * 2 * n,
                    .Rect => |dim| @max(dim.x, dim.y) * n,
                    .Point => 0,
                };

                if(size > largest) largest = size;
            }
            if(largest == 0) largest = 1;
            break :blk largest;
        };

        self.impl.cell_size = cell_size;
        self.impl.rows = @intFromFloat(@ceil(self.impl.height / self.impl.cell_size));
        self.impl.cols = @intFromFloat(@ceil(self.impl.width / self.impl.cell_size));
        self.impl.allocator.free(self.impl.counts);
        self.impl.counts = try self.impl.allocator.alloc(usize, self.impl.rows * self.impl.cols);
        self.impl.cell_size_set = true;
    }
};
}

pub fn getPrng(io: std.Io) std.Random.DefaultPrng {
    var seed: u64 = undefined; 
    io.random(std.mem.asBytes(&seed));
    return .init(seed);
}

