const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Clock = std.Io.Clock;

const ZigGridLib = @import("ZigGridLib").ZigGridLib(.{});
const CollisionDetection = ZigGridLib.CollisionDetection;

const SpacialGrid = ZigGridLib.SpacialGrid;
const CollisionPair = ZigGridLib.CollisionPair;
const ShapeData = SpacialGrid.ShapeData;

const CircleEnt = struct { id: u32, x: f32, y: f32, r: f32 };
const RectEnt   = struct { id: u32, x: f32, y: f32, w: f32, h: f32 };
const PointEnt  = struct { id: u32, x: f32, y: f32 };

const Config = struct {
    world_w: f32 = 1000,
    world_h: f32 = 1000,
    timeout: i64 = 5,
    ent_count: usize = 1500,

    min_r: f32 = 4,
    max_r: f32 = 12,

    min_wh: f32 = 4,
    max_wh: f32 = 12,
    shape: enum {Rect, Circle, All} = .All,
    update_stdout: bool = false,
    multi_threaded: bool = false,
    thread_count: ?usize = null,
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
        .width  = config.world_w,
        .height = config.world_h,
        .cell_size_multiplier = 1.2,
        .multi_threaded = true,
        .thread_count = config.thread_count,
        .io = init.io,
    });
    defer grid.deinit();

    var circles: std.MultiArrayList(CircleEnt) = .empty;
    var rects:   std.MultiArrayList(RectEnt)   = .empty;
    var points:  std.MultiArrayList(PointEnt)  = .empty;
    defer circles.deinit(allocator);
    defer rects.deinit(allocator);
    defer points.deinit(allocator);

    try circles.ensureTotalCapacity(allocator, config.ent_count);
    try rects.ensureTotalCapacity(allocator, config.ent_count);
    try points.ensureTotalCapacity(allocator, config.ent_count);
    try grid.ensureCapacity(config.ent_count, .Circle);
    try grid.ensureCapacity(config.ent_count, .Rect);
    try grid.ensureCapacity(config.ent_count, .Point);
    
    var prng = getPrng(init.io);
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
    // UPDATE LOOP
    while(true) : (i += 1){
        if(config.update_stdout and i > 0) {
            const last_frame = frames.items[i - 1];
            const elapsed = start.durationTo(Clock.Timestamp.now(init.io, .awake));
            try writer.print("Frame: {} | FrameTime: {} | Elapsed: {}\r", 
                .{ last_frame.frame, last_frame.frame_time, elapsed.raw.toSeconds()}
            );
            try writer.flush();
        }

        try generateCircles(allocator, &circles, &prng, config, 0);
        try generateRects(allocator, &rects, &prng, config, @intCast(circles.len));
        try generatePoints(allocator, &points, &prng, config, @intCast(circles.len + rects.len));

        const start_query = Clock.Timestamp.now(init.io, .awake);

        if (config.naive) {
            try naiveCollisions(allocator, &circles, &rects, &points);
        } else {
            try grid.insertCircles(circles.items(.id), circles.items(.x), circles.items(.y), circles.items(.r));
            try grid.insertRects(rects.items(.id), rects.items(.x), rects.items(.y), rects.items(.w), rects.items(.h));
            try grid.insertPoints(points.items(.id), points.items(.x), points.items(.y));
            try grid.updateCellSize(null);
            _ = try grid.update();
        }

        const end_query = start_query.durationTo(Clock.Timestamp.now(init.io, .awake));

        var frame = FrameMeteric{
            .frame = i,
            .frame_time = end_query.raw.toMilliseconds(),
        };
        try frame.setMedianDistance(
            allocator, &prng, circles.items(.x), circles.items(.y), circles.items(.id)
        );
        try frames.append(allocator, frame); 

        const elapsed = start.durationTo(Clock.Timestamp.now(init.io, .awake));

        if(elapsed.raw.toSeconds() >= config.timeout) break;
    }

    try printStats(writer, init.io, config, frames.items, &profiler);
    try writer.flush();
}

