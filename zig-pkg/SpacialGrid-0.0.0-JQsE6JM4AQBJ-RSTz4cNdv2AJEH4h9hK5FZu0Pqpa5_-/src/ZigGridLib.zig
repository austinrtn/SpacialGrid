const std = @import("std");
const SpacialGridMod = @import("SpacialGrid.zig");
const ShapeTypeMod = @import("ShapeType.zig").ShapeType;
const CollisionDetectionMod = @import("CollisionDetection.zig").CollisionDetection;
const Vector2 = @import("Vector2.zig").Vector2;

const SpacialGridT = SpacialGridMod.SpacialGrid;

pub const Setup = struct{Vector2: type = Vector2 };
pub fn ZigGridLib(comptime setup: Setup) type {
    return struct {
        pub const ZigGridLibSetup = Setup;
        pub const SpacialGrid = SpacialGridT(setup); 
        pub const ShapeType = ShapeTypeMod.ShapeType;
        pub const ShapeData = ShapeTypeMod.ShapeData(setup.Vector2);
        pub const CollisionPair = SpacialGridMod.CollisionPair;
        pub const CollisionData = SpacialGridMod.CollisionData(setup.Vector2);
        pub const CollisionDetection = CollisionDetectionMod(setup.Vector2);
        pub const Vector2 = setup.Vector2;
    };
}
