const std = @import("std");
const ShapeType = @import("SpacialGrid.zig").ShapeType;

pub const Entity = struct {
    shape: ShapeType,
    x: f32, 
    y: f32,

    w: f32 = 0.0,
    h: f32 = 0.0,
    r: f32 = 0.0,

    pub fn init(x: f32, y: f32, shape: ShapeType, shape_data: anytype) !Entity {
        const w: ?f32 = if(@hasField(@TypeOf(shape_data), "w")) shape_data.w else null;
        const h: ?f32 = if(@hasField(@TypeOf(shape_data), "h")) shape_data.h else null;
        const r: ?f32 = if(@hasField(@TypeOf(shape_data), "r")) shape_data.r else null;

        if(shape == .Rect and (w == null or h == null)) {
            std.log.err("Type of shape_data must contain fields \"w\" and \"h\" when shape parameter is .Rect\n", .{});
            return error.InvalidShapeDataFields;
        }
        else if(shape == .Circle and r == null) {
            std.log.err("Type of shape_data must contain field \"r\" when shape parameter is .Circle\n", .{});
            return error.InvalidShapeDataFields;
        }

        return switch (shape) {
            .Point => .{.x = x, .y = y, .shape = shape, },
            .Rect => .{.x = x, .y = y, .shape = shape, .w = w.?, .h = h.? },
            .Circle => .{.x = x, .y = y, .shape = shape, .r = r.? },
        };
    }
};
