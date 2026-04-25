const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;
const CollisionPair = @import("SpacialGrid.zig").CollisionPair;

pub fn EntStorage(comptime shape_type: ShapeType) type {
    return struct {
        const Self = @This();
        pub const ShapeDataType = switch (shape_type) {
            .Circle => struct{ radii: []const f32 },
            .Rect => struct{ widths: []const f32, heights: []const f32 },
            else => void,
        };

allocator: std.mem.Allocator,
        inited: bool = false,

        shape: ShapeType = shape_type,
        ent_count: usize = 0,
        capacity: usize = 0,

        indices: []u32 = undefined,  
        counts: []u32 = undefined,  

        ids: []u32 = undefined,
        xs: []f32 = undefined,
        ys: []f32 = undefined,

        shape_data: ShapeDataType = undefined,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var self: Self = .{.allocator = allocator,};
            defer self.inited = true;

            try self.ensureCapacity(0);
            try self.setCounts(0, 0);

            return self; 
        }

        pub fn freeSlices(self: *Self) void {
            const allocator = self.allocator;
            allocator.free(self.indices);
            allocator.free(self.ids);
            allocator.free(self.xs);
            allocator.free(self.ys);

            if (ShapeDataType != void) {
                inline for (std.meta.fields(ShapeDataType)) |field| {
                    allocator.free(@constCast(@field(self.shape_data, field.name)));
                }
            }
        }

        pub fn deinit(self: *Self) void {
            self.freeSlices();
            self.allocator.free(self.counts);
        }

        pub fn reset(self: *Self) void {
            @memset(self.counts, 0);
        }

        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            const allocator = self.allocator;
            self.capacity = new_capacity;
            if(self.inited) self.freeSlices(); 

            self.indices = try allocator.alloc(u32, new_capacity);
            self.ids = try allocator.alloc(u32, new_capacity);
            self.xs = try allocator.alloc(f32, new_capacity);
            self.ys = try allocator.alloc(f32, new_capacity);
            
            if (ShapeDataType != void) {
                inline for (std.meta.fields(ShapeDataType)) |field| {
                    @field(self.shape_data, field.name) = try allocator.alloc(f32, new_capacity);
                }
            }
        }

        pub fn setCounts(self: *Self, rows: usize, cols: usize) !void {
            self.counts = try self.allocator.alloc(u32, rows * cols);
            @memset(self.counts, 0);
        }
        
        pub fn insert(self: *Self, ids: []const u32, xs: []const f32, ys: []const f32, shape_data: ShapeDataType) !void {
            if(ids.len > self.capacity) try self.ensureCapacity(ids.len * 2);

            @memcpy(self.ids[0..ids.len], ids);
            @memcpy(self.xs[0..ids.len], xs);
            @memcpy(self.ys[0..ids.len], ys);

            if (ShapeDataType != void) {
                inline for (std.meta.fields(ShapeDataType)) |field| {
                    const new_data = @field(shape_data, field.name);
                    @memcpy(@constCast(@field(self.shape_data, field.name))[0..new_data.len], new_data);
                }
            }

            self.ent_count = ids.len;
        }

        pub fn build(self: *Self, grid: anytype) void {
            const ent_count: usize = self.ent_count;

            // For each entity position find the cell the ent
            // exist in and increase the cell's count.
            for(0..ent_count) |i| {
                const x = self.xs[i];
                const y = self.ys[i];

                const cell = grid.impl.getCellPos(x, y) catch continue;
                self.counts[cell.idx] += 1;
            }

            // Prefix-sum pass: rewrite counts[i] from "entity count in cell i"
            // to "start offset of cell i in the indices array".
            var total: u32 = 0;
            for(0..(grid.impl.rows * grid.impl.cols)) |i| {
                const count = &self.counts[i];
                const placeholder = count.*;
                count.* = total;
                total += placeholder;
            }

            // Scatter pass: write each entity id into its cell's slot in indices,
            // advancing the cell's write cursor so consecutive ids pack contiguously.
            for(0..ent_count) |i| {
                const x = self.xs[i];
                const y = self.ys[i];

                const cell = grid.impl.getCellPos(x, y) catch continue;
                const count_index: *u32 = &self.counts[cell.idx];
                self.indices[@intCast(count_index.*)] = @intCast(i);
                count_index.* += 1;
            }
        }

        pub fn getEntsFromCell(self: *@This(), cell_index: usize) []u32 {
            const cell_start: usize = if(cell_index > 0) @intCast(self.counts[cell_index - 1]) else 0;
            const cell_end: usize = @intCast(self.counts[cell_index]);
            return self.indices[cell_start..cell_end];
        }

        pub fn query(self: *Self, grid: anytype, x: f32, y: f32, buf: []u32) ![]u32 {
            const cell_pos = try grid.impl.getCellPos(x, y);

            var neighbor_buf: [9]usize = undefined;
            const neighbors = grid.impl.getNeighborCells(cell_pos.row, cell_pos.col, &neighbor_buf);

            var len: usize = 0;
            for (neighbors) |cell_index| {
                const slice = self.getEntsFromCell(cell_index);
                @memcpy(buf[len..len + slice.len], slice);
                len += slice.len;
            }

            return buf[0..len];
        }

        pub fn getLargestSize(self: *Self) f32 {
            var size: f32 = 0;
            switch(shape_type) {
                .Circle => for(self.shape_data.radii) |r| { size = @max(size, r*2); },
                .Rect => for(self.shape_data.widths, self.shape_data.heights) |w, h| {
                    size = @max(size, w, h);
                },
                else => unreachable,
            }
            return size;
        }
    };
}
