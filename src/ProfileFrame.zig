const std = @import("std");
const ShapeType = @import("ShapeType.zig").ShapeType;

pub const ProfileFrame = struct {
    Grid: struct {
        Build: []const u8,
        Elapsed: f64,
        Frame: usize,
        Threads: usize,
        FPS: f64,

        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("Grid\n");
            
            try writer.print("  Build      : {s}\n", .{ self.Build });
            try writer.print("  Time       : {d:.2}s\n", .{self.Elapsed});
            try writer.print("  Frame      : {d:.0}\n", .{self.Frame});
            try writer.print("  Threads    : {}\n", .{ self.Threads });
            try writer.print("  FPS        : {d:.2}\n", .{ self.FPS });
        }
    },

    Shapes: struct {
        const ShapeData = struct {
            Type: ShapeType,
            Count: usize,
            Avg_Size: f32,
            Min_Size: f32,
            Max_size: f32,
        };
        
        Total_Count: []const u8,
        Circle: ShapeData,
        Rect: ShapeData,
        Point: ShapeData,
        
        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("Shapes\n");
            try writer.print("  Total      : {}\n", .{self.Total_Count});
            try writer.writeAll("\n  Type    | Count | Avg Size | Min Size | Max Size\n");
            try writer.print(
                "  Circle  | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
                .{ self.Circle.count, self.Circle.Avg_Size, self.Circle.Min_Size, self.Circle.Max_size },
            );
            try writer.print(
                "  Rect    | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
                .{ self.Rect.count, self.Rect.Avg_Size, self.Rect.Min_Size, self.Rect.Max_size },
            );
            try writer.print(
                "  Point   | {d:>5} | {d:>8.2} | {d:>8.2} | {d:>8.2}\n",
                .{ self.Point.count, self.Point.Avg_Size, self.Point.Min_Size, self.Point.Max_size },
            );
        }
    },

    Cells: struct {
        const CellData = struct {
            Type: ?ShapeType, // If null, all shapes
            Avg_Shapes_Per_Cell: f32,
            Empty_Cells: usize,
            Max_In_Cell: usize,
        };
        
        Rows: usize,
        Cols: usize,
        Cell_Size: f32,
        Cell_Mult: f32,
        Cell_Count: usize,

        Combined: CellData,
        Circle: CellData,
        Rect: CellData,
        Point: CellData,
        
        pub fn fmt(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("\nCells\n");
            try writer.print("  Rows       : {}\n", .{self.Rows});
            try writer.print("  Cols       : {}\n", .{self.Cols});
            try writer.print("  Cell Size  : {d:.2}\n", .{self.Cell_Size});
            try writer.print("  Cell Mult  : {d:.2}\n", .{self.Cell_Mult});
            try writer.print("  Cell Count : {}\n", .{ self.Cell_Count });
    
            try writer.writeAll("\n  Type      | Avg Shapes/Cell | Empty Cells | Max In Cell\n");
            try writeDensityData(self.Combined, writer);
            try writeDensityData(self.Circle, writer);
            try writeDensityData(self.Rect, writer);
            try writeDensityData(self.Point, writer);
        }
        
        fn writeDensityData(cell_data: CellData, writer: *std.Io.Writer) !void {
            const label: []const u8 = if(cell_data.Type) |tag| @tagName(tag) else "Combined"; 
            
            try writer.print(
                "  {s:<9} | {d:>15.2} | {d:>11.0} | {d:>5.0}\n",
                .{ label, cell_data.total, cell_data.empty, cell_data.max },
            );
        }
    },

    Timing: struct {
        const TimingData = struct{ Last: f32, Percent: f32, };
        Build: TimingData,
        InsertCircles: TimingData,
        InsertRects: TimingData,
        InsertPoints: TimingData,
        FindingCollisions: TimingData,
        Update: TimingData,
        
        pub fn fmt(self: @This(), out: *std.Io.Writer) !void {
            try out.writeAll("Timing\n");
            try out.writeAll("  Stage               | Last (ms) | Percent\n");

            inline for(std.meta.fields(@TypeOf(self))) |field| {
                const timing_data = @field(self, field.name);

                if(timing_data.percent > 0) {
                    try out.print(
                        "  {s:<19} | {d:>9.4} | {d:>6.2}%\n",
                        .{ field.name, timing_data.last / 1_000_000.0, timing_data.percent },
                    );
                } else {
                    try out.print(
                        "  {s:<19} | {d:>9.4} | -\n",
                        .{ field.name, timing_data.last / 1_000_000.0 },
                    );
                }
            }
        }
    },

    Detection: struct {
        const DetectionData = struct { raw: usize, percent: f32 };
        Query_Pressure: usize,
        Detected: DetectionData,
        Missed: DetectionData,
        
        pub fn fmt(writer: *std.Io.Writer) !void {
            _ = writer;
        }
    }
};