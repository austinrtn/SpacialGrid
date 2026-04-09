const std = @import("std");
const Io = std.Io;
const SpacialGrid = @import("SpacialGrid.zig");

pub fn main(init: std.process.Init) !void {
    var grid = try SpacialGrid.SpacialGrid.init(SpacialGrid.Config{
        .allocator = init.gpa,
        .cell_size = 25,
        .ent_count = 50,
        .width = 100,
        .height = 100,
    });
    defer grid.deinit();

    const rect1 = Rect{.x = 25, .y = 25, .width = 25, .height = 25};
    const rect2 = Rect{.x = 50, .y = 50, .width = 25, .height = 25};
}

const Rect = struct{
    x: f32,
    y: f32,
    width: f32,
    height: f32= 25,
};
