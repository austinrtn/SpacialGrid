# Separate storage by shape type (for SIMD)
If we want to vectorize collision detection, the tagged-union layout fights us: SIMD lanes can't mix circle-vs-circle and rect-vs-rect kernels in one pass.
Refactor to per-shape arrays with their own ID spaces (circles: []Circle, rects: []Rect, densely packed).  The grid keeps separate prefix-summed index lists 
per shape type, and findCollisions dispatches three branchless kernels: circle×circle, circle×rect, rect×rect.  No tag, no switch in the hot path.
Ripple: CollisionPair needs to become typed (or results split by pair type), and any API exposing a single global entity ID needs a (shape, local_id) lookup.
