const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;
const Arraylist = std.ArrayList;
const Timestamp = std.Io.Clock.Timestamp;

// Future useful profiler categories:
// - Cell density: avg shapes per cell, max shapes in one cell, empty cell percent.
// - Candidate pressure: total narrowphase checks, checks per shape, checks per collision.
// - Collision results: total collisions found, hit rate from candidates.
// - Query pressure: avg queried cells and avg candidate shapes per query.
// - Worker balance: per-thread time, work items processed, candidates checked, collisions found.
// - Memory behavior: result list capacity, query buffer capacity, realloc counts.

pub const Profiler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    results: std.Io.Writer.Allocating = undefined,

    start_time: Timestamp = undefined,
    end_time: f32 = 0,
    frames: usize = 0,
    fps_tracker: Arraylist(f64) = .empty,

    shape_count_start: ShapeCounts = undefined,
    shape_count_end: ShapeCounts = undefined,

    running: bool = false,
    finished: bool = false,
    logged_max_frame_msg: bool = false,

    cell_density: CellDensity = undefined,
    timed_items: struct {
        build: ProfileItem,
        insert_circles: ProfileItem,
        insert_rects: ProfileItem,
        insert_points: ProfileItem,
        find_collision: ProfileItem,
        update: ProfileItem,
    } = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Profiler {
        const self = try allocator.create(Profiler);
        self.* = .{ .allocator = allocator, .io = io };
        self.results = .init(allocator);
        self.cell_density = .{ .allocator = allocator, .profiler = self };

        self.timed_items.build = .init(allocator, io, self, "Build", true);
        self.timed_items.insert_circles = .init(allocator, io, self, "Insert Circles", true);
        self.timed_items.insert_rects = .init(allocator, io, self, "Insert Rects", true);
        self.timed_items.insert_points = .init(allocator, io, self, "Insert Points", true);
        self.timed_items.find_collision = .init(allocator, io, self, "Finding Collisions", true);
        self.timed_items.update = .init(allocator, io, self, "Update", false);
        return self;
    }

    pub fn deinit(self: *Profiler) void {
        self.running = false;
        self.cell_density.deinit();
        self.fps_tracker.deinit(self.allocator);

        inline for (std.meta.fields(@TypeOf(self.timed_items))) |field| {
            const item = &@field(self.timed_items, field.name);
            item.deinit();
        }
        self.results.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *Profiler) void {
        if (!self.running) return;
        self.frames += 1;

        const elapsed_seconds: f64 = @as(f64, self.end_time) / 1000.0;
        const fps: f64 = if (elapsed_seconds == 0) 0 else
            @as(f64, @floatFromInt(self.frames)) / elapsed_seconds;

        self.fps_tracker.append(self.allocator, fps) catch {};
    }

    pub fn start(self: *Profiler, max_frames: ?usize, shape_count_start: ShapeCounts) void {
        if (max_frames) |f| ProfileItem.max_samples = f;
        self.running = true;
        self.start_time = Timestamp.now(self.io, .awake);
        self.shape_count_start = shape_count_start;
    }

    pub fn stop(self: *Profiler, shape_count_end: ShapeCounts) void {
        const elapsed_dur = self.start_time.durationTo(
            Timestamp.now(self.io, .awake),
        );

        self.shape_count_end = shape_count_end;
        self.end_time = @floatFromInt(elapsed_dur.raw.toMilliseconds());
        self.running = false;
        self.finished = true;
    }

    pub fn buildResults(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;
        const header: []const u8 = "Spacial Grid Profiling";
        try out.print("{s}\n", .{header});
        for (0..header.len) |_| try out.writeAll("_");
        try out.writeAll("\n");

        try self.writeGridData(grid);

        if (!isShapeCountEql(self.shape_count_start, self.shape_count_end)) {
            try out.writeAll("Starting Shapes:\n");
            try self.writeShapeCounts(self.shape_count_start);
            try out.writeAll("\nEnding Shapes:\n");
            try self.writeShapeCounts(self.shape_count_end);
        } else {
            try out.writeAll("\nShape Count:\n");
            try self.writeShapeCounts(self.shape_count_end);
        }
        try out.writeAll("\n");

        try self.writeCellData(grid);
        try out.writeAll("\n");
        try self.writeTimedItems();
    }

    fn writeGridData(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;
        const elapsed_seconds: f32 = (self.end_time) / 1000.0;

        try out.print("Time Profiled: {d:.2}s\n", .{elapsed_seconds});
        try out.print("Threads: {}\n", .{grid.impl.thread_count});
    }

    fn writeCellData(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;

        try out.writeAll("\nCell Data:\n");
        try out.print("  Rows: {}\n  Cols: {}\n", .{ grid.impl.rows, grid.impl.cols });
        try out.print("  Cell Size: {}\n  Cell Count: {}\n", .{ grid.impl.cell_size, grid.impl.rows * grid.impl.cols });

        self.cell_density.setCellDensity();

        try out.writeAll("\n  Combined:\n");
        try self.writeDensityData(self.cell_density.all_data);
        try out.writeAll("  Circle:\n");
        try self.writeDensityData(self.cell_density.circle_data);
        try out.writeAll("  Rect:\n");
        try self.writeDensityData(self.cell_density.rect_data);
        try out.writeAll("  Point:\n");
        try self.writeDensityData(self.cell_density.point_data);
    }

    fn writeDensityData(self: *Profiler, data: CellDensity.DensityData) !void {
        const out = &self.results.writer;
        try out.print(
            "    Avg Shapes/Cell: {d:.2}\n    Avg Empty Cells: {d:.2}\n    Avg Max In Cell: {d:.2}\n",
            .{ data.total, data.empty, data.max },
        );
    }

    fn writeCellItems(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;

        var total: usize = 0;
        var max_count_in_cell: usize = 0;
        var empty_cells: usize = 0;

        const circle_storage = grid.impl.circle_storage;
        for (0..circle_storage.counts.len) |i| {
            const cell_count: usize = if (i == 0) @intCast(circle_storage.counts[0]) else @intCast(circle_storage.counts[i] - circle_storage.counts[i - 1]);

            total += cell_count;
            if (cell_count == 0) empty_cells += 1;
            if (cell_count > max_count_in_cell) max_count_in_cell = cell_count;
        }

        try out.print("  Max Shapes in Cell: {}\n  Empty Cells: {}\n", .{ max_count_in_cell, empty_cells });
    }

    fn writeShapeCounts(self: *Profiler, shape_count: ShapeCounts) !void {
        inline for (std.meta.fields(ShapeType)) |field| {
            const count = @field(shape_count, field.name);
            if (count > 0) {
                try self.results.writer.print("  {s}: {}\n", .{ field.name, count });
            }
        }
        try self.results.writer.print("  Total: {}\n", .{getTotalCount(shape_count)});
    }

    fn writeTimedItems(self: *Profiler) !void {
        const out = &self.results.writer;
        const ItemFields = std.meta.fields(@TypeOf(self.timed_items));
        var relevant_sum: f64 = 0;

        // Percent is based on average time so unequal sample counts do not skew the breakdown.
        inline for (ItemFields) |field| {
            const item = &@field(self.timed_items, field.name);
            if (item.include_percent and item.hasResults()) {
                const avg = item.getAvg();
                item.percent_time = avg.nanos;
                relevant_sum += avg.nanos;
            }
        }

        inline for (ItemFields) |field| {
            const item = &@field(self.timed_items, field.name);
            if (item.include_percent and item.hasResults() and relevant_sum > 0) {
                item.percent = (item.percent_time / relevant_sum) * 100;
            }
        }

        inline for (ItemFields) |field| {
            const item = @field(self.timed_items, field.name);
            try out.print("{s}:\n", .{item.text});

            if (!item.hasResults()) {
                try out.writeAll("  N.A\n");
            } else {
                const avg = item.getAvg();
                try out.print("  Avg: {d:.4}ms", .{avg.millis});
                if (item.include_percent)
                    try out.print(" | {d:.2}%", .{item.percent});
            }

            try out.writeAll("\n");
        }
    }
};

