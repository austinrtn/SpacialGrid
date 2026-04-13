const ShapeType = @import("SpacialGrid.zig").ShapeType;

pub const CollisionDetection = struct {
    pub fn checkColliding(
        ax: f32, ay: f32, a_shape: ShapeType, a_r: f32, a_w: f32, a_h: f32,
        bx: f32, by: f32, b_shape: ShapeType, b_r: f32, b_w: f32, b_h: f32,
    ) bool {
        return switch (a_shape) {
            .Circle => switch (b_shape) {
                .Circle => circleCollision(ax, ay, a_r, bx, by, b_r),
                .Rect   => rectCircleCollision(bx, by, b_w, b_h, ax, ay, a_r),
                .Point  => pointCircleCollision(ax, ay, a_r, bx, by),
            },
            .Rect => switch (b_shape) {
                .Circle => rectCircleCollision(ax, ay, a_w, a_h, bx, by, b_r),
                .Rect   => rectCollision(ax, ay, a_w, a_h, bx, by, b_w, b_h),
                .Point  => pointRectCollision(ax, ay, a_w, a_h, bx, by),
            },
            .Point => switch (b_shape) {
                .Circle => pointCircleCollision(bx, by, b_r, ax, ay),
                .Rect   => pointRectCollision(bx, by, b_w, b_h, ax, ay),
                .Point  => pointCollision(ax, ay, bx, by),
            },
        };
    }

    pub fn circleCollision(ax: f32, ay: f32, r_a: f32, bx: f32, by: f32, r_b: f32) bool {
        const dx = ax - bx;
        const dy = ay - by;
        const r = r_a + r_b;
        return (dx * dx + dy * dy) < (r * r);
    }

    pub fn rectCollision(ax: f32, ay: f32, aw: f32, ah: f32, bx: f32, by: f32, bw: f32, bh: f32) bool {
        return (ax < bx + bw and ax + aw > bx) and
               (ay < by + bh and ay + ah > by);
    }

    pub fn pointCollision(ax: f32, ay: f32, bx: f32, by: f32) bool {
        return ax == bx and ay == by;
    }

    pub fn rectCircleCollision(rx: f32, ry: f32, rw: f32, rh: f32, cx: f32, cy: f32, r: f32) bool {
        const closest_x = @max(rx, @min(cx, rx + rw));
        const closest_y = @max(ry, @min(cy, ry + rh));
        const dx = cx - closest_x;
        const dy = cy - closest_y;
        return (dx * dx + dy * dy) < (r * r);
    }

    pub fn pointCircleCollision(cx: f32, cy: f32, r: f32, px: f32, py: f32) bool {
        const dx = px - cx;
        const dy = py - cy;
        return (dx * dx + dy * dy) < (r * r);
    }

    pub fn pointRectCollision(rx: f32, ry: f32, rw: f32, rh: f32, px: f32, py: f32) bool {
        return (px >= rx and px <= rx + rw) and
               (py >= ry and py <= ry + rh);
    }
};
