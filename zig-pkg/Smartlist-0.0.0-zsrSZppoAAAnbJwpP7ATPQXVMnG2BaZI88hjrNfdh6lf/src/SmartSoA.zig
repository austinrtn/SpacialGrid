const std = @import("std");
const Allocator = std.mem.Allocator;
const Attribute = std.builtin.Type.StructField.Attributes;

pub fn SmartSoA(comptime StructT: type) type {
    const Inner = GetInner(StructT);
    return struct {
        pub const Child: type = StructT;
        const Self = @This();
        const starting_capacity = 8;
        const InnerFields = std.meta.fields(Inner);

        /// Number of valid elements within the arrays.
        len: usize = 0,
        /// Number of allocated elements available within the arrays.
        capacity: usize = 0,
        /// Contains slices of all field data.
        /// Not for API use.
        inner: Inner = undefined,

        /// Create a new SmartSoA instance.
        pub fn init() Self {
            var self = Self{};
            self.resetInner();
            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.capacity > 0) self.freeInner(allocator);
        }

        /// Free all inner fields.
        fn freeInner(self: *Self, allocator: Allocator) void {
            inline for(InnerFields) |field| {
                allocator.free(@field(self.inner, field.name));
            }
        }

        /// Set all inner slices to empty.
        fn resetInner(self: *Self) void {
            inline for (InnerFields) |field| {
                @field(self.inner, field.name) = &.{};
            }
        }

        /// Increases the capacity of the arrays to store more items.
        /// Allows arrays to grow without allocation up to the set capacity.
        /// Will invalidate element pointers if additional memory is needed.
        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, capacity: usize) !void {
            const allocated = self.capacity > 0;
            if (self.capacity >= capacity) return;

            inline for(InnerFields) |field| {
                const data = &@field(self.inner, field.name);
                if (allocated) data.* = try allocator.realloc(data.*, capacity)
                else data.* = try allocator.alloc(@FieldType(StructT, field.name), capacity);
            }

            self.capacity = capacity;
        }

        /// Returns a slice of values for the specified field.
        pub fn items(self: *Self, comptime field: std.meta.FieldEnum(Inner)) @FieldType(Inner, @tagName(field)) {
            return @field(self.inner, @tagName(field))[0..self.len];
        }

        /// Returns a struct of slices for each specified field.
        /// For example, if you pass fields .x and .y, then
        ///`soa.manyItems(&.{.x, .y});`
        /// will return a struct with fields x and y, both being slices of
        /// their respective type.
        pub fn manyItems(self: *Self, comptime fields: []const std.meta.FieldEnum(Inner)) GetStructOfArrays(Inner, fields) {
            var t: GetStructOfArrays(Inner, fields) = undefined;

            inline for(InnerFields) |field| {
                if(@hasField(@TypeOf(t), field.name))
                    @field(t, field.name) = @field(self.inner, field.name)[0..self.len];
            }

            return t;
        }

        pub fn allItems(self: *Self) Inner {
            var t: Inner = undefined;

            inline for(InnerFields) |field|
                @field(t, field.name) = @field(self.inner, field.name)[0..self.len];

            return t;
        }

        /// Returns a copy of StructT at the specified index.
        pub fn get(self: *Self, index: usize) StructT {
            std.debug.assert(index < self.len);
            var T: StructT = undefined;
            inline for(InnerFields) |field| {
                @field(T, field.name) = @field(self.inner, field.name)[index];
            }
            return T;
        }

        /// Sets the capacity to the starting capacity if capacity is 0,
        /// or to twice the size of the current capacity.
        fn checkCapacity(self: *Self, allocator: Allocator) !void {
            if (self.capacity == 0)
                try self.ensureTotalCapacity(allocator, starting_capacity);
            if (self.len + 1 > self.capacity)
                try self.ensureTotalCapacity(allocator, self.capacity * 2);
        }

        /// Set the element at the specified index.
        pub fn set(self: *Self, T: StructT, index: usize) void {
            std.debug.assert(index < self.len);
            inline for(InnerFields) |field| {
                @field(self.inner, field.name)[index] = @field(T, field.name);
            }
        }

        /// Add an element to the end of the array.
        /// Will invalidate element pointers if additional memory is needed.
        pub fn append(self: *Self, allocator: Allocator, T: StructT) !void {
            try self.checkCapacity(allocator);

            inline for(InnerFields) |field| {
                @field(self.inner, field.name)[self.len] = @field(T, field.name);
            }

            self.len += 1;
        }

        /// Inserts a new element at the specified index, shifting all following elements over one.
        /// Will invalidate element pointers if additional memory is needed.
        pub fn insert(self: *Self, allocator: Allocator, T: StructT, index: usize) !void {
            std.debug.assert(index <= self.len);
            try self.checkCapacity(allocator);
            inline for(InnerFields) |field| {
                const slice = @field(self.inner, field.name);
                var i: usize = self.len;

                while(i > index) : (i -= 1) slice[i] = slice[i - 1];
                slice[index] = @field(T, field.name);
            }

            self.len += 1;
        }

        /// Clears all data within arrays but keeps capacity at its current value.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        /// Clears all data and frees all array data, setting capacity to 0.
        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            if (self.capacity > 0) {
                self.freeInner(allocator);
                self.resetInner();
            }
            self.len = 0;
            self.capacity = 0;
        }

        /// Removes and returns the element at the specified index and replaces it with the last element in the array.
        /// Returns null if length is 0.
        /// Fast, but does not retain array order.
        pub fn swapAndPop(self: *Self, index: usize) ?StructT {
            if (self.len == 0) return null;
            std.debug.assert(index < self.len);
            const last_idx: usize = self.len - 1;
            var data: StructT = undefined;

            inline for(InnerFields) |field| {
                const slice = @field(self.inner, field.name);

                @field(data, field.name) = slice[index];
                slice[index] = slice[last_idx];
            }

            self.len -= 1;
            return data;
        }

        /// Returns the last element in the array, or returns null if length is 0.
        pub fn pop(self: *Self) ?StructT {
            if(self.len == 0) return null;
            const index = self.len - 1;
            var data: StructT = undefined;

            inline for(InnerFields) |field| {
                const slice = @field(self.inner, field.name);
                @field(data, field.name) = slice[index];
            }

            self.len -= 1;
            return data;
        }

        /// Removes the element at the specified index.
        /// Retains the order of the array but is slower than swapAndPop.
        pub fn orderedRemove(self: *Self, index: usize) void {
            std.debug.assert(index < self.len);
            inline for(InnerFields) |field| {
                const slice = @field(self.inner, field.name);
                for(index..self.len - 1) |i| {
                    slice[i] = slice[i + 1];
                }
            }
            self.len -= 1;
        }

        /// Removes elements from `from_idx` through `to_idx`, including both indexes.
        pub fn orderedRemoveMany(self: *Self, from_idx: usize, to_idx: usize) void {
            std.debug.assert(from_idx <= to_idx);
            std.debug.assert(to_idx < self.len);
            const len_removed = to_idx - from_idx + 1;

            inline for(InnerFields) |field| {
                const slice = @field(self.inner, field.name);
                var idx_to_write: usize = from_idx;

                for(to_idx + 1..self.len) |idx_to_copy| {
                    slice[idx_to_write] = slice[idx_to_copy];
                    idx_to_write += 1;
                }
            }

            self.len -= len_removed;
            }
        };
}

