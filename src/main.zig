const std = @import("std");
const Io = std.Io;
const Lib = @import("SpacialGrid");

const SpacialGrid = Lib.SpacialGrid(.{.thread_count = 4});
const Vector2 = SpacialGrid.Vector2;
const ShapeData = SpacialGrid.ShapeData;
const Entity = SpacialGrid.Entity;

const Config = struct {
    world_w: f32 = 1000, 
    world_h: f32 = 1000,
    max_frames: usize = 5000,
    ent_count: usize = 100,
    shape: enum {Rect, Circle, All} = .All,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const config = try parseArgs(allocator, init.minimal.args);

    var grid: *SpacialGrid = try .init(SpacialGrid.Config{
        .allocator = init.gpa,
        .ent_count = config.ent_count,
        .width = config.world_w,
        .height = config.world_h,
        .io = init.io,
    });
    defer grid.deinit();

    var ents: std.MultiArrayList(Entity) = .empty;
    defer ents.deinit(allocator);
    try ents.ensureTotalCapacity(allocator, config.ent_count);

    for(0..config.ent_count) |i| {
        const pos = blk: {
            
        };
        try ents.append(allocator, .{
            .pos
        });
    }

    var i: usize = 0;
    while(true) : (i += 1){
        try grid.update(.{
            .positions = ents.items(.pos), 
            .shape_data = ents.items(.shape_data), 
            .indices = ents.items(.id)
        });            

        const results = grid.results.items;
        const found_col = results.len > 0;

        std.debug.print("Frame: {} of {}\n", .{i, config.max_frames});
        for(results) |pair| {
            std.debug.print("{any}\n", .{pair});
        }
        if(!found_col) std.debug.print("No col\r", .{});
        if(i == 500) {
            try ents.append(allocator, .{
                .pos = .{.x = 25, .y = 25},
                .shape_data = .{ .Circle = 12},
                .id = 0,
            });

            try ents.append(allocator, .{
                .pos = .{.x = 20, .y = 20},
                .shape_data = .{ .Rect =  .{.x = 10, .y = 15}},
                .id = 1,
            });
        }
        if(i == config.max_frames) break;
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: std.process.Args) !Config {
    var config: Config = .{};
    var iter = try args.iterateAllocator(allocator);
    defer iter.deinit();
    _ = iter.next();

    while(iter.next()) |arg| {  
        if(try convertArg(f32, arg, "world_w=")) |result| config.world_w = result
        else if(try convertArg(f32, arg, "world_h=")) |result| config.world_h = result
        else if(try convertArg(usize, arg, "count=")) |result| config.ent_count = result
        else if(try convertArg(usize, arg, "m_frame=")) |result| config.max_frames = result
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
