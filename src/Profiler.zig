const std = @import("std");
const builtin = @import("builtin");
const ShapeType = @import("ShapeType.zig").ShapeType;
const Timestamp = std.Io.Clock.Timestamp;

// Future useful profiler categories:
// - Candidate pressure: total narrowphase checks, checks per shape, checks per collision.
// - Collision results: total collisions found, hit rate from candidates.
// - Query pressure: avg queried cells and avg candidate shapes per query.
// - Worker balance: per-thread time, work items processed, candidates checked, collisions found.
// - Memory behavior: result list capacity, query buffer capacity, realloc counts.

pub const CollisionCounter = struct {
    pressure: f32 = 0,
    hits: f32 = 0,

    pub fn reset(self: *@This()) void {
        self.pressure = 0;
        self.hits = 0;
    }
};

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

    collision_candidates: std.atomic.Value(usize) = .init(0),
    narrowphase_hits: std.atomic.Value(usize) = .init(0),
    narrowphase_misses: std.atomic.Value(usize) = .init(0),

    cell_density: CellDensity = undefined,
    cell_data_text: []const u8 = undefined, // This likely needs to be depreciated

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

        self.timed_items.build = .init(io, self, "Build", true);
        self.timed_items.insert_circles = .init(io, self, "Insert Circles", true);
        self.timed_items.insert_rects = .init(io, self, "Insert Rects", true);
        self.timed_items.insert_points = .init(io, self, "Insert Points", true);
        self.timed_items.find_collision = .init(io, self, "Finding Collisions", true);
        self.timed_items.update = .init(io, self, "Update", false);
        return self;
    }

    pub fn deinit(self: *Profiler) void {
        self.running = false;
        self.allocator.free(self.cell_data_text);

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
        if(@mod(self.frames, 10) != 0 and self.frames > 10) return;

        self.results.clearRetainingCapacity();
        const out = &self.results.writer;
        if (clear_screen) try out.writeAll("\x1b[2J \x1b[H");
        const header: []const u8 = "Spacial Grid Profiling";
        try out.print("{s}\n", .{header});

        for (0..header.len) |_| try out.writeAll("_");
        try out.writeAll("\n");

        try out.writeAll("\n");

        try self.writeGridData(grid);
        try out.writeAll("\n");
        try self.writeShapeCounts(grid);
        try self.writeCellData(grid);
        try out.writeAll("\n");
        try self.writeTimedItems();

        const collision_counter: struct{attempts: f32, hits: f32} = blk: {
            if(!grid.impl.multi_threaded) {
                break :blk grid.impl.collision_counter;
            }

            // If grid is multi-threaded
            var attempts: f32 = 0;
            var hits: f32 = 0;

            for(grid.impl.workers) |worker| {
                attempts += worker.collision_counter.attemtps;
                hits += worker.collision_counter.hits;
                worker.collision_counter.reset();
            }
            break :blk .{.attempts = attempts, .hits = hits};
        };

        const missed = collision_counter.attempts - collision_counter.hits;
        const hits_percent: f32 = collision_counter.hits / collision_counter.attempts * 100;
        const miss_percent: f32 = missed / collision_counter.attempts * 100;

        try out.print("\nQuery Pressure: {}\n", .{collision_counter.attempts});
        try out.print("Collisions Detected: {} | {d:.2}%\n", .{collision_counter.hits, hits_percent});
        try out.print("Collisions Missed: {} | {d:.2}%\n", .{self.narrowphase_misses, miss_percent});
    }

    fn writeGridData(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;

        try out.writeAll("Grid\n");
        try out.print("  Build      : {s}\n", .{@tagName(builtin.mode)});
        try out.print("  Time       : {d:.2}s\n", .{self.time_elapsed});
        try out.print("  Frame      : {d:.0}\n", .{self.frames});
        try out.print("  Threads    : {}\n", .{grid.impl.thread_count});
        try out.print("  FPS        : {d:.2}\n", .{self.fps});
    }

    fn writeCellData(self: *Profiler, grid: anytype) !void {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer writer.deinit();
        const out = &writer.writer;

        try out.writeAll("\nCells\n");
        try out.print("  Rows       : {}\n", .{grid.impl.rows});
        try out.print("  Cols       : {}\n", .{grid.impl.cols});
        try out.print("  Cell Size  : {d:.2}\n", .{grid.impl.cell_size});
        try out.print("  Cell Count : {}\n", .{grid.impl.rows * grid.impl.cols});

        self.cell_density.setCellDensity(grid);

        try out.writeAll("\n  Type      | Avg Shapes/Cell | Empty Cells | Max In Cell\n");
        try writeDensityData("Combined", self.cell_density.all_data, out);
        try writeDensityData("Circle", self.cell_density.circle_data, out);
        try writeDensityData("Rect", self.cell_density.rect_data, out);
        try writeDensityData("Point", self.cell_density.point_data, out);

        self.allocator.free(self.cell_data_text);
        self.cell_data_text = try self.allocator.dupe(u8, writer.written());
        try self.results.writer.print("{s}", .{self.cell_data_text});
    }

    fn writeDensityData(label: []const u8, data: CellDensity.DensityData, out: *std.Io.Writer) !void {
        try out.print(
            "  {s:<9} | {d:>15.2} | {d:>11.0} | {d:>5.0}\n",
            .{ label, data.total, data.empty, data.max },
        );
    }

    fn writeShapeCounts(self: *Profiler, grid: anytype) !void {
        const out = &self.results.writer;

        const circles = grid.impl.circle_storage.getProfileData();
        const rects = grid.impl.rect_storage.getProfileData();
        const points = grid.impl.point_storage.getProfileData();

        const total_count = circles.count + rects.count + points.count;

        try out.writeAll("Shapes\n");
        try out.print("  Total      : {}\n", .{total_count});
        try out.writeAll("\n  Type    | Count | Avg Size | Min Size | Max Size\n");
        try out.print(
            "  Circle  | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
            .{ circles.count, circles.avg, circles.smallest, circles.largest },
        );
        try out.print(
            "  Rect    | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
            .{ rects.count, rects.avg, rects.smallest, rects.largest },
        );
        try out.print(
            "  Point   | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
            .{ points.count, points.avg, points.smallest, points.largest },
        );
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

        try out.writeAll("Timing\n");
        try out.writeAll("  Stage               | Last (ms) | Percent\n");

        inline for (ItemFields) |field| {
            const item = @field(self.timed_items, field.name);
            if (!item.hasResults()) {
                if (item.include_percent) {
                    try out.print("  {s:<19} | {s:>9} | {s:>7}\n", .{ item.text, "N.A", "N.A" });
                } else {
                    try out.print("  {s:<19} | {s:>9} | {s:>7}\n", .{ item.text, "N.A", "-" });
                }
            } else {
                if (item.include_percent) {
                    try out.print(
                        "  {s:<19} | {d:>9.4} | {d:>6.2}%\n",
                        .{ item.text, item.last_time_ns / 1_000_000.0, item.percent },
                    );
                } else {
                    try out.print(
                        "  {s:<19} | {d:>9.4} | {s:>7}\n",
                        .{ item.text, item.last_time_ns / 1_000_000.0, "-" },
                    );
                }
            }
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

    fn init(io: std.Io, profiler: *Profiler, text: []const u8, include_percent: bool) ProfileItem {
        return .{
            .io = io,
            .profiler = profiler,
            .text = text,
            .include_percent = include_percent,
        };
    }

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
        setShapeStorageDensity(grid.impl.circle_storage.counts, &self.circle_data);
        setShapeStorageDensity(grid.impl.rect_storage.counts, &self.rect_data);
        setShapeStorageDensity(grid.impl.point_storage.counts, &self.point_data);
        self.setAllDensity(
            grid.impl.circle_storage.counts,
            grid.impl.rect_storage.counts,
            grid.impl.point_storage.counts,
        );
    }

    fn setShapeStorageDensity(counts: []const u32, data: *DensityData) void {
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
