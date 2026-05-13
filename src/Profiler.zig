const std = @import("std");
const builtin = @import("builtin");
const ProfileFrame = @import("ProfileFrame.zig").ProfileFrame;
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

fn getCellCount(counts: []const u32, idx: usize) usize {
    if (idx >= counts.len) return 0;
    return if (idx == 0)
        @intCast(counts[0])
    else
        @intCast(counts[idx] - counts[idx - 1]);
}

pub const Profiler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    results: std.Io.Writer.Allocating = undefined,
    profile_frames: std.ArrayList(ProfileFrame) = .empty,

    start_time: Timestamp = undefined,
    last_time: i96 = undefined,

    time_elapsed: f64 = 0,
    frames: usize = 0,
    fps: f64 = 0,

    running: bool = false,

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

        self.profile_frames.deinit(self.allocator);
        self.results.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Profiler) void {
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
        self.running = false;
    }

    pub fn writeResults(self: *Profiler, grid: anytype, clear_screen: bool) !void {
        if (@mod(self.frames, 10) != 0 and self.frames > 10) return;

        const frame = self.captureFrame(grid);
        try self.profile_frames.append(self.allocator, frame);
        try self.writeFrame(frame, clear_screen);
    }

    fn writeFrame(self: *Profiler, frame: ProfileFrame, clear_screen: bool) !void {
        self.results.clearRetainingCapacity();
        const out = &self.results.writer;
        if (clear_screen) try out.writeAll("\x1b[2J\x1b[H");
        try frame.fmt(out);
    }

    fn captureFrame(self: *Profiler, grid: anytype) ProfileFrame {
        var cell_density: CellDensity = .{};
        cell_density.setCellDensity(grid);

        return .{
            .grid = self.captureGridData(grid),
            .shapes = captureShapeCounts(grid),
            .cells = captureCellData(grid, cell_density),
            .timing = self.captureTimingData(),
            .detection = captureDetectionData(grid),
        };
    }

    fn captureGridData(self: *Profiler, grid: anytype) ProfileFrame.Grid {
        return .{
            .build = @tagName(builtin.mode),
            .elapsed = self.time_elapsed,
            .frame = self.frames,
            .threads = grid.impl.thread_count,
            .fps = self.fps,
            .area_pixels = grid.impl.width * grid.impl.height,
        };
    }

    fn captureTimingData(self: *Profiler) ProfileFrame.Timing {
        const ItemFields = std.meta.fields(@TypeOf(self.timed_items));
        var relevant_sum: f64 = 0;

        inline for (ItemFields) |field| {
            const item = @field(self.timed_items, field.name);
            if (item.include_percent and item.hasResults()) {
                relevant_sum += item.last_time_ns;
            }
        }

        return .{
            .build = timingData(self.timed_items.build, relevant_sum),
            .insert_circles = timingData(self.timed_items.insert_circles, relevant_sum),
            .insert_rects = timingData(self.timed_items.insert_rects, relevant_sum),
            .insert_points = timingData(self.timed_items.insert_points, relevant_sum),
            .finding_collisions = timingData(self.timed_items.find_collision, relevant_sum),
            .update = timingData(self.timed_items.update, relevant_sum),
        };
    }
};

const ProfileItem = struct {
    io: std.Io,

    profiler: *Profiler,
    text: []const u8,
    include_percent: bool,
    start_time: Timestamp = undefined,
    last_time_ns: f64 = 0,

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

fn shapeData(comptime shape_type: ShapeType, profile_data: anytype) ProfileFrame.ShapeData {
    return .{
        .shape_type = shape_type,
        .count = profile_data.count,
        .avg_size = profile_data.avg,
        .min_size = profile_data.smallest,
        .max_size = profile_data.largest,
    };
}

fn captureShapeCounts(grid: anytype) ProfileFrame.Shapes {
    const circles = grid.impl.circle_storage.getProfileData();
    const rects = grid.impl.rect_storage.getProfileData();
    const points = grid.impl.point_storage.getProfileData();

    return .{
        .total_count = circles.count + rects.count + points.count,
        .circle = shapeData(.Circle, circles),
        .rect = shapeData(.Rect, rects),
        .point = shapeData(.Point, points),
    };
}

fn cellData(shape_type: ?ShapeType, density: CellDensity.DensityData) ProfileFrame.CellData {
    return .{
        .shape_type = shape_type,
        .avg_shapes_per_cell = density.total,
        .empty_cells = @intFromFloat(density.empty),
        .max_in_cell = @intFromFloat(density.max),
    };
}

fn captureCellData(grid: anytype, cell_density: CellDensity) ProfileFrame.Cells {
    return .{
        .rows = grid.impl.rows,
        .cols = grid.impl.cols,
        .cell_size = grid.impl.cell_size,
        .cell_mult = grid.cell_size_multiplier,
        .cell_count = grid.impl.rows * grid.impl.cols,
        .combined = cellData(null, cell_density.all_data),
        .circle = cellData(.Circle, cell_density.circle_data),
        .rect = cellData(.Rect, cell_density.rect_data),
        .point = cellData(.Point, cell_density.point_data),
    };
}

fn timingData(item: ProfileItem, relevant_sum: f64) ProfileFrame.TimingData {
    const last_ns: ?f64 = if (item.hasResults()) item.last_time_ns else null;
    const percent: ?f64 = if (item.include_percent and item.hasResults() and relevant_sum > 0)
        (item.last_time_ns / relevant_sum) * 100
    else
        null;

    return .{
        .label = item.text,
        .last_ns = last_ns,
        .percent = percent,
        .include_percent = item.include_percent,
    };
}

fn captureDetectionData(grid: anytype) ProfileFrame.Detection {
    const collision_counter: CollisionCounter = blk: {
        if (!grid.impl.multi_threaded) break :blk grid.impl.collision_counter;

        var attempts: f32 = 0;
        var hits: f32 = 0;

        for (grid.impl.workers) |*worker| {
            attempts += worker.collision_counter.pressure;
            hits += worker.collision_counter.hits;
            worker.collision_counter.reset();
        }
        break :blk .{ .pressure = attempts, .hits = hits };
    };

    const pressure: f64 = @floatCast(collision_counter.pressure);
    const hits: f64 = @floatCast(collision_counter.hits);
    const missed: f64 = pressure - hits;
    const hits_percent: f64 = if (pressure == 0) 0 else hits / pressure * 100;
    const miss_percent: f64 = if (pressure == 0) 0 else missed / pressure * 100;

    return .{
        .query_pressure = pressure,
        .detected = .{ .raw = hits, .percent = hits_percent },
        .missed = .{ .raw = missed, .percent = miss_percent },
    };
}

const CellDensity = struct {
    const DensityData = struct { total: f64 = 0, empty: f64 = 0, max: f64 = 0 };

    all_data: DensityData = .{},
    circle_data: DensityData = .{},
    rect_data: DensityData = .{},
    point_data: DensityData = .{},

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
