const std = @import("std");
const CollisionDetection = @import("CollisionDetection.zig").CollisionDetection;
const Vector2 = @import("Vector2.zig").Vector2;
const Worker = @import("Worker.zig").Worker;
const WorkQueue = @import("WorkQueue.zig").WorkQueue;
const Setup = @import("ZigGridLib.zig").Setup;
const ShapeTypeMod = @import("ShapeType.zig");
const ShapeType = ShapeTypeMod.ShapeType;
const ShapeData = ShapeTypeMod.ShapeData;

/// The Entity data required for SpacialGrid.update
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

/// The struct that is returned when two entities collide 
pub const CollisionPair = struct {
    a: usize,
    b: usize,
};

/// Collision detection system 
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
        allocator: std.mem.Allocator, 
        io: std.Io,

        width: f32, // Width of world 
        height: f32, // Height of world
        cell_size: f32 = 1, // Size of each cell.  Recommend it be 1.2-2x the size of largest entity
        cell_size_multiplier: f32 = 2.0, // Multiplier applied to the largest entity size when computing cell size via setCellSize.  Recommend 1.2-2.0

        ent_capacity: usize = 0, // The max amount of entities the SpacialGrid contains until next allocation

        // If null, thread count is set automatically to cpu core count.  multi_threaded variable still must be set to true
        thread_count: ?usize = null, 
        multi_threaded: bool = false, 
    };

    const Impl = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        width: f32,
        height: f32,
        rows: usize,
        cols: usize,
        cell_size: f32 = 1.0,

        indices: []usize,
        counts: []usize, // Tracks entity count per cell
        ent_count: usize = 0,
        ids: []usize = undefined,
        positions: []Vec2 = undefined,
        shape_data: []Shape = undefined,

        multi_threaded: bool = false,
        thread_count: ?usize = null,

        ent_capacity: usize,

        workers: []Worker(setup) = undefined, // Used for deviding work durring mulithreading 
        work_queue: WorkQueue = undefined, // Where workers pull their "work"
        query_buf: []usize = undefined, // Used for querying entities in a single threaded context
        has_updated: bool = false,

        pub fn getCellIndex(self: @This(), row: usize, row_offset: i32, col: usize, col_offset: i32) !usize {
            const row_val: i32 = @as(i32, @intCast(row)) + row_offset;
            const col_val: i32 = @as(i32, @intCast(col)) + col_offset;

            if(row_val < 0 or row_val >= @as(i32, @intCast(self.rows)) or
               col_val < 0 or col_val >= @as(i32, @intCast(self.cols)))
                return error.OutOfBounds;

            return @as(usize, @intCast(row_val)) * self.cols + @as(usize, @intCast(col_val));
        }

        pub fn getEntsFromCell(self: *@This(), cell_index: usize) []usize {
            const cell_start = if(cell_index > 0) self.counts[cell_index - 1] else 0;
            const cell_end = self.counts[cell_index];
            return self.indices[cell_start..cell_end];
        }

        fn getCellPos(self: @This(), pos: Vec2) !struct{row: usize, col: usize, idx: usize} {
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

        pub fn findCollisions(
            self: *@This(),
            grid: anytype,
            indices: []usize,
            positions: []Vec2,
            shape_data: []Shape,
            col_list: *std.ArrayList(CollisionPair),
            query_buf: []usize,
        ) void {
            for(indices) |id_a| {
                const pos_a = positions[id_a];
                const shape_a = shape_data[id_a];

                const nearby = grid.query(pos_a, query_buf) catch continue;

                for(nearby) |id_b| {
                    if(id_a >= id_b) continue;

                    const pos_b = positions[id_b];
                    const shape_b = shape_data[id_b];

                    if(CollisionDetection(Vec2).checkColliding(pos_a, shape_a, pos_b, shape_b)) {
                        col_list.append(self.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                    }
                }
            }
        }
    };

    impl: Impl,
    cell_size_multiplier: f32, // Multiplier applied to the largest entity size when computing cell size via setCellSize.  Recommend 1.2-2.0
    results: std.ArrayList(CollisionPair) = .empty, // Where collisions are kept after update is called

    /// Create a new instance of SpacialGrid
    pub fn init(config: Config) !*Self {
        const self = try config.allocator.create(Self);
        self.* = Self {
            .cell_size_multiplier = config.cell_size_multiplier,
            .impl = .{
                .allocator = config.allocator,
                .io = config.io,
                .width = config.width,
                .height = config.height,
                .rows = @intFromFloat(@ceil(config.height / config.cell_size)),
                .cols = @intFromFloat(@ceil(config.width / config.cell_size)),
                .ent_capacity = config.ent_capacity,
                .counts = undefined,
                .indices = undefined,
                .workers = undefined,
                .multi_threaded = config.multi_threaded,
                .thread_count = config.thread_count,
            },
        };

        // Allocate space for cells 
        self.impl.indices = try self.impl.allocator.alloc(usize, self.impl.ent_capacity);
        self.impl.counts = try self.impl.allocator.alloc(usize, self.impl.rows * self.impl.cols);
        @memset(self.impl.counts, 0);

        self.impl.ids = try self.impl.allocator.alloc(usize, self.impl.ent_capacity);
        self.impl.positions = try self.impl.allocator.alloc(Vec2, self.impl.ent_capacity);
        self.impl.shape_data = try self.impl.allocator.alloc(Shape, self.impl.ent_capacity);

        self.impl.query_buf = try config.allocator.alloc(usize, self.impl.ent_capacity);

        // Setting the thread count does not enable multi threading by itself
        if(self.impl.thread_count != null and !self.impl.multi_threaded) {
            std.log.warn("SpacialGrid.multi_threading must be set to true to enable multi_threading!\n", .{});
        }

        // Get number of cpu cores and create that many number of Workers/ threads 
        if(config.multi_threaded) {
            const thread_count = self.impl.thread_count orelse try std.Thread.getCpuCount();
            self.impl.workers = try config.allocator.alloc(Worker(setup), thread_count);

            // Init worker threads. 
            for(self.impl.workers) |*w| {
                w.* = try Worker(setup).init(self, self.impl.ent_capacity);
                try w.spawn();
            }

            self.impl.work_queue = .init(config.allocator, config.io);
        }
        try self.results.ensureTotalCapacity(self.impl.allocator, self.impl.ent_capacity);

        return self;
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.impl.allocator;
        allocator.free(self.impl.counts);
        allocator.free(self.impl.indices);
        allocator.free(self.impl.ids);
        allocator.free(self.impl.positions);
        allocator.free(self.impl.shape_data);
        allocator.free(self.impl.query_buf);

        // Deinit workers and free memory
        if(self.impl.multi_threaded) {  
            for(self.impl.workers) |*w| w.deinit();
            allocator.free(self.impl.workers);
        }
        self.results.deinit(self.impl.allocator);
        allocator.destroy(self);
    }

    /// Constructs SpacialGrid cells using entity data
    fn insert(self: *Self, ids: []usize, positions: []Vec2, shape_data: []Shape) !void {
        if(self.impl.has_updated) {
            self.reset();
        }

        // Resize if the new ent count passed in is greater than capacity
        const projected_ent_count = self.impl.ent_count + ids.len;
        if(projected_ent_count > self.impl.ent_capacity) try self.resizeBuffers(projected_ent_count * 2);
        
        const ent_count = self.impl.ent_count;
        for(ids, 0..) |id, i| {
            self.impl.ids[ent_count + i] = id;
        }

        for(positions, 0..) |pos, i| {
            self.impl.positions[ent_count + i] = pos;
        } 

        for(shape_data, 0..) |shape, i| {
            self.impl.shape_data[ent_count + i] = shape;
        } 

        self.impl.ent_count = projected_ent_count;
    }

    pub fn build(self: *Self) void {
        // For each entity position find the cell the ent 
        // exist in and increase the cell's count.
        for(0..self.impl.ent_count) |i| {
            const pos = self.impl.positions[i];
            const cell = self.impl.getCellPos(pos) catch continue;
            self.impl.counts[cell.idx] += 1;
        }

        // Prefix-sum pass: rewrite counts[i] from "entity count in cell i"
        // to "start offset of cell i in the indices array".
        var total: usize = 0;
        for(0..(self.impl.rows * self.impl.cols)) |i| {
            const count = &self.impl.counts[i];
            const placeholder = count.*;
            count.* = total;
            total += placeholder;
        }

        // Scatter pass: write each entity id into its cell's slot in indices,
        // advancing the cell's write cursor so consecutive ids pack contiguously.
        for(0..self.impl.ent_count) |i| {
            const pos = self.impl.positions[i];
            const cell = self.impl.getCellPos(pos) catch continue;
            const count_index: *usize = &self.impl.counts[cell.idx];
            self.impl.indices[count_index.*] = i;
            count_index.* += 1;
        }
    }

    pub fn reset(self: *Self) void {
        @memset(self.impl.counts, 0); 
        self.impl.has_updated = false;
        self.impl.ent_count = 0;
    }

    /// Get entities from cell of and neighboring cells of position
    pub fn query(self: *Self, pos: Vec2, buf: []usize) ![]usize {
        const cell_pos = try self.impl.getCellPos(pos);

        var len: usize = 0;
        for(0..3) |dr| {
            for(0..3) |dc| {
                const row_offset: i32 = @as(i32, @intCast(dr)) - 1;
                const col_offset: i32 = @as(i32, @intCast(dc)) - 1;
                const cell_index = self.impl.getCellIndex(
                    cell_pos.row, row_offset, cell_pos.col, col_offset
                ) catch continue;

                const slice = self.impl.getEntsFromCell(cell_index);
                @memcpy(buf[len..len + slice.len], slice);
                len += slice.len;
            }
        }

        return buf[0..len];
    }

    /// Main collision detection loop
    pub fn update(self: *Self, collision_data: CollisionD) !void {
        const workers = self.impl.workers;
        
        const indices = collision_data.indices;
        const positions = collision_data.positions;
        const shape_data = collision_data.shape_data;

        // Insert entities into the grid 
        self.results.clearRetainingCapacity();
        self.insert(indices, positions);

        // If not multi_threaded, just call findCollisions, else run workers
        if(!self.impl.multi_threaded) {
            self.impl.findCollisions(self, indices, positions, shape_data, &self.results, self.impl.query_buf);
            return;
        }

        // Have workers look for and save collisions 
        self.impl.work_queue.reset();
        for(workers) |*w| {
            w.col_list.clearRetainingCapacity();

            w.set(positions, shape_data);
            w.work_semaphore.post(self.impl.io);
        }

        // Once workers are finished, add their collisions to the grid's results
        for(workers) |*w| {
            w.done_semaphore.wait(self.impl.io) catch continue; 
            try self.results.appendSlice(self.impl.allocator, w.col_list.items);
        }
    }

    /// Allocate new buffers to accommodate new entity count
    fn resizeBuffers(self: *Self, new_len: usize) !void {
        self.impl.allocator.free(self.impl.indices);
        self.impl.allocator.free(self.impl.ids);
        self.impl.allocator.free(self.impl.positions);
        self.impl.allocator.free(self.impl.shape_data);
        self.impl.allocator.free(self.impl.query_buf);
        if(self.impl.multi_threaded) {
            for(self.impl.workers) |*w| w.allocator.free(w.query_buf);
        }

        const new_cap = @max(new_len, self.impl.ent_capacity * 2);
        self.impl.ent_capacity = new_cap;
        self.impl.indices = try self.impl.allocator.alloc(usize, new_cap);
        self.impl.ids = try self.impl.allocator.alloc(usize, new_cap);
        self.impl.positions = try self.impl.allocator.alloc(Vec2, new_cap);
        self.impl.shape_data = try self.impl.allocator.alloc(Shape, new_cap);
        self.impl.query_buf = try self.impl.allocator.alloc(usize, new_cap);
        if(self.impl.multi_threaded) {
            for(self.impl.workers) |*w| w.query_buf = try w.allocator.alloc(usize, new_cap);
        }
    }
    
    /// Set the size of the SpacialGrid's cell size to the size of the largest entity 
    /// multipied by SpacialGrid.cell_size_multiplier.
    /// Must be called before SpacialGrid.update and must be called whenever the maximum size 
    /// for an entity changes.   
    pub fn setCellSize(self: *Self, shape_data: []Shape) !void {
        const cell_size: f32 = blk: {
            var largest: f32 = 0.0;
            for(shape_data) |shape| {
                const size = switch(shape) {
                    .Circle => |r| r * 2 * self.cell_size_multiplier,
                    .Rect => |dim| @max(dim.x, dim.y) * self.cell_size_multiplier,
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
    }
};
}

pub fn getPrng(io: std.Io) std.Random.DefaultPrng {
    var seed: u64 = undefined; 
    io.random(std.mem.asBytes(&seed));
    return .init(seed);
}