const ProfileItem = struct {
    var max_samples: usize = 10_000;

    allocator: std.mem.Allocator,
    io: std.Io,

    profiler: *Profiler,
    text: []const u8,
    include_percent: bool,
    start_time: Timestamp = undefined,
    times: Arraylist(i96) = .empty,
    percent: f64 = 0,
    percent_time: f64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, profiler: *Profiler, text: []const u8, include_percent: bool) ProfileItem {
        return .{
            .allocator = allocator,
            .io = io,
            .profiler = profiler,
            .text = text,
            .include_percent = include_percent,
        };
    }

    fn deinit(self: *ProfileItem) void {
        self.times.deinit(self.allocator);
    }

    pub fn start(self: *ProfileItem) void {
        if (!self.profiler.running) return;
        self.start_time = Timestamp.now(self.io, .awake);
    }

    pub fn stop(self: *ProfileItem) !void {
        if (!self.profiler.running) return;
        if (self.times.items.len >= max_samples) {
            if (!self.profiler.logged_max_frame_msg) {
                std.log.info("Max frames for profiler reached.  No longer running profiler", .{});
                self.profiler.logged_max_frame_msg = true;
            }
            return;
        }
        const end_time = self.start_time.durationTo(
            Timestamp.now(self.io, .awake),
        );
        const ns = end_time.raw.toNanoseconds();

        if (self.times.items.len < max_samples)
            try self.times.append(self.allocator, ns);
    }

    fn hasResults(self: ProfileItem) bool {
        return (self.times.items.len > 0);
    }

    pub fn getAvg(self: ProfileItem) struct { nanos: f64, millis: f64 } {
        var avg: f64 = 0;
        for (self.times.items) |time| avg += @floatFromInt(time);

        avg = avg / @as(f64, @floatFromInt(self.times.items.len));
        const avg_ms = avg / 1_000_000.0;

        return .{ .nanos = avg, .millis = avg_ms };
    }
};

