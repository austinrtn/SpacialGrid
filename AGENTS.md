# Repository Guidelines

## Project Structure & Module Organization

This is a Zig project for a spatial grid/collision detection library and benchmarks. Core source files live in `src/`. `src/root.zig` exposes the package API, while `src/ZigGridLib.zig` wires together public types such as `SpacialGrid`, `CollisionDetection`, and shape helpers. The executable benchmark/demo entry point is `src/main.zig`; `src/touchtips.zig` is a separate run target. Supporting modules include `Worker.zig`, `WorkQueue.zig`, `EntStorage.zig`, `Vector2.zig`, and shape/collision modules.

Generated build output belongs in `zig-out/` and `.zig-cache/`, both ignored by git. Benchmark outputs and notes are stored in `results/`, `WorkerPerRegionResults.txt`, `bugfixes.txt`, and `todo.md`.

## Build, Test, and Development Commands

- `zig build` builds and installs the main `ZigGridLib` executable into `zig-out/bin/`.
- `zig build run -- count=10000 timeout=3` runs `src/main.zig` with simulation arguments.
- `zig build test` runs module and executable Zig tests configured in `build.zig`.
- `zig build touchtips` builds and runs the `src/touchtips.zig` executable.
- `zig fmt src/*.zig build.zig` formats project Zig files before committing.
- `./gen_results.sh` runs a benchmark sweep and writes a timestamped file under `results/`; verify its `BIN` path matches the executable name before using it.

## Coding Style & Naming Conventions

Use standard Zig formatting via `zig fmt`. Types use PascalCase (`SpacialGrid`, `CollisionPair`), functions and fields use camelCase or lower snake where already established (`insertCircles`, `thread_count`), and enum tags use PascalCase (`Circle`, `Rect`, `All`). Prefer explicit error propagation with `try`, allocator ownership passed as parameters, and `defer` cleanup near allocation sites.

## Testing Guidelines

Place Zig `test` blocks close to the module they validate, especially for collision math, storage behavior, and worker queue logic. Use small deterministic fixtures, then run `zig build test`. For performance-sensitive changes, also run representative `zig build run -- count=... timeout=...` scenarios and record notable results in `results/` only when useful for comparison.

## Commit & Pull Request Guidelines

Recent commits use short imperative messages such as `Fixing Worker Queue` and `Fixing automatic ensure cap`; keep future subjects concise and behavior-focused. Pull requests should describe the changed behavior, list test or benchmark commands run, call out any performance impact, and include before/after results when touching grid update, collision detection, worker scheduling, or allocation behavior.

## Agent-Specific Instructions

Do not commit generated `zig-out/` or `.zig-cache/` contents. Keep edits scoped, preserve benchmark artifacts unless asked to clean them, and avoid renaming public API symbols without updating imports and examples.
