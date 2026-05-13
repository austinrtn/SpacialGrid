const std = @import("std");
const builtin = @import("builtin");
const build = builtin.mode;

const Attr = std.builtin.Type.StructField.Attributes;

pub const BaseFields = [_][]const u8{ "ids", "xs", "ys" };
pub const RectFields = [_][]const u8{ "ws", "hs" };
pub const CircleFields = [_][]const u8{"radii"};
pub const AllFields = BaseFields ++ RectFields ++ CircleFields;

const Types = [_]type{[]const u8} ** AllFields.len;
const Attrs = [_]Attr{.{}} ** AllFields.len;

pub const InsertionFieldMap = struct {
    ids: []const u8 = "ids",
    xs: []const u8 = "xs",
    ys: []const u8 = "ys",
    ws: []const u8 = "ws",
    hs: []const u8 = "hs",
    radii: []const u8 = "radii",
};

pub fn Insert(comptime SpacialGrid: type, comptime PROFILING: bool) type {
    return struct {
        const Self = @This();
        Circle: CircleInsert,
        Rect: RectInsert,
        Point: PointInsert,

        pub fn init(grid: *SpacialGrid) Self {
            return .{
                .Point = .{ .grid = grid },
                .Circle = .{ .grid = grid },
                .Rect = .{ .grid = grid },
            };
        }

        const CircleInsert = struct {
            grid: *SpacialGrid,

            pub fn single(self: @This(), id: u32, x: f32, y: f32, r: f32) !void {
                try self.many(&.{id}, &.{x}, &.{y}, &.{r});
            }

            pub fn many(self: @This(), ids: []const u32, xs: []const f32, ys: []const f32, radii: []const f32) !void {
                const grid = self.grid;

                if(build == .Debug or build == .ReleaseSafe) {
                    if(ids.len != xs.len or ids.len != ys.len or ids.len != radii.len) @panic(
                        "All slice parameters must be of the same length!\n"
                    );
                }

                if (grid.impl.has_updated) {
                    grid.reset();
                }

                if (PROFILING) self.grid.impl.profiler.timed_items.insert_circles.start();
                if (ids.len > grid.impl.ent_capacity) try grid.ensureCapacity(ids.len * 2, .Circle);

                try grid.impl.circle_storage.insert(ids, xs, ys, .{ .radii = radii });
                if (PROFILING) try self.grid.impl.profiler.timed_items.insert_circles.stop();
                grid.impl.has_built = false;

            }

            pub fn mal(self: @This(), comptime field_map: InsertionFieldMap, circles_mal: anytype) !void {
                if(circles_mal.len == 0) return;
                const fields = BaseFields ++ CircleFields;

                const Data = @Struct(
                    .auto,
                    null,
                    &fields,
                    &[_]type{ []const u32, []const f32, []const f32, []const f32 },
                    &[_]std.builtin.Type.StructField.Attributes{ .{}, .{}, .{}, .{} },
                );

                var data: Data = undefined;

                Self.parseMal(field_map, &data, circles_mal);
                try self.many(data.ids, data.xs, data.ys, data.radii);
            }
        };

        const RectInsert = struct {
            grid: *SpacialGrid,

            pub fn single(self: @This(), id: u32, x: f32, y: f32, w: f32, h: f32) !void {
                try self.many(&.{id}, &.{x}, &.{y}, &.{w}, &.{h});
            }

            pub fn many(self: @This(), ids: []const u32, xs: []const f32, ys: []const f32, widths: []const f32, heights: []const f32) !void {
                if(build == .Debug or build == .ReleaseSafe) {
                    if(ids.len != xs.len or ids.len != ys.len or ids.len != widths.len or ids.len != heights.len) @panic(
                        "All slice parameters must be of the same length!\n"
                    );
                }

                const grid = self.grid;
                if (grid.impl.has_updated) {
                    grid.reset();
                }

                if (PROFILING) self.grid.impl.profiler.timed_items.insert_rects.start();
                if (ids.len > grid.impl.ent_capacity) try grid.ensureCapacity(ids.len * 2, .Rect);

                try grid.impl.rect_storage.insert(ids, xs, ys, .{ .widths = widths, .heights = heights });
                if (PROFILING) try self.grid.impl.profiler.timed_items.insert_rects.stop();
                grid.impl.has_built = false;
            }

            pub fn mal(self: @This(), comptime field_map: InsertionFieldMap, rect_mal: anytype) !void {
                if(rect_mal.len == 0) return;
                const fields = BaseFields ++ RectFields;

                const Data = @Struct(
                    .auto,
                    null,
                    &fields,
                    &[_]type{ []const u32, []const f32, []const f32, []const f32, []const f32 },
                    &[_]std.builtin.Type.StructField.Attributes{.{}} ** 5,
                );

                var data: Data = undefined;

                Self.parseMal(field_map, &data, rect_mal);
                try self.many(data.ids, data.xs, data.ys, data.ws, data.hs);
            }
        };

        const PointInsert = struct {
            grid: *SpacialGrid,

            pub fn single(self: @This(), id: u32, x: f32, y: f32) !void {
                try self.many(&.{id}, &.{x}, &.{y});
            }

            pub fn many(self: @This(), ids: []const u32, xs: []const f32, ys: []const f32) !void {
                if(build == .Debug or build == .ReleaseSafe) {
                    if(ids.len != xs.len or ids.len != ys.len) @panic(
                        "All slice parameters must be of the same length!\n"
                    );
                }

                const grid = self.grid;
                if (grid.impl.has_updated) {
                    grid.reset();
                }

                if (PROFILING) self.grid.impl.profiler.timed_items.insert_points.start();
                if (ids.len > grid.impl.ent_capacity) try grid.ensureCapacity(ids.len * 2, .Point);

                try grid.impl.point_storage.insert(ids, xs, ys, {});
                if (PROFILING) try self.grid.impl.profiler.timed_items.insert_points.stop();

                grid.impl.has_built = false;
            }

            pub fn mal(self: @This(), comptime field_map: InsertionFieldMap, point_mal: anytype) !void {
                if(point_mal.len == 0) return;

                const fields = BaseFields;
                const Data = @Struct(
                    .auto,
                    null,
                    &fields,
                    &[_]type{ []const u32, []const f32, []const f32 },
                    &[_]std.builtin.Type.StructField.Attributes{.{}} ** 3,
                );

                var data: Data = undefined;

                Self.parseMal(field_map, &data, point_mal);
                try self.many(data.ids, data.xs, data.ys);
            }
        };

        fn parseMal(comptime field_map: InsertionFieldMap, data: anytype, mal: anytype) void {
            const MalParam = @TypeOf(mal);
            const Mal = switch (@typeInfo(MalParam)) {
                .pointer => |ptr| ptr.child,
                else => MalParam,
            };
            const mal_slice = switch (@typeInfo(MalParam)) {
                .pointer => mal.*.slice(),
                else => mal.slice(),
            };
            const FieldEnum = comptime Mal.Field;

            inline for (std.meta.fields(@TypeOf(data.*))) |field| {
                const field_name = field.name;
                const field_val = @field(field_map, field_name);

                const mal_field = comptime (std.meta.stringToEnum(FieldEnum, field_val) orelse
                    @compileError(std.fmt.comptimePrint(
                        "\nMultiArrayList is missing field '{s}' mapped from insertion field '{s}'\n",
                        .{ field_val, field_name },
                    )));

                @field(data.*, field_name) = mal_slice.items(mal_field);
            }
        }
    };
}
