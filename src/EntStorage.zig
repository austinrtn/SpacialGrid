const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;

pub fn EntStorage(comptime shape_type: ShapeType) type {
    const DataType = switch (shape_type) {
        .Circle => struct{ radii: []f32 },
        .Rect => struct{ widths: []f32, heights: []f32 },
        else => void,
    };

    return struct {

    };
}

pub const EntStoragee = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    shape: ShapeType,
    ent_count: usize = 0,
    capacity: usize = 0,

    indices: []u32 = undefined,  
    counts: []u32 = undefined,  

    ids: []u32 = undefined,
    xs: []f32 = undefined,
    ys: []f32 = undefined,

    widths: ?[]f32 = null,
    heights: ?[]f32 = null,
    radii: ?[]f32 = null,

    fn init(allocator: std.mem.Allocator, rows: u32, cols: u32, capacity: usize, shape: ShapeType) !Self {
        var self: Self = .{.allocator = allocator, .shape = shape};

        if(shape == .Rect) { self.widths = undefined; self.heights = undefined; }
        else if(shape == .Circle) self.radii = undefined;

        self.counts = try allocator.alloc(u32, rows * cols);
        try self.ensureCapacity(capacity, true);

        return self; 
    }

    fn insert(self: *Self, ids: []const u32, xs: []const f32, ys: []const f32, widths: ?[]const f32, heights: ?[]const f32, radii: ?[]const f32) void {
        @memcpy(self.ids[self.ent_count..][0..ids.len], ids);
        @memcpy(self.xs[self.ent_count..][0..xs.len], xs);
        @memcpy(self.ys[self.ent_count..][0..ys.len], ys);

        switch(self.shape) {
            .Rect => {
                @memcpy(self.widths.?[self.ent_count..][0..widths.?.len], widths.?);
                @memcpy(self.heights.?[self.ent_count..][0..heights.?.len], heights.?);
            },
            .Circle => @memcpy(self.radii.?[self.ent_count..][0..radii.?.len], radii.?),
            else => {},
        }
    }

    fn ensureCapacity(self: *Self, new_capacity: usize, initializing: bool) !void {
        const allocator = self.allocator;
        self.capacity = new_capacity;
        if(!initializing) self.freeSlices(); 

        self.indices = try allocator.alloc(u32, new_capacity);
        self.ids = try allocator.alloc(u32, new_capacity);
        self.xs = try allocator.alloc(f32, new_capacity);
        self.ys = try allocator.alloc(f32, new_capacity);
        
        switch(self.shape) {
            .Rect => {
                self.widths = try allocator.alloc(f32, new_capacity);
                self.heights = try allocator.alloc(f32, new_capacity);
            },
            .Circle => self.radii = try allocator.alloc(f32, new_capacity),
            else => {},
        }
    }

    fn freeSlices(self: *Self) void {
        const allocator = self.allocator;
        allocator.free(self.indices);
        allocator.free(self.ids);
        allocator.free(self.xs);
        allocator.free(self.ys);

        if(self.widths) |w| allocator.free(w);
        if(self.heights) |h| allocator.free(h);
        if(self.radii) |r| allocator.free(r);
    }

    fn deinit(self: *Self) void {
        self.freeSlices();
        self.allocator.free(self.counts);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const count = 1000;
    const Ents = struct {
        ids: [count]u32,
        xs: [count]f32, 
        ys: [count]f32,
        radii: [count]f32,
    }; 
    var ents: Ents = undefined;

    inline for(std.meta.fields(@TypeOf(ents))) |field| {
        const slice = &@field(ents, field.name);
        _=slice;
    }

    var storage = try EntStorage.init(allocator, 12, 12, count, .Circle);
    defer storage.deinit();

    storage.insert(&ents.ids, &ents.xs, &ents.ys, null, null, &ents.radii);
}
