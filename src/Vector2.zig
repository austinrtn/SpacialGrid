pub const Vector2 = struct{
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vector2 {
        return .{.x = x, .y = y};
    }

    pub fn eql(v1: Vector2, v2: Vector2) bool {
        return (v1.x == v2.x and v1.y == v2.y);
    }

    pub fn getDistanceSq(v1: Vector2, v2: Vector2) f32 {
        const dx: f32 = v1.x - v2.x;
        const dy: f32 = v1.y - v2.y;
        return (dx * dx + dy * dy);
    }
};


