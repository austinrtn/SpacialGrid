const std = @import("std");
const Io = std.Io;
const Lib = @import("SpacialGrid");
const Vector2 = Lib.Vector2;

const SpacialGrid = Lib.SpacialGrid(4);
const ShapeData = Lib.ShapeData;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var grid: SpacialGrid = try .init(SpacialGrid.Config{
        .allocator = init.gpa,
        .cell_size = 25,
        .ent_count = 4,
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

    try ents.append(allocator, .{
        .pos = .{.x = 25, .y = 25},
        .shape_data = .{ .Circle = 12},
        .id = 0,
    });

    const max_frames: usize = 5000;
    var i: usize = 0;
    while(true) : (i += 1){
        try grid.update(.{
            .positions = ents.items(.pos), .shape_data = ents.items(.shape_data), .indices = ents.items(.id)
        });            

        const results = grid.results.items;
        const found_col = results.len > 0;

        std.debug.print("Frame: {} of {}\n", .{i, max_frames});
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
        if(i == max_frames) break;
    }
}
