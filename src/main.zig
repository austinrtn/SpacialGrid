const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Clock = std.Io.Clock;

const ZigGridLib = @import("ZigGridLib").ZigGridLib(.{});
const CollisionDetection = ZigGridLib.CollisionDetection;
const SpacialGrid = ZigGridLib.SpacialGrid;
const CollisionPair = ZigGridLib.CollisionPair;
const Vector2   = ZigGridLib.Vector2;
const ShapeData = SpacialGrid.ShapeData;
const Entity    = SpacialGrid.Entity;

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
        .multi_threaded = config.multi_threaded,
        .thread_count = config.thread_count,
        .io = init.io,
    });
    defer grid.deinit();

    var ents: std.MultiArrayList(Entity) = .empty;
    defer ents.deinit(allocator);

    try ents.ensureTotalCapacity(allocator, config.ent_count);
    try grid.ensureCapacity(config.ent_count);

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

        try generateEnts(allocator, &ents, &prng, config);

        try grid.insertMAL(ents);

        const start_query = Clock.Timestamp.now(init.io, .awake);

        if (config.naive) try naiveCollisions(allocator, ents.items(.pos), ents.items(.shape_data), ents.items(.id))
        else {
            try grid.setCellSize();
            try grid.update();
        }

        const end_query = start_query.durationTo
            (Clock.Timestamp.now(init.io, .awake));

        var frame = FrameMeteric{
            .frame = i, 
            .frame_time = end_query.raw.toMilliseconds(),
        };
        try frame.setMedianDistance(
            allocator, &prng, ents.items(.pos), ents.items(.id)
        );
        try frames.append(allocator, frame); 

        const elapsed = start.durationTo(Clock.Timestamp.now(init.io, .awake));

        if(elapsed.raw.toSeconds() >= config.timeout) break;
    }

    try printStats(writer, init.io, config, frames.items, &profiler);
    try writer.flush();
}

fn generateEnts(allocator: std.mem.Allocator, ents: *std.MultiArrayList(Entity), pnrg: *std.Random.DefaultPrng, config: Config) !void {
    const rand = pnrg.random();
    ents.clearRetainingCapacity();

    for(0..config.ent_count) |i| {
        const pos = blk: {
            const x = rand.float(f32) * config.world_w;
            const y = rand.float(f32) * config.world_h;
            break :blk Vector2{.x = x, .y = y};
        };
        const shape_data: ShapeData = blk: {
            var shape: @TypeOf(config.shape) = config.shape;
            if(shape == .All) {
                switch(rand.intRangeAtMost(usize, 0, 1)) {
                    0 => shape = .Circle,
                    1 => shape = .Rect,
                    else => unreachable,
                }
            }
            switch(shape) {
                .Rect => {
                    const w = rand.float(f32) * (config.max_wh - config.min_wh) + config.min_wh;
                    const h = rand.float(f32) * (config.max_wh - config.min_wh) + config.min_wh;
                    break :blk ShapeData{.Rect = .{.x = w, .y = h}};
                },
                .Circle => break :blk ShapeData{ .Circle = (rand.float(f32) * (config.max_r - config.min_r) + config.min_r )},
                else => unreachable,
            }
            unreachable;
        };
        try ents.append(allocator, .{
            .pos = pos,
            .shape_data = shape_data,
            .id = @intCast(i),
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

fn naiveCollisions(allocator: std.mem.Allocator, positions: []Vector2, shape_data: []ShapeData, ids: []u32) !void {
    var results: std.ArrayList(CollisionPair) = .empty;
    defer results.deinit(allocator);

    const CD = CollisionDetection;
    for (0..ids.len) |i| {
        for (i + 1..ids.len) |j| {
            const a = ids[i];
            const b = ids[j];
            if (CD.checkColliding(positions[@intCast(a)], shape_data[@intCast(a)], positions[@intCast(b)], shape_data[@intCast(b)])) {
                try results.append(allocator, .{ .a = a, .b = b });
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
        positions: []Vector2,
        ids: []u32
    )
    !void {
        const sample_size: usize = 1000;
        const rand = prng.random();

        var dists: std.ArrayList(f32) = .empty;
        defer dists.deinit(allocator);

        for(0..sample_size) |_| {
                const id_a = ids[rand.intRangeAtMost(usize, 0, ids.len - 1)];
                const id_b = ids[rand.intRangeAtMost(usize, 0, ids.len - 1)];
                if(id_a >= id_b) continue;
                const pos_a = positions[@intCast(id_a)];
                const pos_b = positions[@intCast(id_b)];

                const dx = pos_a.x - pos_b.x;
                const dy = pos_a.y - pos_b.y;
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
