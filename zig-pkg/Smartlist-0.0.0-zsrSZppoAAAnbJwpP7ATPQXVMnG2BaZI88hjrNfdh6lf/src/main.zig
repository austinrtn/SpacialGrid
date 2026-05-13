const std = @import("std");
const Io = std.Io;
const SmartSoA = @import("SmartSoA.zig").SmartSoA;
const Point = struct {x: f32, y: f32};

/// A performance test between the SmartSoa
/// data structure and Zig's own std.Multiarraylist.
/// Whats being measured:
/// - Time spent appending data to data structures,
/// - Time spent getting data from data structures
/// - Time spent looping through and manipulating data from data structures
///
/// Results:
///   The test consistently showed a negilible but measurable
///   difference between both the time spent appending and
///   time spent manipuluating data, with a slight edge to
///   the MultiArraylist when appending data, but a slight edge
///   to the SmartSoA when manipulating data through the hot-loop.

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const writer = &stdout.interface;

    var mal_timestamp: Timestamps = .init(io);
    var smart_timestamp: Timestamps = .init(io);

    const P_Count = 1_000_000;
    const frame_count = 10_000;
    const max_x = 100_000.0;
    const max_y = 100_000.0;
    const max_vel = 100;

    const Particle = struct {
        x: f32,
        y: f32,
        x_vel: f32,
        y_vel: f32,
    };

    try writer.writeAll("Generating Particles...\n");
    try writer.flush();
    const base_particles = try allocator.alloc(Particle, P_Count);
    defer allocator.free(base_particles);

    const src = std.Random.IoSource{.io = io};
    const rand = src.interface();

    for(base_particles) |*p| {
        p.* = .{
            .x = rand.float(f32) * max_x,
            .y = rand.float(f32) * max_y,
            .x_vel = rand.float(f32) * max_vel,
            .y_vel = rand.float(f32) * max_vel,
        };
    }

    const mal_particles = try allocator.dupe(Particle, base_particles);
    defer allocator.free(mal_particles);
    const smart_particles = try allocator.dupe(Particle, base_particles);
    defer allocator.free(smart_particles);

    var mal_list: std.MultiArrayList(Particle) = .empty;
    defer mal_list.deinit(allocator);

    var smart_list: SmartSoA(Particle) = .init();
    defer smart_list.deinit(allocator);

    try writer.writeAll("Particles generated, Testing MultiArraylist\n");
    try writer.writeAll("Appending Particles...\n");
    try writer.flush();
    mal_timestamp.append.start();

    try mal_list.ensureTotalCapacity(allocator, P_Count);
    for(mal_particles) |p| {
        try mal_list.append(allocator, p);
    }

    mal_timestamp.append.end();

    try writer.writeAll("Getting Slices...\n");
    try writer.flush();

    mal_timestamp.get_slices.start();

    const mal_slice = mal_list.slice();
    const xs = mal_slice.items(.x);
    const ys = mal_slice.items(.y);
    const x_vels = mal_slice.items(.x_vel);
    const y_vels = mal_slice.items(.y_vel);

    mal_timestamp.get_slices.end();

    try writer.writeAll("Manipulating data...\n");
    try writer.flush();

    mal_timestamp.manipulate.start();
    for (0..frame_count) |_| {
        for(xs, ys, x_vels, y_vels) |*x, *y, x_vel, y_vel| {
            x.* += x_vel;
            y.* += y_vel;
        }
    }
    mal_timestamp.manipulate.end();

    try writer.writeAll("\nTesting SmartSoA...\n");
    try writer.writeAll("Appending Particles...\n");
    try writer.flush();

    smart_timestamp.append.start();

    try smart_list.ensureTotalCapacity(allocator, P_Count);
    for(smart_particles) |p| {
        try smart_list.append(allocator, p);
    }

    smart_timestamp.append.end();

    try writer.writeAll("Getting slices via manyItems...\n");
    try writer.flush();

    smart_timestamp.get_slices.start();

    const smart_items = smart_list.manyItems(&.{ .x, .y, .x_vel, .y_vel });

    smart_timestamp.get_slices.end();

    try writer.writeAll("Manipulating data...\n");
    try writer.flush();

    smart_timestamp.manipulate.start();
    for (0..frame_count) |_| {
        for(smart_items.x, smart_items.y, smart_items.x_vel, smart_items.y_vel) |*x, *y, x_vel, y_vel| {
            x.* += x_vel;
            y.* += y_vel;
        }
    }
    smart_timestamp.manipulate.end();

    for (xs, ys, smart_items.x, smart_items.y) |mal_x, mal_y, smart_x, smart_y| {
        try std.testing.expectEqual(mal_x, smart_x);
        try std.testing.expectEqual(mal_y, smart_y);
    }

    try writer.writeAll("\nComparison\n");
    try printTiming(writer, "MultiArrayList", mal_timestamp);
    try printTiming(writer, "SmartSoA", smart_timestamp);
    try writer.writeAll("\nRatios (SmartSoA / MultiArrayList)\n");
    try printRatio(writer, "append", smart_timestamp.append.end_time, mal_timestamp.append.end_time);
    try printRatio(writer, "get slices", smart_timestamp.get_slices.end_time, mal_timestamp.get_slices.end_time);
    try printRatio(writer, "manipulate", smart_timestamp.manipulate.end_time, mal_timestamp.manipulate.end_time);
    try writer.flush();
}

