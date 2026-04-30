const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;
const Arraylist = std.ArrayList;
const Timestamp = std.Io.Clock.Timestamp;

// Future useful profiler categories:
// - Grid dimensions: cell size, rows, cols, total cells.
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

    shape_count_start: ShapeCounts = undefined,
    shape_count_end: ShapeCounts = undefined,

    running: bool = false,
    finished: bool = false,
    logged_max_frame_msg: bool = false,

    items: struct {
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

        self.items.build = .init(allocator, io, self, "Build", true);
        self.items.insert_circles = .init(allocator, io, self, "Insert Circles", true);
        self.items.insert_rects = .init(allocator, io, self, "Insert Rects", true);
        self.items.insert_points = .init(allocator, io, self, "Insert Points", true);
        self.items.find_collision = .init(allocator, io, self, "Finding Collisions", true);
        self.items.update = .init(allocator, io, self, "Update", false);
        return self;
    }

    pub fn deinit(self: *Profiler) void {
        self.running = false;
        inline for (std.meta.fields(@TypeOf(self.items))) |field| {
            const item = &@field(self.items, field.name);
            item.deinit();
        }
        self.results.deinit();
        self.allocator.destroy(self);
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

        const elapsed_seconds: f32 = (self.end_time) / 1000.0;

        try out.print("Time Profiled: {d:.2}s\n", .{elapsed_seconds});
        try out.print("Threads: {}\n", .{grid.impl.thread_count});

        if (!isShapeCountEql(self.shape_count_start, self.shape_count_end)) {
            try out.writeAll("Starting Shapes:\n");
            try self.printShapeCounts(self.shape_count_start);
            try out.writeAll("\nEnding Shapes:\n");
            try self.printShapeCounts(self.shape_count_end);
        } else {
            try out.writeAll("\nShape Count:\n");
            try self.printShapeCounts(self.shape_count_end);
        }
        try out.writeAll("\n");

        const ItemFields = std.meta.fields(@TypeOf(self.items));
        var relevant_sum: f64 = 0;

        // Percent is based on average time so unequal sample counts do not skew the breakdown.
        inline for (ItemFields) |field| {
            const item = &@field(self.items, field.name);
            if (item.include_percent and item.hasResults()) {
                const avg = item.getAvg();
                item.percent_time = avg.nanos;
                relevant_sum += avg.nanos;
            }
        }

        inline for (ItemFields) |field| {
            const item = &@field(self.items, field.name);
            if (item.include_percent and item.hasResults() and relevant_sum > 0) {
                item.percent = (item.percent_time / relevant_sum) * 100;
            }
        }

        inline for (ItemFields) |field| {
            const item = @field(self.items, field.name);
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

    fn printShapeCounts(self: *Profiler, shape_count: ShapeCounts) !void {
        inline for (std.meta.fields(ShapeType)) |field| {
            const count = @field(shape_count, field.name);
            if (count > 0) {
                try self.results.writer.print("  {s}: {}\n", .{ field.name, count });
            }
        }
        try self.results.writer.print("  Total: {}\n", .{getTotalCount(shape_count)});
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
