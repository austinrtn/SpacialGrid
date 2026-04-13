const std = @import("std");
const builtin = @import("builtin");
const Lib = @import("SpacialGrid");

const THREAD_COUNT = 1;
const SpacialGrid = Lib.SpacialGrid(.{.thread_count = THREAD_COUNT});
const ShapeType = Lib.ShapeType;
const Entity    = Lib.Entity;

const FrameMeteric = struct {
    frame: usize = 0,
    frame_time: i64 = 0,
    median_dist: f32 = 0,

    fn setMedianDistance(self: *FrameMeteric, allocator: std.mem.Allocator,
        prng: *std.Random.DefaultPrng, x_pos: []f32, y_pos: []f32) !void {
        const sample_size: usize = 1000;
        const rand = prng.random();

        var dists: std.ArrayList(f32) = .empty;
        defer dists.deinit(allocator);

        for (0..sample_size) |_| {
            const id_a = rand.intRangeAtMost(usize, 0, x_pos.len - 1);
            const id_b = rand.intRangeAtMost(usize, 0, x_pos.len - 1);
            if (id_a >= id_b) continue;
            const dx = x_pos[id_a] - x_pos[id_b];
            const dy = y_pos[id_a] - y_pos[id_b];
            try dists.append(allocator, @sqrt(dx * dx + dy * dy));
        }

        std.mem.sort(f32, dists.items, {}, std.sort.asc(f32));
        self.median_dist = dists.items[@divTrunc(dists.items.len, 2)];
    }
};

const Config = struct {
    world_w: f32 = 1000,
    world_h: f32 = 1000,
    timeout: i64 = 5,
    ent_count: usize = 100,

    min_r: f32 = 4,
    max_r: f32 = 12,

    min_wh: f32 = 4,
    max_wh: f32 = 12,
    shape: enum { Rect, Circle, All } = .All,
    update_stdout: bool = false,
    naive: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var buf: [2056]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    const writer = &stdout.interface;

    const config = try parseArgs(allocator, init.minimal.args);
    var grid: *SpacialGrid = try .init(.{
        .allocator = init.gpa,
        .ent_count = config.ent_count,
        .width     = config.world_w,
        .height    = config.world_h,
        .auto_cell_resize = false,
        .cell_size = 25,
        .io        = init.io,
    });
    defer grid.deinit();

    var ents: std.MultiArrayList(Entity) = .empty;
    defer ents.deinit(allocator);

    try ents.ensureTotalCapacity(allocator, config.ent_count);
    var prng = Lib.getPrng(init.io);

    const Clock = std.Io.Clock;

    var frames: std.ArrayList(FrameMeteric) = .empty;
    defer frames.deinit(allocator);

    try writer.writeAll("Starting sim...\n");
    try writer.flush();

    var profiler = struct {
        collision: std.ArrayList(i128) = .empty,
        query: std.ArrayList(i128) = .empty,
        insert: std.ArrayList(i128) = .empty,
        cell_max: std.ArrayList(usize) = .empty,
        hits: usize = 0,

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.collision.deinit(alloc);
            self.query.deinit(alloc);
            self.insert.deinit(alloc);
            self.cell_max.deinit(alloc);
        }
    }{};
    defer profiler.deinit(allocator);

    const start = Clock.Timestamp.now(init.io, .awake);
    var i: usize = 0;
    while (true) : (i += 1) {
        if (config.update_stdout and i > 0) {
            const last_frame = frames.items[i - 1];
            const elapsed = start.durationTo(Clock.Timestamp.now(init.io, .awake));
            try writer.print("Frame: {} | FrameTime: {} | Elapsed: {}\r",
                .{ last_frame.frame, last_frame.frame_time, elapsed.raw.toSeconds() },
            );
            try writer.flush();
        }

        try generateEnts(allocator, &ents, &prng, config);

        const start_query = Clock.Timestamp.now(init.io, .awake);

        const data = Lib.CollisionData{
            .count   = ents.len,
            .x_pos   = ents.items(.x),
            .y_pos   = ents.items(.y),
            .shapes  = ents.items(.shape),
            .widths  = ents.items(.w),
            .heights = ents.items(.h),
            .radii   = ents.items(.r),
        };

        if (config.naive) try naiveCollisions(allocator, data)
        else {
            try grid.setCellSize(data.shapes, data.radii, data.widths, data.heights, 1.5);
            try grid.update(data, &profiler);
        }

        const end_query = start_query.durationTo(Clock.Timestamp.now(init.io, .awake));

        var frame = FrameMeteric{
            .frame = i,
            .frame_time = end_query.raw.toMilliseconds(),
        };
        try frame.setMedianDistance(allocator, &prng, ents.items(.x), ents.items(.y));
        try frames.append(allocator, frame);

        const elapsed = start.durationTo(Clock.Timestamp.now(init.io, .awake));
        if (elapsed.raw.toSeconds() >= config.timeout) break;
    }

    try printStats(writer, init.io, config, frames.items, &profiler);
    try writer.flush();
}

