const std = @import("std");

pub const WorkItem = struct {
    pub const Kernel = enum {cc, cr, cp, rr, rc, rp, pp, pc, pr};
    kernel: Kernel,
    start: usize,
    end: usize,

    pub fn init(kernel: Kernel, start: usize, end: usize) WorkItem {
        return .{
            .kernel = kernel,
            .start = start,
            .end = end,
        };
    }
};

pub const WorkQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
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

    pub fn appendWork(self: *WorkQueue, work: WorkItem) !void {
        try self.work.append(self.allocator, work); 
    }

    pub fn getNextWorkItem(self: *WorkQueue, m_threaded: bool) !?WorkItem{
        if(m_threaded) {
            try self.mu.lock(self.io);
            defer self.mu.unlock(self.io);
            if(self.index >= self.work.items.len) return null; 

            const items = self.work.items[self.index];
            self.index += 1;

            return items;
        } else {
            if(self.index >= self.work.items.len) return null; 

            const items = self.work.items[self.index];
            self.index += 1;

            return items;
        }
    }
};
