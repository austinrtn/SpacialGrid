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

        pub fn init(allocator: std.mem.Allocator, rows: u32, cols: u32) !Self {
            var self: Self = .{.allocator = allocator,};
            defer self.inited = true;

            self.counts = try allocator.alloc(u32, rows * cols);
            @memset(self.counts, 0);

            try self.ensureCapacity(0);

            return self; 
        }

        pub fn freeSlices(self: *Self) void {
            const allocator = self.allocator;
            allocator.free(self.indices);
            allocator.free(self.ids);
            allocator.free(self.xs);
            allocator.free(self.ys);

            inline for(std.meta.fields(ShapeDataType)) |field| {
                allocator.free(@field(self.shape_data, field.name)); 
            }
        }

        pub fn deinit(self: *Self) void {
            self.freeSlices();
            self.allocator.free(self.counts);
        }

        pub fn ensureCapacity(self: *Self, new_capacity: usize) !void {
            const allocator = self.allocator;
            self.capacity = new_capacity;
            if(self.inited) self.freeSlices(); 

            self.indices = try allocator.alloc(u32, new_capacity);
            self.ids = try allocator.alloc(u32, new_capacity);
            self.xs = try allocator.alloc(f32, new_capacity);
            self.ys = try allocator.alloc(f32, new_capacity);
            
            inline for (std.meta.fields(ShapeDataType))|field| {
                const shape_d = &@field(self.shape_data, field.name);
                shape_d.* = try allocator.alloc(f32, new_capacity);
            }
        }
        
        pub fn insert(self: *Self, ids: []const u32, xs: []const f32, ys: []const f32, shape_data: ShapeDataType) !void {
            const new_ent_count = self.ent_count + ids.len;
            if(new_ent_count >= self.capacity) try self.ensureCapacity(new_ent_count * 2);

            @memcpy(self.ids[self.ent_count..][0..ids.len], ids);
            @memcpy(self.xs[self.ent_count..][0..xs.len], xs);
            @memcpy(self.ys[self.ent_count..][0..ys.len], ys);

            inline for (std.meta.fields(ShapeDataType))|field| {
                const current_data = @field(self.shape_data, field.name);
                const new_data = @field(shape_data, field.name); 

                @memcpy(current_data[self.ent_count..][0..new_data.len], new_data);
            }

            self.ent_count += new_ent_count;
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
                const slice = self.impl.getEntsFromCell(cell_index);
                @memcpy(buf[len..len + slice.len], slice);
                len += slice.len;
            }

            return buf[0..len];
        }
    };
}

// pub fn main(init: std.process.Init) !void {
//     const allocator = init.gpa;
//     const count = 1000;
//     const Ents = struct {
//         ids: [count]u32,
//         xs: [count]f32, 
//         ys: [count]f32,
//         widths:[count]f32,
//         heights:[count]f32,
//     }; 
//     var ents: Ents = undefined;
//
//     inline for(std.meta.fields(@TypeOf(ents))) |field| {
//         const slice = &@field(ents, field.name);
//         @memset(slice, 0);
//     }
//
//     var storage: EntStorage(.Rect) = try .init(allocator, 12, 12, count);
//     defer storage.deinit();
//     
//     storage.insert(&ents.ids, &ents.xs, &ents.ys, .{.widths = &ents.widths, .heights = &ents.heights});
// 