test "items" {
    const allocator = std.testing.allocator;
    var list = SmartSoA(Point).init();
    defer list.deinit(allocator);

    const point: Point = .{.x = 1.5, .y = 0};

    try list.append(allocator, point);
    const items = list.manyItems(&.{.x, .y});

    for(items.x, items.y) |*x, *y| {
        x.* += 1;
        y.* += 1;
    }

    for(items.x, items.y) |x, y| {
        try std.testing.expectEqual(point.x, x - 1);
        try std.testing.expectEqual(point.y, y - 1);
    }
}

test "allItems" {
    const allocator = std.testing.allocator;

    var list = SmartSoA(struct{int: usize, str: []const u8}).init();
    defer list.deinit(allocator);

    for(0..10) |i| {
        try list.append(allocator, .{.int = i, .str = "hello"});
    }

    const items = list.allItems();
    for(items.int, items.str, 0..) |int, str, i| {
        try std.testing.expectEqual(int, i);
        try std.testing.expectEqual(str, "hello");
    }
}

test "many_appends" {
    const point_count = 1_000_000;
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(@intCast(std.testing.random_seed));
    const random = prng.random();

    var list = SmartSoA(Point).init();
    defer list.deinit(allocator);

    for(0..point_count) |_| {
        const x: f32 = random.float(f32) * 100_000;
        const y: f32 = random.float(f32) * 100_000;
        try list.append(allocator, .{.x = x, .y = y});
    }

    try std.testing.expectEqual(list.len, point_count);
}

test "set" {
    const allocator = std.testing.allocator;

    var list = SmartSoA(struct{int: usize}).init();
    defer list.deinit(allocator);

    for(0..5) |i| {
        try list.append(allocator, .{.int = i});
    }

    for(5..10) |i| {
        list.set(.{.int = i}, i - 5);
    }

    for(0..5) |i| {
        const T = list.get(i);
        try std.testing.expectEqual(i + 5, T.int);
    }
}

test "insert" {
    const allocator = std.testing.allocator;

    var list = SmartSoA(struct{int: usize}).init();
    defer list.deinit(allocator);

    for(0..5) |i| {
        try list.append(allocator, .{.int = i});
    }

    const new_int: @TypeOf(list).Child = .{.int =69};
    try list.insert(allocator, new_int, 3);

    const ints = list.items(.int);

    try std.testing.expectEqual(list.len, 6);
    try std.testing.expectEqual(ints[3], 69);
}

