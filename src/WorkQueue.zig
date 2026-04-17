const std = @import("std");

pub const WorkQueue = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    row_idx: usize = 0,
    col_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) WorkQueue {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn getNextCellChunk(self: *WorkQueue, grid: anytype) !?[]u32 {
        try self.mu.lock(self.io);
        defer self.mu.unlock(self.io);

        if(self.col_idx == grid.impl.cols) return null;

        const cell_idx = grid.impl.getCellIndex(@intCast(self.row_idx), @intCast(self.col_idx)) catch unreachable;
        const ents = grid.impl.getEntsFromCell(cell_idx);

        if(self.row_idx == grid.impl.rows - 1) {
            self.col_idx += 1;
            self.row_idx = 0;
        }
        else self.row_idx += 1;

        return ents;
    }

    pub fn reset(self: *WorkQueue) void {
        self.row_idx = 0;
        self.col_idx = 0;
    }
};
