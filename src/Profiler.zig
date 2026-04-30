const std = @import("std");
const Arraylist = std.ArrayList;
const Timestamp = std.Io.Clock.Timestamp;

pub const Profiler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    results: std.Io.Writer.Allocating = undefined,

    start_time: Timestamp = undefined,
    end_time: f32 = 0,

    running: bool = false,
    finished: bool = false,
    logged_max_frame_msg: bool = false,

    items: struct {
        build: ProfileItem,
        insert_circles: ProfileItem,
        insert_rects: ProfileItem,
        insert_points: ProfileItem,
        update: ProfileItem,
    } = undefined,

    pub fn init(self: *Profiler, allocator: std.mem.Allocator, io: std.Io) void {
        self.* = .{ .allocator = allocator, .io = io };
        self.results = .init(allocator);

        self.items.build = .init(allocator, io, self, "Build");
        self.items.insert_circles = .init(allocator, io, self, "Insert Circles");
        self.items.insert_rects = .init(allocator, io, self, "Insert Rects");
        self.items.insert_points = .init(allocator, io, self, "Insert Points");
        self.items.update = .init(allocator, io, self, "Update");
    }

    pub fn deinit(self: *Profiler) void {
        self.running = false;
        inline for (std.meta.fields(@TypeOf(self.items))) |field| {
            const item = &@field(self.items, field.name);
            item.deinit();
        }
        self.results.deinit();
    }

    pub fn start(self: *Profiler, max_frames: ?usize) void {
        if (max_frames) |f| ProfileItem.max_samples = f;
        self.running = true;
        self.start_time = Timestamp.now(self.io, .awake);
    }

    pub fn stop(self: *Profiler) void {
        const elapsed_dur = self.start_time.durationTo(
            Timestamp.now(self.io, .awake),
        );

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

        try out.print("Time Profiled {d:.2}s\n", .{elapsed_seconds});
        try out.print("Threads: {}\n", .{grid.impl.thread_count});

        inline for (std.meta.fields(@TypeOf(self.items))) |field| {
            const item = @field(self.items, field.name);
            try out.print("\t{s}:\n", .{item.text});

            if (item.times.items.len > 0) {
                var avg: f32 = 0;
                for (item.times.items) |time| avg += @floatFromInt(time);
                avg = avg / @as(f32, @floatFromInt(item.times.items.len));
                const avg_ms = avg / 1_000_000.0;

                try out.print("\t  Avg: {d:.0}ns | {d:.3}ms", .{ avg, avg_ms });
            } else try out.print("\tN/A", .{});
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
    start_time: Timestamp = undefined,
    times: Arraylist(i96) = .empty,
    percent: f32 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, profiler: *Profiler, text: []const u8) ProfileItem {
        return .{ .allocator = allocator, .io = io, .profiler = profiler, .text = text };
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

    pub fn getTotalTimeRan(self: ProfileItem) i64() {
        var total: i96 = 0;
        for(self.times.items) |t| {
            total += t;
        }
    }
};
