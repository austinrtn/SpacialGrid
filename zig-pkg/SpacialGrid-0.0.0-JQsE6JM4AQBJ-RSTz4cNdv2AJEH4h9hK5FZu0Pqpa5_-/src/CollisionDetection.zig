const std = @import("std");
const ShapeData = @import("ShapeType.zig").ShapeData;

pub fn CollisionDetection(comptime Vector2: type) type {

    if(!@hasField(Vector2, "x") or !@hasField(Vector2, "y")) {
        @compileError("Vector2 type must contain both fields x and y");
    }

    const Shape = ShapeData(Vector2);

return struct {
    /// Check if two entities are colliding
    pub fn checkColliding(x_a: f32, y_a: f32, shape_a: Shape, x_b: f32, y_b: f32, shape_b: Shape) bool {
        return switch (shape_a) {
            .Circle => |r1| switch(shape_b) {
                .Circle => |r2| circleCollision(x_a, y_a, r1, x_b, y_b, r2),
                .Rect => |dim| rectCircleCollision(x_b, y_b, dim.x, dim.y, x_a, y_a, r1),
                .Point => pointCircleCollision(x_a, y_a, r1, x_b, y_b),
            },
            .Rect => |dim1| switch(shape_b) {
                .Circle => |r| rectCircleCollision(x_a, y_a, dim1.x, dim1.y, x_b, y_b, r),
                .Rect => |dim2| rectCollision(x_a, y_a, dim1.x, dim1.y, x_b, y_b, dim2.x, dim2.y),
                .Point => pointRectCollision(x_a, y_a, dim1.x, dim1.y, x_b, y_b),
            },
            .Point => switch(shape_b) {
                .Circle => |r| pointCircleCollision(x_b, y_b, r, x_a, y_a),
                .Rect => |dim| pointRectCollision(x_b, y_b, dim.x, dim.y, x_a, y_a),
                .Point => pointCollision(x_a, y_a, x_b, y_b),
            }
        };
    }

    /// Check collision between two circles.
    pub fn circleCollision(x_a: f32, y_a: f32, r_a: f32, x_b: f32, y_b: f32, r_b: f32) bool {
        const dx = x_a - x_b;
        const dy = y_a - y_b;
        const r = r_a + r_b;
        return (dx * dx + dy * dy) < (r * r);
    }

    /// Check collision between two rectangles. Assumes coordinates start at top left of rect.
    pub fn rectCollision(x_a: f32, y_a: f32, w_a: f32, h_a: f32, x_b: f32, y_b: f32, w_b: f32, h_b: f32) bool {
        return (
            (x_a < x_b + w_b and x_a + w_a > x_b)
                             and
            (y_a < y_b + h_b and y_a + h_a > y_b)
        );
    }

    /// Check collision between two points (if both points are equal).
    pub fn pointCollision(x1: f32, y1: f32, x2: f32, y2: f32) bool {
        return x1 == x2 and y1 == y2;
    }

    /// Check collision between a circle and a rectangle. Assumes coordinates start at top left for rectangle.
    pub fn rectCircleCollision(rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, circle_x: f32, circle_y: f32, r: f32) bool {
        const closest_x = @max(rect_x, @min(circle_x, rect_x + rect_w));
        const closest_y = @max(rect_y, @min(circle_y, rect_y + rect_h));

        const dx = circle_x - closest_x;
        const dy = circle_y - closest_y;

        return (dx * dx + dy * dy) < (r * r);
    }

    /// Check collision between a circle and a point.
    pub fn pointCircleCollision(circle_x: f32, circle_y: f32, r: f32, point_x: f32, point_y: f32) bool {
        const dx = point_x - circle_x;
        const dy = point_y - circle_y;
        return (dx * dx + dy * dy) < (r * r);
    }

    /// Check collision between a rectangle and a point.
    pub fn pointRectCollision(rect_x: f32, rect_y: f32, rect_w: f32, rect_h: f32, point_x: f32, point_y: f32) bool {
        return (
            (point_x >= rect_x and point_x <= rect_x + rect_w)
                               and
            (point_y >= rect_y and point_y <= rect_y + rect_h)
        );
    }
};
}
