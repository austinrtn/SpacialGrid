const std = @import("std");
const SpacialGridMod = @import("SpacialGrid.zig");
const Vector2 = @import("Vector2.zig").Vector2;

const SpacialGridT = SpacialGridMod.SpacialGrid;

const Setup = struct{ thread_count: usize = 1, Vector2: type = Vector2 };
pub fn ZigGridLib(comptime setup: Setup) type {
    return struct {
        pub const ZigGridLibSetup = Setup;
        pub const SpacialGrid = SpacialGridT(setup); 
        pub const ShapeType = SpacialGridMod.ShapeType;
        pub const CollisionData = SpacialGridMod.CollisionData(setup.Vector2);
        pub const ShapeData = SpacialGridMod.ShapeData(setup.Vector2);
    };
}
