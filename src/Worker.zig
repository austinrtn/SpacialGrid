const std = @import("std");
const SpacialGrid = @import("SpacialGrid.zig").SpacialGrid;
const Setup = @import("ZigGridLib.zig").Setup;
const CollisionPair = @import("SpacialGrid.zig").CollisionPair;

pub fn Worker(comptime setup: Setup) type {
    const Grid = SpacialGrid(setup);

    return struct {
        const Self = @This();
        work_semaphore: std.Io.Semaphore = .{},
        done_semaphore: std.Io.Semaphore = .{},
        shutdown: std.atomic.Value(bool) = .init(false),

        allocator: std.mem.Allocator,
        io: std.Io,
        grid: *Grid = undefined,
        thread: std.Thread = undefined,

        col_list: std.ArrayList(CollisionPair) = .empty,
        query_buf: []u32 = undefined,

        pub fn init(grid: *Grid, buf_capacity: usize) !Self {
            var self = Self{
                .allocator = grid.impl.allocator,
                .io = grid.impl.io,
                .grid = grid,
            };
            self.query_buf = try self.allocator.alloc(u32, buf_capacity);
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
                .{self}
            );
        }

        pub fn work(self: *Self) void {
            while(true){
                self.work_semaphore.wait(self.io) catch break;
                if(self.shutdown.load(.acquire)) break;

                const queue = &self.grid.impl.work_queue;
                while(
                    queue.getNextWorkItem(true)
                    catch @panic("Mutex Cancled Error in WorkerQueue.zig\n")
                ) |item| 

                    self.grid.impl.findCollisions(self.grid, item, self.query_buf, &self.col_list);
                    self.done_semaphore.post(self.io);
            }
        }
    };
}
