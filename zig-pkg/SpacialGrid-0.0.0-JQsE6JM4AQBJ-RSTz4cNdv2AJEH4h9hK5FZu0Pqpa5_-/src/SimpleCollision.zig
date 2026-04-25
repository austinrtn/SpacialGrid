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
const PointEnt  = struct { id: u32, x: f32, y: f32 };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

}
