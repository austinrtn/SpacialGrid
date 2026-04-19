const std = @import("std");
const CollisionDetection = @import("CollisionDetection.zig").CollisionDetection;
const Vector2 = @import("Vector2.zig").Vector2;
const Worker = @import("Worker.zig").Worker;
const WorkQueueMod = @import("WorkQueue.zig");
const WorkQueue = WorkQueueMod.WorkQueue;
const WorkItem = WorkQueueMod.WorkItem;

const Setup = @import("ZigGridLib.zig").Setup;
const ShapeTypeMod = @import("ShapeType.zig");
const ShapeType = ShapeTypeMod.ShapeType;
const ShapeData = ShapeTypeMod.ShapeData;
const EntStorage = @import("EntStorage.zig").EntStorage;

/// The Entity data required for SpacialGrid.update
pub fn CollisionData(comptime Vec2: type) type { 
    if(!@hasField(Vec2, "x") or !@hasField(Vec2, "y")) {
        @compileError("Vector2 type must contain both fields x and y");
    }

    return struct {
        indices: []u32,
        positions: []Vec2,
        shape_data: []ShapeData(Vec2),
    };
}

/// The struct that is returned when two entities collide
pub const CollisionPair = struct {
    a: u32,
    b: u32,
};

const CellData = struct{row: usize, col: usize, idx: usize}; 
/// Collision detection system 
pub fn SpacialGrid(comptime setup: Setup) type {
    const Vec2 = setup.Vector2;
    const Shape = ShapeData(Vec2);
    //const CollisionD = CollisionData(Vec2);

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
        id: u32,

        pub fn init(pos: Vec2, shape_data: Shape, id: u32) Entity {
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

        ent_count: u32 = 0,
        circle_storage: EntStorage(.Circle) = undefined,
        rect_storage: EntStorage(.Rect) = undefined,
        point_storage: EntStorage(.Point) = undefined,

        multi_threaded: bool = false,
        thread_count: ?usize = null,

        ent_capacity: u32 = 0,

        workers: []Worker(setup) = undefined, // Used for deviding work durring mulithreading
        work_queue: WorkQueue = undefined, // Where workers pull their "work"
        query_buf: []u32 = undefined, // Used for querying entities in a single threaded context
        has_updated: bool = false,

        pub fn getCellIndex(self: @This(), row: i32, col: i32) !usize {
            if (row < 0 or col < 0) return error.OutOfBounds;
            const r: usize = @intCast(row);
            const c: usize = @intCast(col);
            if (r >= self.rows or c >= self.cols) return error.OutOfBounds;
            return r * self.cols + c;
        }

        /// Fills `buf` with the linear indices of the (up to 9) cells in the
        /// 3x3 neighborhood around (row, col), skipping any that fall outside
        /// the grid. `buf` must have length >= 9.
        pub fn getNeighborCells(self: @This(), row: usize, col: usize, buf: []usize) []usize {
            const r: i32 = @intCast(row);
            const c: i32 = @intCast(col);
            var len: usize = 0;
            for (0..3) |dr| {
                for (0..3) |dc| {
                    const rr = r + @as(i32, @intCast(dr)) - 1;
                    const cc = c + @as(i32, @intCast(dc)) - 1;
                    const idx = self.getCellIndex(rr, cc) catch continue;
                    buf[len] = idx;
                    len += 1;
                }
            }
            return buf[0..len];
        }

        fn getCellPos(self: @This(), x: f32, y: f32) !CellData {
            const row: i32 = @intFromFloat(@floor(y / self.cell_size));
            const col: i32 = @intFromFloat(@floor(x / self.cell_size));

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
            col_list: *std.ArrayList(CollisionPair),
            query_buf: []u32,
        ) void {
            const circles = &grid.impl.circle_storage;

            //Circle-Circle collision
            for(circles.indices) |id_a|{
                const x_a = circles.xs[id_a];
                const y_a = circles.ys[id_a];
                const r_a = circles.shape_data.radii[id_a];

                const nearby = circles.query(x_a, y_a);
                for(nearby) |id_b| {
                    if(id_a >= id_b) continue;

                    const x_b = circles.xs[id_b];
                    const y_b = circles.ys[id_b];
                    const r_b = circles.shape_data.radii[id_b];
                    
                    if(CollisionDetection(Vec2).circleCollision(x_a, y_a, r_a, x_b, y_b, r_b))
                        col_list.append(self.allocator, .{.a = id_a, .b = id_b }) catch continue;
                }
            }
        
            // for(indices) |id_a| {
            //     const pos_a = positions[@intCast(id_a)];
            //     const shape_a = shape_data[@intCast(id_a)];
            //
            //     const nearby = grid.query(pos_a, query_buf) catch continue;
            //
            //     for(nearby) |id_b| {
            //         if(id_a >= id_b) continue;
            //
            //         const pos_b = positions[@intCast(id_b)];
            //         const shape_b = shape_data[@intCast(id_b)];
            //
            //         if(CollisionDetection(Vec2).checkColliding(pos_a, shape_a, pos_b, shape_b)) {
            //             col_list.append(self.allocator, .{ .a = id_a, .b = id_b }) catch continue;
            //         }
            //     }
            }
    };

    impl: Impl,
    cell_size_multiplier: f32, // Multiplier applied to the largest entity size when computing cell size via setCellSize.  Recommend 1.2-2.0
    results: std.ArrayList(CollisionPair) = .empty, // Where collisions are kept after update is called

    /// Create a new instance of SpacialGrid
    pub fn init(config: Config) !*Self {
        const rows: usize = @intFromFloat(@ceil(config.height / config.cell_size));
        const cols: usize = @intFromFloat(@ceil(config.width / config.cell_size));

        const self = try config.allocator.create(Self);
        self.* = Self {
            .cell_size_multiplier = config.cell_size_multiplier,
            .impl = .{
                .allocator = config.allocator,
                .io = config.io,
                .width = config.width,
                .height = config.height,
                .rows = rows,
                .cols = cols,
                .counts = undefined,
                .indices = undefined,
                .workers = undefined,
                .multi_threaded = config.multi_threaded,
                .thread_count = config.thread_count,
            },
        };

        self.impl.circle_storage = .init(config.allocator, rows, cols);
        self.impl.rect_storage = .init(config.allocator, rows, cols);
        self.impl.point_storage = .init(config.allocator, rows, cols);

        self.impl.query_buf = try config.allocator.alloc(u32, 0);

        // Setting the thread count does not enable multi threading by itself
        if(self.impl.thread_count != null and !self.impl.multi_threaded) {
            std.log.warn("SpacialGrid.multi_threading must be set to true durring init to enable multi_threading!\n", .{});
        }

        // Get number of cpu cores and create that many number of Workers/ threads 
        if(config.multi_threaded) {
            const thread_count = self.impl.thread_count orelse try std.Thread.getCpuCount();
            self.impl.workers = try config.allocator.alloc(Worker(setup), thread_count);

            // Init worker threads.
            for(self.impl.workers) |*w| {
                w.* = try Worker(setup).init(self, @intCast(self.impl.ent_capacity));
                try w.spawn();
            }

            self.impl.work_queue = .init(config.allocator, config.io);
        }
        try self.results.ensureTotalCapacity(self.impl.allocator, @intCast(self.impl.ent_capacity));

        return self;
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.impl.allocator;
        allocator.free(self.impl.query_buf);

        self.impl.point_storage.deinit();
        self.impl.circle_storage.deinit();
        self.impl.rect_storage.deinit();

        // Deinit workers and free memory
        if(self.impl.multi_threaded) {  
            for(self.impl.workers) |*w| w.deinit();
            allocator.free(self.impl.workers);
        }

        self.results.deinit(self.impl.allocator);
        allocator.destroy(self);
    }

    /// Add entities into the spacial grid
    pub fn insert(self: *Self, ids: []const u32, positions: []const Vec2, shape: ShapeType, ) !void {

        // Resize if the new ent count passed in is greater than capacity
        const projected_ent_count: usize = @as(usize, self.impl.ent_count) + ids.len;
        if(projected_ent_count > @as(usize, self.impl.ent_capacity)) try self.ensureCapacity(projected_ent_count * 2);

        const ent_count: usize = @intCast(self.impl.ent_count);
        for(ids, 0..) |id, i| {
            self.impl.ids[ent_count + i] = id;
        }

        for(positions, 0..) |pos, i| {
            self.impl.positions[ent_count + i] = pos;
        }

        for(shape_data, 0..) |shape, i| {
            self.impl.shape_data[ent_count + i] = shape;
        }

        self.impl.ent_count = @intCast(projected_ent_count);
    }

    pub fn insertCircles(self: *Self, ids: []const u32, xs: []const f32, ys: []const f32, radii: []const f32) !void {
        if(self.impl.has_updated) {
            self.reset();
        }

        try self.impl.circle_storage.insert(ids, xs, ys, .{.radii = radii});
    }

    pub fn insertRects(self: *Self, ids: []const u32, xs: []const f32, ys: []const f32, widths: []const f32, heights: []const f32) !void {
        if(self.impl.has_updated) {
            self.reset();
        }

        try self.impl.rect_storage.insert(ids, xs, ys, .{.widths = widths, .heights = heights});
    }

    pub fn insertPoints(self: *Self, ids: []const u32, xs: []const f32, ys: []const f32) !void {
        if(self.impl.has_updated) {
            self.reset();
        }

        try self.impl.point_storage.insert(ids, xs, ys, {});
    }

    pub fn reset(self: *Self) void {
        @memset(self.impl.counts, 0); 
        self.impl.has_updated = false;
        self.impl.ent_count = 0;
    }

    pub fn build(self: *Self) void {
        self.impl.circle_storage.build(self);
        self.impl.rect_storage.build(self);
        self.impl.point_storage.build(self);
    }

    /// Get entities from cell of and neighboring cells of position
    pub fn query(self: *Self, x: f32, y: f32, buf: []u32) ![]u32 {
        try self.impl.circle_storage.query(self, x, y, buf);
    }

    /// Main collision detection loop
    pub fn update(self: *Self) !void {
        const workers = self.impl.workers;
        
        const ent_count: usize = @intCast(self.impl.ent_count);
        const ids = self.impl.ids[0..ent_count];
        const positions = self.impl.positions;
        const shape_data = self.impl.shape_data;

        // Insert entities into the grid 
        self.results.clearRetainingCapacity();
        self.build();

        // If not multi_threaded, just call findCollisions, else run workers
        if(!self.impl.multi_threaded) {
            self.impl.findCollisions(self, ids, positions, shape_data, &self.results, self.impl.query_buf);
            self.impl.has_updated = true;
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

        self.impl.has_updated = true;
    }

    /// Allocate new buffers to accommodate new entity count
    pub fn ensureCapacity(self: *Self, capacity: usize) !void {
        self.impl.allocator.free(self.impl.indices);
        self.impl.allocator.free(self.impl.ids);
        self.impl.allocator.free(self.impl.positions);
        self.impl.allocator.free(self.impl.shape_data);
        self.impl.allocator.free(self.impl.query_buf);
        if(self.impl.multi_threaded) {
            for(self.impl.workers) |*w| w.allocator.free(w.query_buf);
        }

        const new_cap: usize = @max(capacity, @as(usize, self.impl.ent_capacity) * 2);
        self.impl.ent_capacity = @intCast(new_cap);
        self.impl.indices = try self.impl.allocator.alloc(u32, new_cap);
        self.impl.ids = try self.impl.allocator.alloc(u32, new_cap);
        self.impl.positions = try self.impl.allocator.alloc(Vec2, new_cap);
        self.impl.shape_data = try self.impl.allocator.alloc(Shape, new_cap);
        self.impl.query_buf = try self.impl.allocator.alloc(u32, new_cap);
        if(self.impl.multi_threaded) {
            for(self.impl.workers) |*w| w.query_buf = try w.allocator.alloc(u32, new_cap);
        }
    }
    
    /// Set the size of the SpacialGrid's cell size to the size of the largest entity 
    /// multipied by SpacialGrid.cell_size_multiplier.
    /// Must be called before SpacialGrid.update and must be called whenever the maximum size 
    /// for an entity changes.   
    pub fn setCellSize(self: *Self) !void {
        const cell_size: f32 = blk: {
            var largest: f32 = 0.0;
            for(self.impl.shape_data) |shape| {
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
        self.impl.counts = try self.impl.allocator.alloc(u32, self.impl.rows * self.impl.cols);
        @memset(self.impl.counts, 0);
    }
};
}

pub fn getPrng(io: std.Io) std.Random.DefaultPrng {
    var seed: u64 = undefined; 
    io.random(std.mem.asBytes(&seed));
    return .init(seed);
}

