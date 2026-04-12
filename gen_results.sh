#!/bin/bash

BIN=./zig-out/bin/SpacialGrid

echo "Building..."
zig build -Doptimize=ReleaseFast
echo "Done. Running..."

run() {
    local label="$1"; shift
    echo "=== $label ===" | tee -a ./Results.txt
    $BIN "$@" >> ./Results.txt
    echo "" >> ./Results.txt
}

# Scale entity count
run "10k ents"    count=10000  timeout=3
run "50k ents"    count=50000  timeout=3
run "100k ents"   count=100000 timeout=3
run "150k ents"    count=150000 timeout=3
run "200k ents"    count=200000  timeout=3
run "500k ents"   count=500000 timeout=1
run "1m ents"   count=1000000 timeout=1

# Vary world size at fixed entity count (changes density)
run "150k | small world 500x500"    count=150000 world_w=500  world_h=500  timeout=2
run "150k | large world 2000x2000"  count=150000 world_w=2000 world_h=2000 timeout=2

# Vary entity size
run "150k | small shapes"  count=150000 min_r=1  max_r=4  min_wh=1  max_wh=4  timeout=2
run "150k | large shapes"  count=150000 min_r=20 max_r=40 min_wh=20 max_wh=40 timeout=2

# Shape variety
run "150k | circles only"  count=150000 shape=Circle timeout=2
run "150k | rects only"    count=150000 shape=Rect   timeout=2
run "150k | mixed"         count=150000 shape=All    timeout=2

echo "Results written to Results.txt"
