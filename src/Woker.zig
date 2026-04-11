const std = @import("std");
const SpacialGrid = @import("SpacialGrid.zig").SpacialGrid;
const Setup = @import("SpacialGrid.zig").SpacialGridSetup;
const CollisionPair = @import("SpacialGrid.zig").CollisionPair;

pub fn Worker(comptime setup: Setup) type {
    const Grid = SpacialGrid(setup);
    const Vec2 = setup.Vector2;
    const Shape = Grid.ShapeData;

    return struct {
        const Self = @This();
        work_semaphore: std.Io.Semaphore = .{},
        done_semaphore: std.Io.Semaphore = .{},
        shutdown: std.atomic.Value(bool) = .init(false),

        allocator: std.mem.Allocator,
        io: std.Io, 
        grid: *Grid = undefined,
        thread: std.Thread = undefined,

        chunk: []usize = undefined, 
        positions: []Vec2 = undefined,
        shape_data: []Shape = undefined,
        col_list: std.ArrayList(CollisionPair) = .empty,
        query_buf: []usize = undefined, 

        pub fn init(grid: *Grid, buf_capacity: usize) !Self {
            var self = Self{ 
                .allocator = grid.impl.allocator, 
                .io = grid.impl.io,
                .grid = grid, 
            };
            self.query_buf = try self.allocator.alloc(usize, buf_capacity);

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.shutdown.store(true, .release);
            self.work_semaphore.post(self.io);
            self.thread.join();

            self.col_list.deinit(self.allocator);
            self.allocator.free(self.query_buf);
        }
        
        pub fn spawn(self: *Self) !void {
            self.thread = try .spawn(
                .{.allocator = self.allocator},  
                Self.work,
                .{ self}
            );
        }

        pub fn set(self: *Self, chunk: []usize, positions: []Vec2, shape_data: []Shape) void {
            self.chunk = chunk;
            self.positions = positions;
            self.shape_data = shape_data;
        }

        pub fn work(self: *Self) void {
            while(true){
                self.work_semaphore.wait(self.io) catch break;
                if(self.shutdown.load(.acquire)) break;
                Grid.findCollisions(
                    self.grid, self.chunk, self.positions, 
                    self.shape_data, &self.col_list, self.query_buf
                );

                self.done_semaphore.post(self.io);
            }
        }
    };
}