const CellDensity = struct {
    const DensityData = struct { total: f64 = 0, empty: f64 = 0, max: f64 = 0 };
    allocator: std.mem.Allocator,
    profiler: *Profiler,

    circle_counts: std.ArrayList([]u32) = .empty,
    rect_counts: std.ArrayList([]u32) = .empty,
    point_counts: std.ArrayList([]u32) = .empty,

    all_data: DensityData = .{},
    circle_data: DensityData = .{},
    rect_data: DensityData = .{},
    point_data: DensityData = .{},

    pub fn append(self: *CellDensity, shape: ShapeType, count: []u32) !void {
        const snapshot = try self.allocator.dupe(u32, count);
        switch (shape) {
            .Circle => try self.circle_counts.append(self.allocator, snapshot),
            .Rect => try self.rect_counts.append(self.allocator, snapshot),
            .Point => try self.point_counts.append(self.allocator, snapshot),
        }
    }

    fn deinit(self: *CellDensity) void {
        for (self.circle_counts.items) |count| self.allocator.free(count);
        for (self.rect_counts.items) |count| self.allocator.free(count);
        for (self.point_counts.items) |count| self.allocator.free(count);
        self.circle_counts.deinit(self.allocator);
        self.rect_counts.deinit(self.allocator);
        self.point_counts.deinit(self.allocator);
    }

    fn setCellDensity(self: *CellDensity) void {
        for (std.meta.tags(ShapeType)) |shape| {
            switch (shape) {
                .Circle => setShapeStorageDensity(self.circle_counts.items, &self.circle_data),
                .Rect => setShapeStorageDensity(self.rect_counts.items, &self.rect_data),
                .Point => setShapeStorageDensity(self.point_counts.items, &self.point_data),
            }
        }
        self.setAllDensity();
    }

    fn setShapeStorageDensity(counts: [][]u32, data: *DensityData) void {
        if (counts.len == 0) {
            data.* = .{};
            return;
        }

        var avg_shapes_per_cell: f64 = 0;
        var max_avg: f64 = 0;
        var empty_avg: f64 = 0;

        for (counts) |count| {
            var total: usize = 0;
            var empty: usize = 0;
            var max: usize = 0;

            for (count) |c32| {
                const c: usize = @intCast(c32);
                total += c;
                if (c == 0) empty += 1;
                max = @max(max, c);
            }

            const cell_count = @as(f64, @floatFromInt(count.len));
            avg_shapes_per_cell += @as(f64, @floatFromInt(total)) / cell_count;
            empty_avg += @as(f64, @floatFromInt(empty));
            max_avg += @as(f64, @floatFromInt(max));
        }

        const sample_count = @as(f64, @floatFromInt(counts.len));
        avg_shapes_per_cell = avg_shapes_per_cell / sample_count;
        max_avg = max_avg / sample_count;
        empty_avg = empty_avg / sample_count;

        data.* = .{
            .total = avg_shapes_per_cell,
            .max = max_avg,
            .empty = empty_avg,
        };
    }

    fn setAllDensity(self: *CellDensity) void {
        const sample_count = @min(self.circle_counts.items.len, self.rect_counts.items.len, self.point_counts.items.len);
        if (sample_count == 0) {
            self.all_data = .{};
            return;
        }

        var avg_shapes_per_cell: f64 = 0;
        var max_avg: f64 = 0;
        var empty_avg: f64 = 0;

        for (0..sample_count) |frame_idx| {
            const circle = self.circle_counts.items[frame_idx];
            const rect = self.rect_counts.items[frame_idx];
            const point = self.point_counts.items[frame_idx];
            const cell_len = @min(circle.len, rect.len, point.len);
            if (cell_len == 0) continue;

            var total: usize = 0;
            var empty: usize = 0;
            var max: usize = 0;

            for (0..cell_len) |cell_idx| {
                const combined: usize = circle[cell_idx] + rect[cell_idx] + point[cell_idx];
                total += combined;
                if (combined == 0) empty += 1;
                max = @max(max, combined);
            }

            const cell_count = @as(f64, @floatFromInt(cell_len));
            avg_shapes_per_cell += @as(f64, @floatFromInt(total)) / cell_count;
            empty_avg += @as(f64, @floatFromInt(empty));
            max_avg += @as(f64, @floatFromInt(max));
        }

        const frames = @as(f64, @floatFromInt(sample_count));
        self.all_data = .{
            .total = avg_shapes_per_cell / frames,
            .empty = empty_avg / frames,
            .max = max_avg / frames,
        };
    }
};

const ShapeCounts = @Struct(
    .auto,
    null,
    blk: {
        var names: [std.meta.tags(ShapeType).len][]const u8 = undefined;
        for (std.meta.tags(ShapeType), 0..) |tag, i| {
            names[i] = @tagName(tag);
        }
        break :blk &names;
    },
    &[_]type{usize} ** std.meta.tags(ShapeType).len,
    &[_]std.builtin.Type.StructField.Attributes{.{}} ** std.meta.tags(ShapeType).len,
);

fn isShapeCountEql(shape_count_a: ShapeCounts, shape_count_b: ShapeCounts) bool {
    inline for (std.meta.fields(ShapeCounts)) |field| {
        const count_a = @field(shape_count_a, field.name);
        const count_b = @field(shape_count_b, field.name);

        if (count_a != count_b) return false;
    }
    return true;
}

fn getTotalCount(shape_counts: ShapeCounts) usize {
    var total: usize = 0;
    inline for (std.meta.fields(ShapeCounts)) |field| {
        total += @field(shape_counts, field.name);
    }
    return total;
}
