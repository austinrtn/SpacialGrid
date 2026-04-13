pub const ShapeType = enum { Point, Rect, Circle };
pub fn ShapeData(comptime Vec2: type) type {
    if(!@hasField(Vec2, "x") or !@hasField(Vec2, "y")) {
        @compileError("Vector2 type must contain both fields x and y\n");
    }

    return union(ShapeType){
        Point: void,
        Rect: Vec2,
        Circle: f32,
    };
}
