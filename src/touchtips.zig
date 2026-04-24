const std = @import("std");

const Io = std.Io;
const Clock = std.Io.Clock;

const ZigGridLib = @import("ZigGridLib").ZigGridLib(.{});
const CollisionDetection = ZigGridLib.CollisionDetection;

const SpacialGrid = ZigGridLib.SpacialGrid;
const CollisionPair = ZigGridLib.CollisionPair;
const ShapeData = SpacialGrid.ShapeData;

const CircleEnt = struct { id: u32, x: f32, y: f32, r: f32 };
const RectEnt   = struct { id: u32, x: f32, y: f32, w: f32, h: f32 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var buf: [1024]u8 = undefined; 
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const writer = &stdout.interface;

    var rects: std.MultiArrayList(RectEnt) = .empty;
    defer rects.deinit(allocator);
    const world_width: usize = 200;

    var i: usize = 0;
    var x: f32 = 0;
    const y: f32 = 10;
    const w: f32 = 10;
    const h: f32 = 10;
    const pad: f32 = 5;

    while(x + pad < world_width) : (i += 1) {
        const rect: RectEnt = .{
            .x = x,
            .y = y, 
            .w = w,
            .h = h,
            .id = @intCast(i), 
        };

        try rects.append(allocator, rect); 
        x += w + pad;
    }

    var grid = try SpacialGrid.init(.{
        .io = io,
        .allocator = allocator,
        .width = 200,
        .height = 200,
        .cell_size_multiplier = 2,
        .multi_threaded = true,
    });
    defer grid.deinit();

    try writer.print("Rects: {}\n", .{rects.items(.id).len});
    try writer.flush();


}
