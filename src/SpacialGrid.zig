const std = @import("std");
const CollisionDetection = @import("CollisionDetection.zig").CollisionDetection;
const Worker = @import("Woker.zig").Worker;
const WorkQueue = @import("WorkQueue.zig").WorkQueue;

pub const ShapeType = enum { Point, Rect, Circle };

pub const CollisionData = struct {
    count: usize,
    x_pos: []f32,
    y_pos: []f32,
    shapes: []ShapeType,
    widths: []f32,
    heights: []f32,
    radii: []f32,
};

pub const CollisionPair = struct {
    a: usize,
    b: usize,
};

pub const SpacialGridSetup = struct { thread_count: usize = 1 };

pub fn SpacialGrid(comptime setup: SpacialGridSetup) type {
    const thread_count = if (setup.thread_count == 0) 1 else setup.thread_count;

    return struct {
        const Self = @This();

        pub const Config = struct {
            width: f32,
            height: f32,
            cell_size: f32,
            allocator: std.mem.Allocator,
            io: std.Io,
            ent_count: usize = 0,
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
            indices: []usize,
            buf_capacity: usize,
            auto_cell_resize: bool = true,
            workers: [thread_count]Worker(setup) = undefined,
            work_queue: WorkQueue = undefined,
        };

        impl: Impl,
        results: std.ArrayList(CollisionPair) = .empty,

        pub fn init(config: Config) !*Self {
            const self = try config.allocator.create(Self);
            self.* = Self{
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
                    .auto_cell_resize = config.auto_cell_resize,
                },
            };

            self.impl.indices = try self.impl.allocator.alloc(usize, self.impl.buf_capacity);
            self.impl.counts = try self.impl.allocator.alloc(usize, self.impl.rows * self.impl.cols);
            @memset(self.impl.counts, 0);

            for (&self.impl.workers) |*w| {
                w.* = try Worker(setup).init(self, self.impl.buf_capacity);
                try w.spawn();
            }

            self.impl.work_queue = .init(config.allocator, config.io);
            try self.results.ensureTotalCapacity(self.impl.allocator, self.impl.ent_count);

            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.impl.allocator;
            allocator.free(self.impl.counts);
            allocator.free(self.impl.indices);

            for (&self.impl.workers) |*w| w.deinit();

            self.results.deinit(self.impl.allocator);
            allocator.destroy(self);
        }

        fn insert(self: *Self, count: usize, x_pos: []f32, y_pos: []f32) void {
            @memset(self.impl.counts, 0);
            for (0..count) |id| {
                const cell = self.getCellPos(x_pos[id], y_pos[id]) catch continue;
                self.impl.counts[cell.idx] += 1;
            }

            var total: usize = 0;
            for (self.impl.counts) |*c| {
                const placeholder = c.*;
                c.* = total;
                total += placeholder;
            }

            for (0..count) |id| {
                const cell = self.getCellPos(x_pos[id], y_pos[id]) catch continue;
                const count_index: *usize = &self.impl.counts[cell.idx];
                self.impl.indices[count_index.*] = id;
                count_index.* += 1;
            }
        }

        fn query(self: *Self, x: f32, y: f32, buf: []usize) ![]usize {
            const cell_pos = try self.getCellPos(x, y);

            var len: usize = 0;
            for (0..3) |dr| {
                for (0..3) |dc| {
                    const row_offset: i32 = @as(i32, @intCast(dr)) - 1;
                    const col_offset: i32 = @as(i32, @intCast(dc)) - 1;
                    const cell_index = self.getCellIndex(
                        cell_pos.row, row_offset, cell_pos.col, col_offset,
                    ) catch continue;

                    const slice = self.getEntsFromCell(cell_index);
                    @memcpy(buf[len .. len + slice.len], slice);
                    len += slice.len;
                }
            }

            return buf[0..len];
        }

        pub fn getEntsFromCell(self: *Self, cell_index: usize) []usize {
            const cell_start = if (cell_index > 0) self.impl.counts[cell_index - 1] else 0;
            const cell_end = self.impl.counts[cell_index];
            return self.impl.indices[cell_start..cell_end];
        }

        fn getCellPos(self: Self, x: f32, y: f32) !struct { row: usize, col: usize, idx: usize } {
            const row: i32 = @intFromFloat(@floor(y / self.impl.cell_size));
            const col: i32 = @intFromFloat(@floor(x / self.impl.cell_size));

            if (row < 0 or row >= self.impl.rows or col < 0 or col >= self.impl.cols)
                return error.OutOfBounds;

            const row_casted: usize = @intCast(row);
            const col_casted: usize = @intCast(col);

            return .{
                .row = row_casted,
                .col = col_casted,
                .idx = row_casted * self.impl.cols + col_casted,
            };
        }

        pub fn getCellIndex(self: Self, row: usize, row_offset: i32, col: usize, col_offset: i32) !usize {
            const row_val: i32 = @as(i32, @intCast(row)) + row_offset;
            const col_val: i32 = @as(i32, @intCast(col)) + col_offset;

            if (row_val < 0 or row_val >= @as(i32, @intCast(self.impl.rows)) or
                col_val < 0 or col_val >= @as(i32, @intCast(self.impl.cols)))
                return error.OutOfBounds;

            return @as(usize, @intCast(row_val)) * self.impl.cols + @as(usize, @intCast(col_val));
        }

        pub fn update(self: *Self, data: CollisionData, profiler: anytype) !void {
            const workers = &self.impl.workers;

            if (!self.impl.auto_cell_resize and !self.impl.cell_size_set) {
                std.log.err("Must call SpacialGrid.setCellSize before calling SpacialGrid.update", .{});
                return error.CellSizeNotSet;
            }

            if (data.count > self.impl.buf_capacity or (self.impl.auto_cell_resize and !self.impl.cell_size_set)) {
                try self.resizeBuffers(data.count);
                if (self.impl.auto_cell_resize)
                    try self.setCellSize(data.shapes, data.radii, data.widths, data.heights, 2);
            }

            self.results.clearRetainingCapacity();

            const insert_start = std.Io.Clock.Timestamp.now(self.impl.io, .awake);
            self.insert(data.count, data.x_pos, data.y_pos);
            const insert_end = insert_start.durationTo(std.Io.Clock.Timestamp.now(self.impl.io, .awake));
            if (@hasField(@TypeOf(profiler.*), "insert"))
                profiler.insert.append(self.impl.allocator, insert_end.raw.toNanoseconds()) catch @panic("Profiler\n");

            if (@hasField(@TypeOf(profiler.*), "cell_max")) {
                var max: usize = 0;
                for (0..self.impl.counts.len) |ci| {
                    const start = if (ci > 0) self.impl.counts[ci - 1] else 0;
                    const count = self.impl.counts[ci] - start;
                    if (count > max) max = count;
                }
                profiler.cell_max.append(self.impl.allocator, max) catch @panic("Profiler\n");
            }

            self.impl.work_queue.reset();

            if (thread_count == 1 or data.count < thread_count) {
                const col_list = &workers[0].col_list;
                const query_buf = workers[0].query_buf;

                col_list.clearRetainingCapacity();
                while (self.impl.work_queue.getNextCellChunk(self) catch @panic("WorkQueue error\n")) |chunk| {
                    if (chunk.len == 0) continue;
                    findCollisions(self, chunk, data, col_list, query_buf, profiler);
                }
                try self.results.appendSlice(self.impl.allocator, col_list.items);
                return;
            }

            for (workers) |*w| {
                w.col_list.clearRetainingCapacity();
                w.set(data);
                w.work_semaphore.post(self.impl.io);
            }

            for (workers) |*w| {
                w.done_semaphore.wait(self.impl.io) catch @panic("done_semaphore wait failed");
                try self.results.appendSlice(self.impl.allocator, w.col_list.items);
            }
        }

        pub fn findCollisions(
            grid: *Self,
            indices: []usize,
            data: CollisionData,
            col_list: *std.ArrayList(CollisionPair),
            query_buf: []usize,
            profiler: anytype,
        ) void {
            for (indices) |id_a| {
                const ax = data.x_pos[id_a];
                const ay = data.y_pos[id_a];

                const query_start = std.Io.Clock.Timestamp.now(grid.impl.io, .awake);
                const nearby = grid.query(ax, ay, query_buf) catch continue;
                const query_end = query_start.durationTo(std.Io.Clock.Timestamp.now(grid.impl.io, .awake));
                if (@hasField(@TypeOf(profiler.*), "query"))
                    profiler.query.append(grid.impl.allocator, query_end.raw.toNanoseconds()) catch @panic("Profiler\n");

                for (nearby) |id_b| {
                    if (id_a >= id_b) continue;

                    const col_time_start = std.Io.Clock.Timestamp.now(grid.impl.io, .awake);
                    const colliding = CollisionDetection.checkColliding(
                        ax,               ay,               data.shapes[id_a], data.radii[id_a], data.widths[id_a], data.heights[id_a],
                        data.x_pos[id_b], data.y_pos[id_b], data.shapes[id_b], data.radii[id_b], data.widths[id_b], data.heights[id_b],
                    );
                    const col_end = col_time_start.durationTo(std.Io.Clock.Timestamp.now(grid.impl.io, .awake));
                    if (@hasField(@TypeOf(profiler.*), "collision"))
                        profiler.collision.append(grid.impl.allocator, col_end.raw.toNanoseconds()) catch @panic("Profiler\n");

                    if (colliding) {
                        if (@hasField(@TypeOf(profiler.*), "hits")) profiler.hits += 1;
                        col_list.append(grid.impl.allocator, .{ .a = id_a, .b = id_b }) catch continue;
                    }
                }
            }
        }

        fn resizeBuffers(self: *Self, new_len: usize) !void {
            self.impl.allocator.free(self.impl.indices);
            for (&self.impl.workers) |*w| w.allocator.free(w.query_buf);

            const new_cap = @max(new_len, self.impl.buf_capacity * 2);
            self.impl.buf_capacity = new_cap;
            self.impl.indices = try self.impl.allocator.alloc(usize, new_cap);
            for (&self.impl.workers) |*w| w.query_buf = try w.allocator.alloc(usize, new_cap);
        }

        pub fn setCellSize(self: *Self, shapes: []ShapeType, radii: []f32, widths: []f32, heights: []f32, n: f32) !void {
            if (n < 1) @panic("n is less than 1\n");

            const cell_size: f32 = blk: {
                var largest: f32 = 0.0;
                for (shapes, radii, widths, heights) |shape, r, w, h| {
                    const size: f32 = switch (shape) {
                        .Circle => r * 2.0 * n,
                        .Rect   => @max(w, h) * n,
                        .Point  => 0,
                    };
                    if (size > largest) largest = size;
                }
                if (largest == 0) largest = 1;
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