fn GetInner(comptime T: type) type {
    const field_names = std.meta.fieldNames(T);

    const field_types = blk: {
        var types: [field_names.len]type = undefined;
        inline for(field_names, 0..) |name, i| types[i] = []@FieldType(T, name);
        break :blk types;
    };

    const field_attrs = blk: {
        var attrs: [field_names.len]Attribute = undefined;
        for(0..field_names.len) |i| attrs[i] = .{};
        break :blk attrs;
    };

    return @Struct(
        .auto,
        null,
        field_names,
        &field_types,
        &field_attrs,
    );
}

fn GetStructOfArrays(comptime T: type, comptime fields: []const std.meta.FieldEnum(T)) type {
    const field_names = blk: {
        var names: [fields.len][]const u8 = undefined;
        for(0..fields.len) |i| {
            names[i] = @tagName(fields[i]);
        }
        break :blk names;
    };

    const field_types = blk: {
        var types: [fields.len]type = undefined;
        for(0..fields.len) |i| {
            types[i] = @FieldType(T, @tagName(fields[i]));
        }

        break :blk types;
    };

    const field_attrs = blk: {
        var attrs: [fields.len]Attribute = undefined;
        for(0..fields.len) |i| {
            attrs[i] = .{};
        }

        break :blk attrs;
    };

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}