fn generateCircles(allocator: std.mem.Allocator, list: *std.MultiArrayList(CircleEnt), prng: *std.Random.DefaultPrng, config: Config, id_offset: u32) !void {
    const rand = prng.random();
    list.clearRetainingCapacity();
    if (config.shape == .Rect) return;
    const count = if (config.shape == .All) config.ent_count / 3 else config.ent_count;
    for (0..count) |i| {
        try list.append(allocator, .{
            .id = id_offset + @as(u32, @intCast(i)),
            .x  = rand.float(f32) * config.world_w,
            .y  = rand.float(f32) * config.world_h,
            .r  = rand.float(f32) * (config.max_r - config.min_r) + config.min_r,
        });
    }
}

fn generateRects(allocator: std.mem.Allocator, list: *std.MultiArrayList(RectEnt), prng: *std.Random.DefaultPrng, config: Config, id_offset: u32) !void {
    const rand = prng.random();
    list.clearRetainingCapacity();
    if (config.shape == .Circle) return;
    const count = if (config.shape == .All) config.ent_count / 3 else config.ent_count;
    for (0..count) |i| {
        try list.append(allocator, .{
            .id = id_offset + @as(u32, @intCast(i)),
            .x  = rand.float(f32) * config.world_w,
            .y  = rand.float(f32) * config.world_h,
            .w  = rand.float(f32) * (config.max_wh - config.min_wh) + config.min_wh,
            .h  = rand.float(f32) * (config.max_wh - config.min_wh) + config.min_wh,
        });
    }
}