test "clear" {
    const allocator = std.testing.allocator;

    var list: SmartSoA(struct{int: usize}) = .init();
    defer list.deinit(allocator);

    try list.append(allocator, .{.int = 5});
    try std.testing.expectEqual(list.len, 1);
    try std.testing.expect(list.capacity > 0);

    list.clearRetainingCapacity();
    try std.testing.expectEqual(list.len, 0);
    try std.testing.expect(list.capacity > 0);

    list.clearAndFree(allocator);
    try std.testing.expectEqual(list.len, 0);
    try std.testing.expectEqual(list.capacity, 0);
}

test "pop_remove" {
    const allocator = std.testing.allocator;

    var list: SmartSoA(struct{int: usize}) = .init();
    defer list.deinit(allocator);

    for(0..10) |i| {
        try list.append(allocator, .{.int = i});
    }

    const swapped = list.swapAndPop(0);
    try std.testing.expectEqual(swapped.?.int, 0);
    try std.testing.expectEqual(list.len, 9);

    const popped = list.pop();

    try std.testing.expectEqual(popped.?.int, 8);
    try std.testing.expectEqual(list.len, 8);
}

test "orderedRemove" {
    const allocator = std.testing.allocator;

    var list: SmartSoA(struct{int: usize}) = .init();
    defer list.deinit(allocator);

    for(0..5) |i| {
        try list.append(allocator, .{.int = i});
    }

    var ints = list.items(.int);

    try std.testing.expectEqual(5, list.len);
    try std.testing.expectEqual(ints[3], 3);

    list.orderedRemove(3);
    ints = list.items(.int);

    try std.testing.expectEqual(4, list.len);
    try std.testing.expectEqual(ints[3], 4);
}

test "orderedRemoveMany" {
    const allocator = std.testing.allocator;

    var list: SmartSoA(struct{int: usize}) = .init();
    defer list.deinit(allocator);

    for(0..20) |i| {
        try list.append(allocator, .{.int = i});
    }

    var ints = list.items(.int);
    try std.testing.expectEqual(ints.len, 20);
    try std.testing.expectEqual(ints[10], 10);
    try std.testing.expectEqual(ints[15], 15);

    list.orderedRemoveMany(10, 15);
    ints = list.items(.int);

    try std.testing.expectEqual(ints.len, 14);
    try std.testing.expectEqual(ints[10], 16);
    try std.testing.expectEqual(ints[13], 19);
}

const Time = struct {
    const Self = @This();
    const Timestamp = std.Io.Clock.Timestamp;

    io: std.Io = undefined,
    start_time: Timestamp = undefined,
    end_time: i64 = 0,

    fn start(self: *Self) void {
        self.start_time = .now(self.io, .awake);
    }

    fn end(self: *Self) void {
        self.end_time = self.start_time.durationTo(.now(self.io, .awake)).raw.toMicroseconds();
    }
};

const Timestamps = struct {
    append: Time = .{},
    get_slices: Time = .{},
    manipulate: Time = .{},

    fn init(io: std.Io) Timestamps {
        var ts: Timestamps = .{};
        inline for(std.meta.fields(@This())) |field| {
            const time = &@field(ts, field.name);
            time.io = io;
        }

        return ts;
    }
};

fn printTiming(writer: *std.Io.Writer, label: []const u8, ts: Timestamps) !void {
    try writer.print(
        "{s}: append={}us, get_slices={}us, manipulate={}us\n",
        .{ label, ts.append.end_time, ts.get_slices.end_time, ts.manipulate.end_time },
    );
}

fn printRatio(writer: *std.Io.Writer, label: []const u8, lhs: i64, rhs: i64) !void {
    const ratio = if (rhs == 0) 0.0 else @as(f64, @floatFromInt(lhs)) / @as(f64, @floatFromInt(rhs));
    try writer.print("{s}: {d:.3}x\n", .{ label, ratio });
}
