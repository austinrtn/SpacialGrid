const std = @import("std");
const Io = std.Io;

const SG = @import("SpacialGrid.zig");

pub const Vector2 = @import("Vector2.zig").Vector2;
pub const CollisionDetection = @import("CollisionDetection.zig").CollisionDetection;
pub const SpacialGrid = SG.SpacialGrid;
pub const ShapeData = SG.ShapeData;
pub const CollisionPair = SG.CollisionPair;

pub fn getPrng(io: std.Io) std.Random.DefaultPrng {
    var seed: u64 = undefined; 
    io.random(std.mem.asBytes(&seed));
    return .init(seed);
}
