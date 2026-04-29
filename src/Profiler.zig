const std = @import("std");
const Arraylist = std.ArrayList;
const Clock = std.Io.Clock;

const ProfileItem = struct {
    const max_samples: usize = 10_000;

    allocator: std.mem.Allocator,
    io: std.Io,

    text: []const u8,
    start_time: Clock.Timestamp = undefined, 
    times: Arraylist(i96) = .empty,
    next_sample: usize = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, text: []const u8) ProfileItem {
        return .{.allocator = allocator, .io = io, .text = text};
    }

    fn deinit(self: *ProfileItem) void {
        self.times.deinit(self.allocator);
    }

    pub fn start(self: *ProfileItem) void {
        self.start_time = Clock.Timestamp.now(self.io, .awake);
    }

    pub fn stop(self: *ProfileItem) !void {
        const end_time = self.start_time.durationTo(
            Clock.Timestamp.now(self.io, .awake),
        );
        const ns = end_time.raw.toNanoseconds();
        
        if(self.times.items.len < max_samples) 
            try self.times.append(self.allocator, ns)
        else {
            self.times.items[self.next_sample] = ns;
            self.next_sample = (self.next_sample + 1) % max_samples;
        }
    }
};

pub const Profiler = struct {
    allocator: std.mem.Allocator, 
    io: std.Io,
    results: std.Io.Writer.Allocating = undefined,

    items: struct {
        update: ProfileItem,
    } = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Profiler {
        var self: Profiler = .{.allocator = allocator, .io = io};
        self.results = .init(allocator);

        self.items.update = .init(allocator, io, "Update"); 
        return self;
    }

    pub fn deinit(self: *Profiler) void {
        inline for(std.meta.fields(@TypeOf(self.items))) |field|{  
            const item = &@field(self.items, field.name);
            item.deinit();
        }
        self.results.deinit();
    }

    pub fn buildResults(self: *Profiler) !void {
        const out = &self.results.writer;
        try out.writeAll("Spacial Grid Profiling: ");
        inline for(std.meta.fields(@TypeOf(self.items))) |field| {
            const item = @field(self.items, field.name);
            if(item.times.items.len > 0) {
                try out.print("\n\t{s}:", .{item.text});

                var avg: f64 = 0;
                for(item.times.items) |time| avg += @floatFromInt(time);
                avg = avg / @as(f64,@floatFromInt(item.times.items.len));
                const avg_ms = avg / 1_000_000.0;

                try out.print(
                    "\n\t--Avg: {d:.0}ns | {d:.3}ms\n", 
                    .{ avg, avg_ms}
                ); 
            }
            else try out.print("No results found.\n", .{});
        }
    }
};