fn generateEnts(allocator: std.mem.Allocator, ents: *std.MultiArrayList(Entity), prng: *std.Random.DefaultPrng, config: Config) !void {
    const rand = prng.random();
    ents.clearRetainingCapacity();

    for (0..config.ent_count) |_| {
        const x = rand.float(f32) * config.world_w;
        const y = rand.float(f32) * config.world_h;

        var w: f32 = 0.0;
        var h: f32 = 0.0;
        var r: f32 = 0.0;

        const shape: ShapeType = switch (config.shape) {
            .Circle => .Circle,
            .Rect   => .Rect,
            .All    => if (rand.intRangeAtMost(usize, 0, 1) == 0) .Circle else .Rect,
        };

        switch (shape) {
            .Rect => {
                w = rand.float(f32) * (config.max_wh - config.min_wh) + config.min_wh;
                h = rand.float(f32) * (config.max_wh - config.min_wh) + config.min_wh;
            },
            .Circle => r = rand.float(f32) * (config.max_r - config.min_r) + config.min_r,
            .Point  => {},
        }

        try ents.append(allocator, try Entity.init(x, y, shape, .{.w = w, .h = h, .r = r}));
    }
}

fn naiveCollisions(allocator: std.mem.Allocator, data: Lib.CollisionData) !void {
    var results: std.ArrayList(Lib.CollisionPair) = .empty;
    defer results.deinit(allocator);

    for (0..data.count) |a| {
        for (a + 1..data.count) |b| {
            if (Lib.CollisionDetection.checkColliding(
                data.x_pos[a], data.y_pos[a], data.shapes[a], data.radii[a], data.widths[a], data.heights[a],
                data.x_pos[b], data.y_pos[b], data.shapes[b], data.radii[b], data.widths[b], data.heights[b],
            )) {
                try results.append(allocator, .{ .a = a, .b = b });
            }
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Config {
    var config: Config = .{};
    var iter = try args.iterateAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    while (iter.next()) |arg| {
        if (try convertArg(f32, arg, "world_w=")) |result| config.world_w = result
        else if (try convertArg(f32, arg, "world_h=")) |result| config.world_h = result

        else if (try convertArg(f32, arg, "min_r=")) |result| config.min_r = result
        else if (try convertArg(f32, arg, "max_r=")) |result| config.max_r = result

        else if (try convertArg(f32, arg, "min_wh=")) |result| config.min_wh = result
        else if (try convertArg(f32, arg, "max_wh=")) |result| config.max_wh = result

        else if (try convertArg(usize, arg, "count=")) |result| config.ent_count = result
        else if (try convertArg(i64, arg, "timeout=")) |result| config.timeout = result
        else if (try convertArg(usize, arg, "update=")) |result| {
            config.update_stdout = result != 0;
        }
        else if (try convertArg(usize, arg, "naive=")) |result| {
            config.naive = result != 0;
        }
        else if (std.mem.startsWith(u8, arg, "shape=")) {
            const val = arg["shape=".len..];
            if (std.mem.eql(u8, val, "Circle"))      config.shape = .Circle
            else if (std.mem.eql(u8, val, "Rect"))   config.shape = .Rect
            else if (std.mem.eql(u8, val, "All"))    config.shape = .All
            else return error.InvalidArg;
        }
        else return error.InvalidArg;
    }

    return config;
}

fn convertArg(comptime T: type, arg: []const u8, startsWith: []const u8) !?T {
    if (!std.mem.startsWith(u8, arg, startsWith)) return null;
    const str = std.mem.trimStart(u8, arg, startsWith);

    switch (@typeInfo(T)) {
        .int   => return try std.fmt.parseInt(T, str, 10),
        .float => return try std.fmt.parseFloat(T, str),
        else   => {},
    }

    return null;
}

fn printStats(writer: anytype, io: std.Io, config: Config, frames: []const FrameMeteric, profiler: anytype) !void {
    try writer.writeAll("\n\n--- Results ---\n");
    try writer.print("Time: {}\n", .{std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds()});
    try writer.print("Build: {s}\n", .{@tagName(builtin.mode)});
    try writer.print("Config  : {} ents | world {d:.0}x{d:.0} | shape: {s} | timeout: {}s\n", .{
        config.ent_count,
        config.world_w, config.world_h,
        @tagName(config.shape),
        config.timeout,
    });

    if (frames.len == 0) {
        try writer.writeAll("No frames recorded.\n");
        return;
    }

    var total_time: i64 = 0;
    var min_time: i64   = std.math.maxInt(i64);
    var max_time: i64   = 0;
    var total_dist: f32 = 0;
    var min_dist: f32   = std.math.floatMax(f32);
    var max_dist: f32   = 0;

    for (frames) |fm| {
        total_time += fm.frame_time;
        if (fm.frame_time < min_time) min_time = fm.frame_time;
        if (fm.frame_time > max_time) max_time = fm.frame_time;
        total_dist += fm.median_dist;
        if (fm.median_dist < min_dist) min_dist = fm.median_dist;
        if (fm.median_dist > max_dist) max_dist = fm.median_dist;
    }

    const n: i64 = @intCast(frames.len);
    const avg_time = @divTrunc(total_time, n);
    const avg_dist = total_dist / @as(f32, @floatFromInt(frames.len));

    var avg_query: i128 = 0;
    if (profiler.query.items.len > 0) {
        var total: i128 = 0;
        for (profiler.query.items) |t| total += t;
        avg_query = @divTrunc(total, @as(i128, @intCast(profiler.query.items.len)));
    }

    var avg_collision: i128 = 0;
    if (profiler.collision.items.len > 0) {
        var total: i128 = 0;
        for (profiler.collision.items) |t| total += t;
        avg_collision = @divTrunc(total, @as(i128, @intCast(profiler.collision.items.len)));
    }

    var avg_insert: i128 = 0;
    if (profiler.insert.items.len > 0) {
        var total: i128 = 0;
        for (profiler.insert.items) |t| total += t;
        avg_insert = @divTrunc(total, @as(i128, @intCast(profiler.insert.items.len)));
    }

    var avg_cell_max: usize = 0;
    if (profiler.cell_max.items.len > 0) {
        var total: usize = 0;
        for (profiler.cell_max.items) |v| total += v;
        avg_cell_max = total / profiler.cell_max.items.len;
    }

    const pairs_total = profiler.collision.items.len;
    const hit_rate: f64 = if (pairs_total > 0)
        @as(f64, @floatFromInt(profiler.hits)) / @as(f64, @floatFromInt(pairs_total)) * 100.0
    else 0.0;
    const avg_pairs_per_frame: usize = if (frames.len > 0) pairs_total / frames.len else 0;

    try writer.print("Frames  : {}\n",                                        .{frames.len});
    try writer.print("Threads : {}\n",                                        .{THREAD_COUNT});
    try writer.print("Time    : avg {}ms | min {}ms | max {}ms\n",            .{avg_time, min_time, max_time});
    try writer.print("Med dist: avg {d:.1} | min {d:.1} | max {d:.1}\n",     .{avg_dist, min_dist, max_dist});
    try writer.print("Insert  : avg {}ns\n",                                  .{avg_insert});
    try writer.print("Query   : avg {}ns\n",                                  .{avg_query});
    try writer.print("Collide : avg {}ns\n",                                  .{avg_collision});
    try writer.print("Pairs   : avg {}/frame | hits {d:.2}%\n",               .{avg_pairs_per_frame, hit_rate});
    try writer.print("Cell max: avg {} ents\n",                               .{avg_cell_max});
}
