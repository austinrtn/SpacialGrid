const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;

pub const ProfileFrame = struct {
    grid: Grid,
    shapes: Shapes,
    cells: Cells,
    timing: Timing,
    detection: Detection,

    pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
        const header: []const u8 = "Spacial Grid Profiling";
        try writer.print("{s}\n", .{header});
        for (0..header.len) |_| try writer.writeAll("_");
        try writer.writeAll("\n\n");

        try self.grid.fmt(writer);
        try writer.writeAll("\n");
        try self.shapes.fmt(writer);
        try self.cells.fmt(writer);
        try writer.writeAll("\n");
        try self.timing.fmt(writer);
        try self.detection.fmt(writer);
    }

    pub const Grid = struct {
        build: []const u8,
        elapsed: f64,
        frame: usize,
        threads: usize,
        fps: f64,
        area_pixels: f32,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("Grid\n");
            try writer.print("  Build      : {s}\n", .{self.build});
            try writer.print("  Time       : {d:.2}s\n", .{self.elapsed});
            try writer.print("  Frame      : {}\n", .{self.frame});
            try writer.print("  Threads    : {}\n", .{self.threads});
            try writer.print("  FPS        : {d:.2}\n", .{self.fps});
            try writer.print("  AREA       : ", .{});

            var buf: [32]u8 = undefined;
            try commify(self.area_pixels, &buf, writer);
        }
    };

    pub const Shapes = struct {
        total_count: usize,
        circle: ShapeData,
        rect: ShapeData,
        point: ShapeData,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("Shapes\n");
            try writer.print("  Total      : {}\n", .{self.total_count});
            try writer.writeAll("\n  Type    | Count | Avg Size | Min Size | Max Size\n");
            try writeShapeData(self.circle, writer);
            try writeShapeData(self.rect, writer);
            try writeShapeData(self.point, writer);
        }

        fn writeShapeData(shape_data: ShapeData, writer: *std.Io.Writer) !void {
            try writer.print(
                "  {s:<7} | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
                .{
                    @tagName(shape_data.shape_type),
                    shape_data.count,
                    shape_data.avg_size,
                    shape_data.min_size,
                    shape_data.max_size,
                },
            );
        }
    };

    pub const ShapeData = struct {
        shape_type: ShapeType,
        count: usize,
        avg_size: f32,
        min_size: f32,
        max_size: f32,
    };

    pub const Cells = struct {
        rows: usize,
        cols: usize,
        cell_size: f32,
        cell_mult: f32,
        cell_count: usize,

        combined: CellData,
        circle: CellData,
        rect: CellData,
        point: CellData,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("\nCells\n");
            try writer.print("  Rows       : {}\n", .{self.rows});
            try writer.print("  Cols       : {}\n", .{self.cols});
            try writer.print("  Cell Size  : {d:.2}\n", .{self.cell_size});
            try writer.print("  Cell Mult  : {d:.2}\n", .{self.cell_mult});
            try writer.print("  Cell Count : {}\n", .{self.cell_count});

            try writer.writeAll("\n  Type      | Avg Shapes/Cell | Empty Cells | Max In Cell\n");
            try writeCellData(self.combined, writer);
            try writeCellData(self.circle, writer);
            try writeCellData(self.rect, writer);
            try writeCellData(self.point, writer);
        }

        fn writeCellData(cell_data: CellData, writer: *std.Io.Writer) !void {
            const label: []const u8 = if (cell_data.shape_type) |tag| @tagName(tag) else "Combined";

            try writer.print(
                "  {s:<9} | {d:>15.2} | {d:>11} | {d:>5}\n",
                .{ label, cell_data.avg_shapes_per_cell, cell_data.empty_cells, cell_data.max_in_cell },
            );
        }
    };

    pub const CellData = struct {
        shape_type: ?ShapeType,
        avg_shapes_per_cell: f64,
        empty_cells: usize,
        max_in_cell: usize,
    };

    pub const Timing = struct {
        build: TimingData,
        insert_circles: TimingData,
        insert_rects: TimingData,
        insert_points: TimingData,
        finding_collisions: TimingData,
        update: TimingData,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("Timing\n");
            try writer.writeAll("  Stage               | Last (ms) | Percent\n");

            inline for (std.meta.fields(@TypeOf(self))) |field| {
                const timing_data = @field(self, field.name);
                try writeTimingData(timing_data, writer);
            }
        }

        fn writeTimingData(timing_data: TimingData, writer: *std.Io.Writer) !void {
            if (timing_data.last_ns) |last_ns| {
                if (timing_data.percent) |percent| {
                    try writer.print(
                        "  {s:<19} | {d:>9.4} | {d:>6.2}%\n",
                        .{ timing_data.label, last_ns / 1_000_000.0, percent },
                    );
                } else {
                    try writer.print(
                        "  {s:<19} | {d:>9.4} | {s:>7}\n",
                        .{ timing_data.label, last_ns / 1_000_000.0, "-" },
                    );
                }
            } else if (timing_data.include_percent) {
                try writer.print("  {s:<19} | {s:>9} | {s:>7}\n", .{ timing_data.label, "N.A", "N.A" });
            } else {
                try writer.print("  {s:<19} | {s:>9} | {s:>7}\n", .{ timing_data.label, "N.A", "-" });
            }
        }
    };

    pub const TimingData = struct {
        label: []const u8,
        last_ns: ?f64,
        percent: ?f64,
        include_percent: bool,
    };

    pub const Detection = struct {
        query_pressure: f64,
        detected: DetectionData,
        missed: DetectionData,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("\nQuery Pressure: ");

            var buf: [32]u8 = undefined;
            try commify(self.query_pressure, &buf, writer);

            try writer.writeAll("\n");

            try writer.print("Collisions Detected: {d:.0} | {d:.2}%\n", .{ self.detected.raw, self.detected.percent });
            try writer.print("Collisions Missed: {d:.0} | {d:.2}%\n", .{ self.missed.raw, self.missed.percent });
        }
    };

    pub const DetectionData = struct {
        raw: f64,
        percent: f64,
    };
};

fn commify(num: anytype, buf: []u8, writer: *std.Io.Writer) !void {
    const digits = try std.fmt.bufPrint(buf, "{}", .{num});

    for(0..digits.len) |i| {
        const from_right = digits.len - i;
        if(i != 0 and @mod(from_right, 3) == 0) try writer.writeAll(",");
        try writer.print("{c}", .{digits[i]});
    }
}
