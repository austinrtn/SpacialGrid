const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;
const Timestamp = std.Io.Clock.Timestamp;

// Future useful profiler categories:
// - Cell density: shapes per cell, shapes in one cell, empty cell percent.
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
    end_time: f64 = 0,
    last_time: i96 = undefined,

    time_elapsed: f64 = 0,
    frames: f64 = 0,
    fps: f64 = 0,

    shape_count_start: ShapeCounts = undefined,
    shape_count_end: ShapeCounts = undefined,

    running: bool = false,
    finished: bool = false,
    logged_max_frame_msg: bool = false,

    cell_density: CellDensity = undefined,
    cell_data_text: []const u8 = undefined,
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
        self.cell_data_text = try allocator.dupe(u8, "");
        self.cell_density = .init();

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
        self.allocator.free(self.cell_data_text);

        inline for (std.meta.fields(@TypeOf(self.timed_items))) |field| {
            const item = &@field(self.timed_items, field.name);
            item.deinit();
        }
        self.results.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Profiler, max_frames: ?usize) void {
        _ = max_frames;
        self.running = true;
        self.start_time = Timestamp.now(self.io, .awake);
        self.last_time = self.start_time.raw.nanoseconds;
    }

    pub fn update(self: *Profiler) void {
        if (!self.running) return;
        const now = Timestamp.now(self.io, .awake);
        const delta_ns = now.raw.nanoseconds - self.last_time;
        self.last_time = now.raw.nanoseconds;

        self.frames += 1;
        const elapsed_ts = self.start_time.durationTo(now);

        const elapsed_milis: f64 = @floatFromInt(elapsed_ts.raw.toMilliseconds());
        self.time_elapsed = elapsed_milis / 1000;

        self.fps = if (delta_ns <= 0) 0 else 1_000_000_000.0 / @as(f64, @floatFromInt(delta_ns));
    }

    pub fn stop(self: *Profiler) void {
        const elapsed_dur = self.start_time.durationTo(
            Timestamp.now(self.io, .awake),
        );

        self.end_time = @floatFromInt(elapsed_dur.raw.toMilliseconds());
        self.running = false;
        self.finished = true;
    }

    pub fn writeResults(self: *Profiler, grid: anytype, clear_screen: bool) !void {
        const out = &self.results.writer;
        if (clear_screen) try out.writeAll("\x1b[2J \x1b[H");
        const header: []const u8 = "Spacial Grid Profiling";
        try out.print("{s}\n", .{header});

        for (0..header.len) |_| try out.writeAll("_");
        try out.writeAll("\n");

        try self.writeGridData(grid);

        // if (!isShapeCountEql(self.shape_count_start, self.shape_count_end)) {
        //     try out.writeAll("Starting Shapes:\n");
        //     try self.writeShapeCounts(self.shape_count_start);
        //     try out.writeAll("\nEnding Shapes:\n");
        //     try self.writeShapeCounts(self.shape_count_end);
        // } else {
        //     try out.writeAll("\nShape Count:\n");
        //     try self.writeShapeCounts(self.shape_count_end);
        // }
        try out.writeAll("\n");

        try self.writeCellData(grid);
        // try out.writeAll("\n");
        // try self.writeTimedItems();
    }

    fn writeGridData(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;

        try out.print("Time Profiled: {d:.2}s\n", .{self.time_elapsed});
        try out.print("Frame: {d:.0}\n", .{self.frames});
        try out.print("Threads: {}\n", .{grid.impl.thread_count});
        try out.print("FPS: {d:.2}\n", .{self.fps});
    }

    fn writeCellData(self: *Profiler, grid: anytype) !void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        const out = &writer.writer;

        try out.writeAll("\nCell Data:\n");
        try out.print("  Rows: {}\n  Cols: {}\n", .{ grid.impl.rows, grid.impl.cols });
        try out.print("  Cell Size: {}\n  Cell Count: {}\n", .{ grid.impl.cell_size, grid.impl.rows * grid.impl.cols });

        self.cell_density.setCellDensity(grid);

        try out.writeAll("\n  Combined:\n");
        try writeDensityData(self.cell_density.all_data, out);
        try out.writeAll("  Circle:\n");
        try writeDensityData(self.cell_density.circle_data, out);
        try out.writeAll("  Rect:\n");
        try writeDensityData(self.cell_density.rect_data, out);
        try out.writeAll("  Point:\n");
        try writeDensityData(self.cell_density.point_data, out);

        self.allocator.free(self.cell_data_text);
        self.cell_data_text = try self.allocator.dupe(u8, writer.written());
        try self.results.writer.print("{s}", .{self.cell_data_text});
    }

    fn writeDensityData(data: CellDensity.DensityData, out: *std.Io.Writer) !void {
        try out.print(
            "    Shapes/Cell: {d:.2}\n    Empty Cells: {d:.0}\n    Max In Cell: {d:.0}\n",
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

        inline for (ItemFields) |field| {
            const item = &@field(self.timed_items, field.name);
            if (item.include_percent and item.hasResults()) {
                item.percent_time = item.last_time_ns;
                relevant_sum += item.last_time_ns;
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
                try out.print("  Last: {d:.4}ms", .{item.last_time_ns / 1_000_000.0});
                if (item.include_percent)
                    try out.print(" | {d:.2}%", .{item.percent});
            }

            try out.writeAll("\n");
        }
    }
};

