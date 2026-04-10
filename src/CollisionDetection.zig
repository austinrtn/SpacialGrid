const std = @import("std");
const Vector2 = @import("Vector2.zig").Vector2;
const ShapeData = @import("SpacialGrid.zig").ShapeData;

/// Check if two entities are colliding
pub fn checkColliding(pos_a: Vector2, shape_a: ShapeData, pos_b: Vector2, shape_b: ShapeData) bool {
    return switch (shape_a) {
        .Circle => |r1| switch(shape_b) {
            .Circle => |r2| circleCollision(pos_a, r1, pos_b, r2),
            .Rect => |dim| rectCircleCollision(pos_b, dim, pos_a, r1),
            .Point => pointCircleCollision(pos_a, r1, pos_b),
        },
        .Rect => |dim1| switch(shape_b) {
            .Circle => |r| rectCircleCollision(pos_a, dim1, pos_b, r),
            .Rect => |dim2| rectCollision(pos_a, dim1, pos_b, dim2),
            .Point => pointRectCollision(pos_a, dim1, pos_b)
        },
        .Point => switch(shape_b) {
            .Circle => |r| pointCircleCollision(pos_b, r, pos_a),
            .Rect => |dim| pointRectCollision(pos_b, dim, pos_a),
            .Point => pointCollision(pos_b, pos_a),
        }
    };
}

/// Check collision between two circles.
pub fn circleCollision(pos_a: Vector2, r_a: f32, pos_b: Vector2, r_b: f32) bool {
    const dist = Vector2.getDistanceSq(pos_a, pos_b);
    const r = r_a + r_b;

    return dist < (r * r);
}

/// Check collision between two Rectangles.  Assumes coordinates start at top left of rect.
pub fn rectCollision(pos_a: Vector2, dim_a: Vector2, pos_b: Vector2, dim_b: Vector2) bool {
    return (
        (pos_a.x < pos_b.x + dim_b.x and pos_a.x + dim_a.x > pos_b.x)
                                     and
        (pos_a.y < pos_b.y + dim_b.y and pos_a.y + dim_a.y > pos_b.y)
    );
}

/// Check collision between two points (if both points are equal).
pub fn pointCollision(point1: Vector2, point2: Vector2) bool {
    return Vector2.eql(point1, point2);
}

/// Check collision between a circle and a rectangle.  Assumes coordinates start at top left for rectangle.
pub fn rectCircleCollision(rect_pos: Vector2, rect_dim: Vector2, circle_pos: Vector2, r: f32) bool {
    const closest_x = @max(rect_pos.x, @min(circle_pos.x, rect_pos.x + rect_dim.x));
    const closest_y = @max(rect_pos.y, @min(circle_pos.y, rect_pos.y + rect_dim.y));

    const dx = circle_pos.x - closest_x;
    const dy = circle_pos.y - closest_y;

    return (dx * dx + dy * dy) < (r * r);
}

/// Check collision between a circle and a point
pub fn pointCircleCollision(pos_a: Vector2, r: f32, point: Vector2) bool {
    const dist = Vector2.getDistanceSq(point, pos_a);
    return (dist < r * r);
}

/// Check collision between a rectangle and a point
pub fn pointRectCollision(pos_a: Vector2, dim: Vector2, point: Vector2) bool {
    return (
        (point.x >= pos_a.x and point.x <= pos_a.x + dim.x)
                            and
        (point.y >= pos_a.y and point.y <= pos_a.y + dim.y)
    );
}

