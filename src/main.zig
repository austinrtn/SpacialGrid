const std = @import("std");
const Io = std.Io;
const SG = @import("SpacialGrid.zig");
const Vector2 = SG.Vector2;

const SpacialGrid = SG.SpacialGrid(1);
const ShapeData = SG.ShapeData;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var grid: SpacialGrid = try .init(SpacialGrid.Config{
        .allocator = init.gpa,
        .cell_size = 25,
        .ent_count = 50,
        .width = 100,
        .height = 100,
    });
    defer grid.deinit();

    var ents: std.MultiArrayList(struct {
        pos: Vector2,
        shape_data: ShapeData,
        id: usize,
    }) = .empty;
    defer ents.deinit(allocator);

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

    while(true) {
        const results = try grid.update(.{.positions = ents.items(.pos), .shape_data = ents.items(.shape_data), .indecies = ents.items(.id)});            
        const found_col = results.len > 0;
        for(results) |pair| {
            std.debug.print("{any}\n", .{pair});
        }
        if(!found_col) std.debug.print("No col\r", .{});
    }
}