const ProfileItem = struct {
    io: std.Io,

    profiler: *Profiler,
    text: []const u8,
    include_percent: bool,
    start_time: Timestamp = undefined,
    last_time_ns: f64 = 0,
    percent: f64 = 0,
    percent_time: f64 = 0,

    fn init(_: std.mem.Allocator, io: std.Io, profiler: *Profiler, text: []const u8, include_percent: bool) ProfileItem {
        return .{
            .io = io,
            .profiler = profiler,
            .text = text,
            .include_percent = include_percent,
        };
    }

    fn deinit(_: *ProfileItem) void {}

    pub fn start(self: *ProfileItem) void {
        if (!self.profiler.running) return;
        self.start_time = Timestamp.now(self.io, .awake);
    }

    pub fn stop(self: *ProfileItem) !void {
        if (!self.profiler.running) return;
        const end_time = self.start_time.durationTo(
            Timestamp.now(self.io, .awake),
        );
        self.last_time_ns = @floatFromInt(end_time.raw.toNanoseconds());
    }

    fn hasResults(self: ProfileItem) bool {
        return self.last_time_ns > 0;
    }
};

const CellDensity = struct {
    const DensityData = struct { total: f64 = 0, empty: f64 = 0, max: f64 = 0 };

    all_data: DensityData = .{},
    circle_data: DensityData = .{},
    rect_data: DensityData = .{},
    point_data: DensityData = .{},

    fn init() CellDensity {
        return .{};
    }

    fn setCellDensity(self: *CellDensity, grid: anytype) void {
        self.setShapeStorageDensity(grid.impl.circle_storage.counts, &self.circle_data);
        self.setShapeStorageDensity(grid.impl.rect_storage.counts, &self.rect_data);
        self.setShapeStorageDensity(grid.impl.point_storage.counts, &self.point_data);
        self.setAllDensity(
            grid.impl.circle_storage.counts,
            grid.impl.rect_storage.counts,
            grid.impl.point_storage.counts,
        );
    }

    fn setShapeStorageDensity(self: *CellDensity, counts: []const u32, data: *DensityData) void {
        _ = self;
        if (counts.len == 0) {
            data.* = .{};
            return;
        }

        var total: usize = 0;
        var empty: usize = 0;
        var max: usize = 0;

        for (0..counts.len) |i| {
            const c: usize = if (i == 0)
                @intCast(counts[0])
            else
                @intCast(counts[i] - counts[i - 1]);
            total += c;
            if (c == 0) empty += 1;
            max = @max(max, c);
        }

        const cell_count = @as(f64, @floatFromInt(counts.len));

        data.* = .{
            .total = @as(f64, @floatFromInt(total)) / cell_count,
            .max = @floatFromInt(max),
            .empty = @floatFromInt(empty),
        };
    }

    fn setAllDensity(self: *CellDensity, circle_counts: []const u32, rect_counts: []const u32, point_counts: []const u32) void {
        const cell_len = @min(circle_counts.len, rect_counts.len, point_counts.len);
        if (cell_len == 0) {
            self.all_data = .{};
            return;
        }

        var total: usize = 0;
        var empty: usize = 0;
        var max: usize = 0;

        for (0..cell_len) |cell_idx| {
            const combined: usize =
                getCellCount(circle_counts, cell_idx) +
                getCellCount(rect_counts, cell_idx) +
                getCellCount(point_counts, cell_idx);
            total += combined;
            if (combined == 0) empty += 1;
            max = @max(max, combined);
        }

        const cell_count = @as(f64, @floatFromInt(cell_len));
        self.all_data = .{
            .total = @as(f64, @floatFromInt(total)) / cell_count,
            .empty = @floatFromInt(empty),
            .max = @floatFromInt(max),
        };
    }
};

fn getCellCount(counts: []const u32, idx: usize) usize {
    if (idx >= counts.len) return 0;
    return if (idx == 0)
        @intCast(counts[0])
    else
        @intCast(counts[idx] - counts[idx - 1]);
}

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
