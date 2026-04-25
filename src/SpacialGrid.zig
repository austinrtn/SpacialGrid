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
pub const CollisionPair = packed struct {
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
        cell_size_multiplier: f32 = 2.0, // Multiplier applied to the largest entity size when computing cell size via updateCellSize.  Recommend 1.2-2.0

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

        query_results: []u32 = undefined,
        query_buf: []u32 = undefined, // Used for querying entities in a single threaded context
        col_list: std.ArrayList(CollisionPair) = .empty,
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

        pub fn getCellPos(self: @This(), x: f32, y: f32) !CellData {
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
            work_item: WorkItem,
            query_buf: []u32,
            col_list: *std.ArrayList(CollisionPair),
        ) void {
            switch (work_item.kernel) {
                .cc => self.findCollision(.Circle, .Circle, grid, work_item, col_list, query_buf),
                .rr => self.findCollision(.Rect, .Rect, grid, work_item, col_list, query_buf),
                .pp => self.findCollision(.Point, .Point, grid, work_item, col_list, query_buf),
                .cr => self.findCollision(.Circle, .Rect, grid, work_item, col_list, query_buf),
                .rc => self.findCollision(.Rect, .Circle, grid, work_item, col_list, query_buf),
                .cp => self.findCollision(.Circle, .Point, grid, work_item, col_list, query_buf),
                .pc => self.findCollision(.Point, .Circle, grid, work_item, col_list, query_buf),
                .rp => self.findCollision(.Rect, .Point, grid, work_item, col_list, query_buf),
                .pr => self.findCollision(.Point, .Rect, grid, work_item, col_list, query_buf),
            }
        }

        fn findCollision(self: *@This(), comptime outer_shape: ShapeType, comptime inner_shape: ShapeType, grid: anytype, work_item: WorkItem,
                            col_list: *std.ArrayList(CollisionPair), buf: []u32) void {

            const cd = CollisionDetection(Vec2);
            var outer_storage = switch (outer_shape) {
                    .Circle => self.circle_storage,
                    .Rect => self.rect_storage,
                    .Point => self.point_storage,
            };

            var inner_storage = switch (inner_shape) {
                    .Circle => self.circle_storage,
                    .Rect => self.rect_storage,
                    .Point => self.point_storage,
            };

            for(outer_storage.indices[work_item.start..work_item.end]) |idx_a_u32| {
                const idx_a: usize = @intCast(idx_a_u32);
                const x_a = outer_storage.xs[idx_a];
                const y_a = outer_storage.ys[idx_a];
                const id_a = outer_storage.ids[idx_a];

                const nearby = inner_storage.query(grid, x_a, y_a, buf) catch continue;
                for(nearby) |idx_b_u32| {
                    const idx_b: usize = @intCast(idx_b_u32);
                    if (outer_shape == inner_shape and idx_a >= idx_b) continue;

                    const x_b = inner_storage.xs[idx_b];
                    const y_b = inner_storage.ys[idx_b];
                    const id_b = inner_storage.ids[idx_b];
                    
                    const pair: CollisionPair = .{.a = id_a, .b = id_b};
                    var colliding: bool = false;
                    switch (outer_shape) {
                        .Circle => {
                            const r_a = outer_storage.shape_data.radii[idx_a];
                            switch (inner_shape) {
                                .Circle => {
                                    const r_b = inner_storage.shape_data.radii[idx_b];
                                    colliding = cd.circleCollision(x_a, y_a, r_a, x_b, y_b, r_b);
                                },
                                .Rect => {
                                    const w_b = inner_storage.shape_data.widths[idx_b];
                                    const h_b = inner_storage.shape_data.heights[idx_b];
                                    colliding = cd.rectCircleCollision(x_b, y_b, w_b, h_b, x_a, y_a, r_a);
                                },
                                .Point => colliding = cd.pointCircleCollision(x_a, y_a, r_a, x_b, y_b),
                            }
                        }, 
                        .Rect => {
                            const w_a = outer_storage.shape_data.widths[idx_a];
                            const h_a = outer_storage.shape_data.heights[idx_a];
                            switch (inner_shape) {
                                .Circle => {
                                    const r_b = inner_storage.shape_data.radii[idx_b];
                                    colliding = cd.rectCircleCollision(x_a, y_a, w_a, h_a, x_b, y_b, r_b);
                                },
                                .Rect => {
                                    const w_b = inner_storage.shape_data.widths[idx_b];
                                    const h_b = inner_storage.shape_data.heights[idx_b];
                                    colliding = cd.rectCollision(x_a, y_a, w_a, h_a, x_b, y_b, w_b, h_b);
                                },
                                .Point => colliding = cd.pointRectCollision(x_a, y_a, w_a, h_a, x_b, y_b),
                            }
                        },
                        .Point => {
                            switch (inner_shape) {
                                .Circle => {
                                    const r_b = inner_storage.shape_data.radii[idx_b];
                                    colliding = cd.pointCircleCollision(x_b, y_b, r_b, x_a, y_a);
                                },
                                .Rect => {
                                    const w_b = inner_storage.shape_data.widths[idx_b];
                                    const h_b = inner_storage.shape_data.heights[idx_b];
                                    colliding = cd.pointRectCollision(x_b, y_b, w_b, h_b, x_a, y_a);
                                },
                                .Point => colliding = cd.pointCollision(x_a, y_a, x_b, y_b),
                            }
                        }
                    }

                    if(colliding) col_list.append(self.allocator, pair) catch continue;
                }
            }
        }
    };

    impl: Impl,
    cell_size_multiplier: f32, // Multiplier applied to the largest entity size when computing cell size via updateCellSize.  Recommend 1.2-2.0
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
                .rows = 0,
                .cols = 0,
                .workers = undefined,
                .multi_threaded = config.multi_threaded,
                .thread_count = config.thread_count,
            },
        };

        self.impl.circle_storage = try .init(config.allocator);
        self.impl.rect_storage = try .init(config.allocator);
        self.impl.point_storage = try .init(config.allocator);

        self.impl.query_results = try config.allocator.alloc(u32, 0);
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

        }

        self.impl.work_queue = .init(config.allocator, config.io);
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

        self.impl.work_queue.deinit();
        allocator.free(self.impl.query_results);
        self.impl.col_list.deinit(allocator);
        self.results.deinit(self.impl.allocator);
        allocator.destroy(self);
    }

    pub fn insert(self: *Self) Insert {
        return .{ .grid = self };
    }

    pub fn reset(self: *Self) void {
        self.impl.circle_storage.reset();
        self.impl.rect_storage.reset();
        self.impl.point_storage.reset();
        self.impl.has_updated = false;
        self.impl.ent_count = 0;
    }

    pub fn build(self: *Self) !void {
        self.impl.circle_storage.build(self);
        self.impl.rect_storage.build(self);
        self.impl.point_storage.build(self);

        try self.generateWorkQueue();
    }

    fn generateWorkQueue(self: *Self) !void {
        self.impl.work_queue.reset();
        const circle_count = self.impl.circle_storage.ent_count;
        const rect_count = self.impl.rect_storage.ent_count;
        const point_count = self.impl.point_storage.ent_count;

        try self.generateKernelItems(.cc, circle_count);
        try self.generateKernelItems(.rr, rect_count);
        try self.generateKernelItems(.pp, point_count);

        try self.generateKernelItems(
            if (circle_count <= rect_count) .cr else .rc, 
            @min(circle_count, rect_count)
        );

        try self.generateKernelItems(
            if (circle_count <= point_count) .cp else .pc, 
            @min(circle_count, point_count)
        );

        try self.generateKernelItems(
            if (rect_count <= point_count) .rp else .pr, 
            @min(rect_count, point_count)
        );
    }

    fn generateKernelItems(self: *Self, kernel: WorkItem.Kernel, count: usize) !void {
        const slice_unit: usize = 250;
        const queue = &self.impl.work_queue; 
        
        var i: usize = 0;
        while(i < count) : (i += slice_unit) {
            const end = @min(i + slice_unit, count);
            try queue.appendWork(.init(kernel, i, end));
        }
    }

    /// Get entities from cell of and neighboring cells of position.
    /// Range of ents discovered is determined by cell size
    pub fn queryEntsInArea(self: *Self, x: f32, y: f32) ![]u32 {
        var queried_indices = try QueryIndices.init(self.*, x, y);
        defer queried_indices.deinit();

        const qr = &self.impl.query_results;
        qr.* = try self.impl.allocator.realloc(qr.*, queried_indices.total_count);
        const buf = qr.*;

        var pos: usize = 0;
        for (queried_indices.c_indices) |idx| {
            buf[pos] = self.impl.circle_storage.ids[@intCast(idx)];
            pos += 1;
        }
        for (queried_indices.r_indices) |idx| {
            buf[pos] = self.impl.rect_storage.ids[@intCast(idx)];
            pos += 1;
        }
        for (queried_indices.p_indices) |idx| {
            buf[pos] = self.impl.point_storage.ids[@intCast(idx)];
            pos += 1;
        }

        return buf;
    }

    // Find collisions from one point.  the 'a' field in the collision pair is 
    // the id of the queried entity
    pub fn query(self: *Self, x: f32, y: f32, id: u32, shape_data: Shape) !*std.ArrayList(CollisionPair) {
        const cd = CollisionDetection(Vec2);
        self.impl.col_list.clearRetainingCapacity();

        var queried_indices = try QueryIndices.init(self.*, x, y); 
        defer queried_indices.deinit();

        for(queried_indices.c_indices) |idx_u32| {
            const i: usize = @intCast(idx_u32);
            const x2 = self.impl.circle_storage.xs[i];
            const y2 = self.impl.circle_storage.ys[i];
            const r = self.impl.circle_storage.shape_data.radii[i];
            const id_b = self.impl.circle_storage.ids[i];

            if(cd.checkColliding(x, y, shape_data, x2, y2, .{ .Circle = r })) {
                try self.impl.col_list.append(self.impl.allocator, .{.a = id, .b = id_b});
            }
        }

        for(queried_indices.r_indices) |idx_u32| {
            const i: usize = @intCast(idx_u32);
            const x2 = self.impl.rect_storage.xs[i];
            const y2 = self.impl.rect_storage.ys[i];
            const w = self.impl.rect_storage.shape_data.widths[i];
            const h = self.impl.rect_storage.shape_data.widths[i];
            const id_b = self.impl.rect_storage.ids[i];

            if(cd.checkColliding(x, y, shape_data, x2, y2, .{ .Rect = .{.x = w, .y = h} })) {
                try self.impl.col_list.append(self.impl.allocator, .{.a = id, .b = id_b});
            }
        }

        for(queried_indices.p_indices) |idx_u32| {
            const i: usize = @intCast(idx_u32);
            const x2 = self.impl.point_storage.xs[i];
            const y2 = self.impl.point_storage.ys[i];
            const id_b = self.impl.point_storage.ids[i];

            if(cd.checkColliding(x, y, shape_data, x2, y2, .Point)) {
                try self.impl.col_list.append(self.impl.allocator, .{.a = id, .b = id_b});
            }
        }
    }

    /// Main collision detection loop
    pub fn update(self: *Self) !*std.ArrayList(CollisionPair) {
        const workers = self.impl.workers;

        // Insert entities into the grid 
        self.results.clearRetainingCapacity();
        try self.build();

        // If not multi_threaded, just call findCollisions, else run workers
        if(!self.impl.multi_threaded) {
            while(try self.impl.work_queue.getNextWorkItem(false)) |item| {
                self.impl.findCollisions(self, item, self.impl.query_buf, &self.results);
            }
            self.impl.has_updated = true;
            return &self.results;
        }

        // Have workers look for and save collisions
        for(workers) |*w| {
            w.col_list.clearRetainingCapacity();
            w.work_semaphore.post(self.impl.io);
        }

        // Once workers are finished, add their collisions to the grid's results
        for(workers) |*w| {
            w.done_semaphore.wait(self.impl.io) catch continue; 
            try self.results.appendSlice(self.impl.allocator, w.col_list.items);
        }

        self.impl.has_updated = true;
        return &self.results;
    }

    /// Reallocate buffers to accommodate new entity count.  Leave null to reallocate space for all 
    /// shapes
    pub fn ensureCapacity(self: *Self, capacity: usize, shape: ?ShapeType) !void {
        if(shape) |s| switch(s) {
            .Circle => try self.impl.circle_storage.ensureCapacity(capacity),
            .Rect => try self.impl.rect_storage.ensureCapacity(capacity),
            .Point => try self.impl.point_storage.ensureCapacity(capacity),
        } else {
            try self.impl.circle_storage.ensureCapacity(capacity);
            try self.impl.rect_storage.ensureCapacity(capacity);
            try self.impl.point_storage.ensureCapacity(capacity);
        }

        const new_cap: usize = @max(
            self.impl.circle_storage.capacity,
            self.impl.rect_storage.capacity,
            self.impl.point_storage.capacity,
        );

        self.impl.allocator.free(self.impl.query_buf);
        if(self.impl.multi_threaded) {
            for(self.impl.workers) |*w| w.allocator.free(w.query_buf);
        }

        self.impl.ent_capacity = @intCast(new_cap);
        self.impl.query_buf = try self.impl.allocator.alloc(u32, new_cap);

        if(self.impl.multi_threaded) {
            for(self.impl.workers) |*w| w.query_buf = try w.allocator.alloc(u32, new_cap);
        }
    }
    
    /// Set the size of the SpacialGrid's cell size to the size of the largest entity 
    /// multipied by SpacialGrid.cell_size_multiplier.
    /// Must be called before SpacialGrid.update and must be called whenever the maximum size 
    /// for an entity changes.   
    pub fn updateCellSize(self: *Self, cell_size_mult: ?f32) !void {
        if(cell_size_mult) |int| { 
            if(int < 1) @panic("cell_size_mult must be greater than or equal to 1\n");
            self.cell_size_multiplier = int; 
        }

        var cell_size: f32 = @max(
            self.impl.circle_storage.getLargestSize(),
            self.impl.rect_storage.getLargestSize(),
        ) * self.cell_size_multiplier;
        if(cell_size == 0) cell_size = self.cell_size_multiplier; 
        
        self.impl.cell_size = cell_size;
        const rows: usize = @intFromFloat(@ceil(self.impl.height / self.impl.cell_size));
        const cols: usize = @intFromFloat(@ceil(self.impl.width / self.impl.cell_size));

        self.impl.rows = rows;        
        self.impl.cols = cols;
        try self.impl.circle_storage.setCounts(rows, cols);
        try self.impl.rect_storage.setCounts(rows, cols);
        try self.impl.point_storage.setCounts(rows, cols);
    }

    const QueryIndices = struct {
        allocator: std.mem.Allocator,
        c_buf: []u32,
        c_indices: []u32, 

        r_buf: []u32,
        r_indices: []u32, 

        p_buf: []u32,
        p_indices: []u32, 
        total_count: usize = 0,

        fn init(grid: Self, x: f32, y: f32) !QueryIndices {
            const allocator = grid.impl.allocator;
            var self: QueryIndices = undefined; 
            self.allocator = allocator;

            self.c_buf = try allocator.alloc(u32, grid.impl.circle_storage.ent_count);
            self.r_buf = try allocator.alloc(u32, grid.impl.rect_storage.ent_count);
            self.p_buf = try allocator.alloc(u32, grid.impl.point_storage.ent_count);

            self.c_indices = try grid.impl.circle_storage.query(grid, x, y, self.c_buf);
            self.r_indices = try grid.impl.rect_storage.query(grid, x, y, self.r_buf);
            self.p_indices = try grid.impl.point_storage.query(grid, x, y, self.p_buf);

            self.total_count = self.c_indices.len + self.r_indices.len + self.p_indices.len;
        }

        fn deinit(self: *QueryIndices) void {
            self.allocator.free(self.c_buf);
            self.allocator.free(self.r_buf);
            self.allocator.free(self.p_buf);
        }
    };

    const Insert = struct {
        grid: *Self,

        pub fn circles(self: @This(), ids: []const u32, xs: []const f32, ys: []const f32, radii: []const f32) !void {
            const grid = self.grid;
            if(grid.impl.has_updated) {
                grid.reset();
            }
            
            if(ids.len > grid.impl.ent_capacity) try grid.ensureCapacity(ids.len * 2, .Circle);

            try grid.impl.circle_storage.insert(ids, xs, ys, .{.radii = radii});
        }

        pub fn rects(self: @This(), ids: []const u32, xs: []const f32, ys: []const f32, widths: []const f32, heights: []const f32) !void {
            const grid = self.grid;
            if(grid.impl.has_updated) {
                grid.reset();
            }

            if(ids.len > grid.impl.ent_capacity) try grid.ensureCapacity(ids.len * 2, .Rect);

            try grid.impl.rect_storage.insert(ids, xs, ys, .{.widths = widths, .heights = heights});
        }

        pub fn points(self: @This(), ids: []const u32, xs: []const f32, ys: []const f32) !void {
            const grid = self.grid;
            if(grid.impl.has_updated) {
                grid.reset();
            }

            if(ids.len > grid.impl.ent_capacity) try grid.ensureCapacity(ids.len * 2, .Point);

            try grid.impl.point_storage.insert(ids, xs, ys, {});
        }
    };


};
}
