const std = @import("std");

const SG = @import("SpacialGrid.zig");

pub const CollisionDetection = @import("CollisionDetection.zig").CollisionDetection;
pub const SpacialGrid = SG.SpacialGrid;
pub const ShapeType = SG.ShapeType;
pub const CollisionData = SG.CollisionData;
pub const CollisionPair = SG.CollisionPair;
pub const Entity = @import("Entity.zig").Entity;

pub fn getPrng(io: std.Io) std.Random.DefaultPrng {
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    return .init(seed);
}