fn generatePoints(allocator: std.mem.Allocator, list: *std.MultiArrayList(PointEnt), prng: *std.Random.DefaultPrng, config: Config, id_offset: u32) !void {
    const rand = prng.random();
    list.clearRetainingCapacity();
    const count = if (config.shape == .All) config.ent_count / 3 else 0;
    for (0..count) |i| {
        try list.append(allocator, .{
            .id = id_offset + @as(u32, @intCast(i)),
            .x  = rand.float(f32) * config.world_w,
            .y  = rand.float(f32) * config.world_h,
        });
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Config {
    var config: Config = .{};
    var iter = try args.iterateAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    while(iter.next()) |arg| {  
        // World and Shape dimensions 
        if(try convertArg(f32, arg, "world_w=")) |result| config.world_w = result
        else if(try convertArg(f32, arg, "world_h=")) |result| config.world_h = result

        // Circle
        else if(try convertArg(f32, arg, "min_r=")) |result| config.min_r = result
        else if(try convertArg(f32, arg, "max_r=")) |result| config.max_r = result

        // Rect
        else if(try convertArg(f32, arg, "min_wh=")) |result| config.min_wh = result
        else if(try convertArg(f32, arg, "max_wh=")) |result| config.max_wh = result

        // Entity Count 
        else if(try convertArg(usize, arg, "count=")) |result| config.ent_count = result 
        // Time before simulation ends in seconds
        else if(try convertArg(i64, arg, "timeout=")) |result| config.timeout = result

        // Set multi_threaded 
        else if(try convertArg(usize, arg, "m_threaded=")) |result| {
            if(result == 0) config.multi_threaded = false
            else if(result == 1) config.multi_threaded = true  
            else unreachable;
        }
        // Number of threads to be used
        else if(try convertArg(usize, arg, "threads=")) |result| {
            config.thread_count = result;
            config.multi_threaded = true;
        }

        // If output should print to STDOUT
        else if(try convertArg(usize, arg, "update=")) |result| {
            if(result == 0) config.update_stdout = false
            else if(result == 1) config.update_stdout = true
            else unreachable;
        }

        // Run ent-per-ent collision detection (no spacial grid)
        else if(try convertArg(usize, arg, "naive=")) |result| {
            config.naive = result != 0;
        }

        // Choose which shapes to generate 
        else if(std.mem.startsWith(u8, arg, "shape=")) {
            const val = arg["shape=".len..];
            if(std.mem.eql(u8, val, "Circle"))config.shape = .Circle
            else if(std.mem.eql(u8, val, "Rect"))config.shape = .Rect
            else if(std.mem.eql(u8, val, "All")) config.shape = .All
            else return error.InvalidArg;
        }

        else return error.InvalidArg;
    }

    return config;
}

fn convertArg(comptime T: type, arg: []const u8, startsWith: []const u8) !?T {
    if(!std.mem.startsWith(u8, arg, startsWith)) return null;
    const str = std.mem.trimStart(u8, arg, startsWith);

    switch(@typeInfo(T)) {
        .int => return try std.fmt.parseInt(T, str, 10),
        .float => return try std.fmt.parseFloat(T, str),
        else => {},   
    }

    return null;
} 

const AnyEnt = struct { id: u32, x: f32, y: f32, shape: ShapeData };

fn naiveCollisions(
    allocator: std.mem.Allocator,
    circles: *std.MultiArrayList(CircleEnt),
    rects:   *std.MultiArrayList(RectEnt),
    points:  *std.MultiArrayList(PointEnt),
) !void {
    var ents: std.ArrayList(AnyEnt) = .empty;
    defer ents.deinit(allocator);

    for (0..circles.len) |i| {
        const s = circles.get(i);
        try ents.append(allocator, .{ .id = s.id, .x = s.x, .y = s.y, .shape = .{ .Circle = s.r } });
    }
    for (0..rects.len) |i| {
        const s = rects.get(i);
        try ents.append(allocator, .{ .id = s.id, .x = s.x, .y = s.y, .shape = .{ .Rect = .{ .x = s.w, .y = s.h } } });
    }
    for (0..points.len) |i| {
        const s = points.get(i);
        try ents.append(allocator, .{ .id = s.id, .x = s.x, .y = s.y, .shape = .Point });
    }

    var results: std.ArrayList(CollisionPair) = .empty;
    defer results.deinit(allocator);

    const CD = CollisionDetection;
    for (0..ents.items.len) |i| {
        for (i + 1..ents.items.len) |j| {
            const a = ents.items[i];
            const b = ents.items[j];
            if (CD.checkColliding(a.x, a.y, a.shape, b.x, b.y, b.shape)) {
                try results.append(allocator, .{ .a = a.id, .b = b.id });
            }
        }
    }
}
const FrameMeteric = struct {
    frame: usize = 0,
    frame_time: i64 = 0,
    median_dist: f32 = 0,

    fn setMedianDistance(
        self: *FrameMeteric,
        allocator: std.mem.Allocator,
        prng: *std.Random.DefaultPrng,
        xs: []f32,
        ys: []f32,
        ids: []u32,
    ) !void {
        const sample_size: usize = 1000;
        const rand = prng.random();

        var dists: std.ArrayList(f32) = .empty;
        defer dists.deinit(allocator);

        for(0..sample_size) |_| {
                const ia = rand.intRangeAtMost(usize, 0, ids.len - 1);
                const ib = rand.intRangeAtMost(usize, 0, ids.len - 1);
                if(ia >= ib) continue;

                const dx = xs[ia] - xs[ib];
                const dy = ys[ia] - ys[ib];
                const dist: f32 = @sqrt(dx * dx + dy * dy);
                try dists.append(allocator, dist);
        }

        std.mem.sort(f32, dists.items, {}, std.sort.asc(f32));
        self.median_dist = dists.items[@as(usize, @divTrunc(dists.items.len, 2))];
    } 
};

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

    const thread_count = blk: {
        if(!config.multi_threaded) break :blk 1;
        break :blk config.thread_count orelse try std.Thread.getCpuCount();
    };

    try writer.print("Frames  : {}\n",                                          .{frames.len});
    try writer.print("Threads : {}\n",                                          .{thread_count});
    try writer.print("Time    : avg {}ms | min {}ms | max {}ms\n",              .{avg_time, min_time, max_time});
    try writer.print("Med dist: avg {d:.1} | min {d:.1} | max {d:.1}\n",       .{avg_dist, min_dist, max_dist});
    try writer.print("Insert  : avg {}ns\n",                                    .{avg_insert});
    try writer.print("Query   : avg {}ns\n",                                    .{avg_query});
    try writer.print("Collide : avg {}ns\n",                                    .{avg_collision});
    try writer.print("Pairs   : avg {}/frame | hits {d:.2}%\n",                 .{avg_pairs_per_frame, hit_rate});
    try writer.print("Cell max: avg {} ents\n",                                 .{avg_cell_max});
}

pub fn getPrng(io: std.Io) std.Random.DefaultPrng {
    var seed: u64 = undefined; 
    io.random(std.mem.asBytes(&seed));
    return .init(seed);
}
