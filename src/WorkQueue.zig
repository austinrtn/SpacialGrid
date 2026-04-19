const std = @import("std");

pub const WorkItem = struct {
    pub const Kernel = enum {cc, cr, cp, rr, rp, pp};
    kernel: Kernel,
    indicies: []u32,

    fn init(kernel: Kernel, indicies: []u32) WorkItem {
        return .{
            .kernel = kernel,
            .indicies = indicies,
        };
    }
};

pub const WorkQueue = struct {
    allocator: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    work: std.ArrayList(WorkItem) = .empty,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) WorkQueue {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *WorkQueue) void {
        self.work.deinit(self.allocator);
    }

    pub fn reset(self: *WorkQueue) void {
        self.work.clearRetainingCapacity();
        self.index = 0;
    }

    pub fn getNextWorkItem(self: *WorkQueue) !?WorkItem{
        try self.mu.lock(self.io);
        defer self.mu.unlock(self.io);

        if(self.index >= self.work.items.len) return null; 
        defer self.index +=1;

        return self.work.items[self.index];
    }
};
