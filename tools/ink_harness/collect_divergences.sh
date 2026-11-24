#!/usr/bin/env bash
# Collects the divergent cases of a differential swarm run for the nightly workflow
# (.github/workflows/differential.yml):
#   collect_divergences.sh <dir> <check.log> <out> [reductions_max]
# copies each case that `zig build swarm-check -- <dir>` reported in <check.log> (its
# `<n>.*` files) to <out>/<n>/, and runs `zig build swarm-reduce` on the first
# <reductions_max> of them (default 3), each bounded to 10 minutes, writing
# <out>/<n>/reduce.log (the reduced swarm configuration) and the candidates it ran under
# <out>/<n>/reduce/.
set -euo pipefail

[ "$#" -ge 3 ] || { echo "usage: collect_divergences.sh <dir> <check.log> <out> [reductions_max]" >&2; exit 2; }
directory="$1"
log="$2"
out="$3"
reductions_max="${4:-3}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
harness="$root/reference/ink_harness_build/ink_harness.dll"

# GNU timeout (on the runner); without it (macOS) a reduction runs unbounded.
bound=()
command -v timeout >/dev/null && bound=(timeout 600)

mkdir -p "$out"
cp "$log" "$out/"
[ -f "$directory/batch.log" ] && cp "$directory/batch.log" "$out/"

# A divergence line is `<n>: <kind>: ...`; the `  swarm: ...` lines under it are indented.
names="$(grep -oE '^[0-9]+: ' "$log" | sed 's/: $//' | sort -u || true)"
[ -n "$names" ] || { echo "no divergent cases in $log"; exit 0; }

reductions=0
for name in $names; do
    mkdir -p "$out/$name"
    cp "$directory/$name".* "$out/$name/"
    [ "$reductions" -lt "$reductions_max" ] || continue
    reductions=$((reductions + 1))
    echo "reducing $name"
    status=0
    ${bound[@]+"${bound[@]}"} zig build swarm-reduce -Doptimize=ReleaseSafe -- \
        "$directory" "$name" --harness "$harness" > "$out/$name/reduce.log" 2>&1 || status=$?
    [ "$status" -eq 0 ] || echo "swarm-reduce $name exited with $status" >> "$out/$name/reduce.log"
    tail -n 3 "$out/$name/reduce.log"
    # Every candidate the reducer ran, numbered in order; reduce.log names the result.
    if [ -d "$directory/reduce-$name" ]; then cp -R "$directory/reduce-$name" "$out/$name/reduce"; fi
done
echo "collected $(echo "$names" | wc -l | tr -d ' ') divergent cases in $out"
