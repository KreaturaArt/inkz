#!/usr/bin/env bash
# Orchestrates the ink reference harness (plan D19). Called by the mise tasks in mise.toml:
#   setup               fetch ink at the pinned commit and build the harness
#   expected [case...]  regenerate test/ground_truth/<case>.{ink.json,expected} (all by default)
#   random              regenerate test/ground_truth/dotnet_random.expected
#   floats              regenerate test/ground_truth/dotnet_floats.expected
#   paths [case...]     regenerate test/ground_truth/<case>.paths (container paths and hashes)
#   diagnostics         inklecate's errors and warnings for test/ground_truth/diagnostics/*.ink
#   swarm <dir>...      ink's results for generated swarm cases (`zig build swarm-gen`):
#                       <n>.ink.json and <n>.expected, <n>.compile_errors or <n>.timeout
set -euo pipefail

ink_tag="v1.2.1"
ink_commit="35c63e52f1d3"
root="$(cd "$(dirname "$0")/../.." && pwd)"
cases="$root/test/ground_truth"
build="$root/reference/ink_harness_build"
harness() { dotnet "$build/ink_harness.dll" "$@"; }

setup() {
    if [ ! -d "$root/reference/ink/.git" ]; then
        git clone --quiet --depth 1 --branch "$ink_tag" https://github.com/inkle/ink.git \
            "$root/reference/ink"
    fi
    local actual
    actual="$(git -C "$root/reference/ink" rev-parse --short=12 HEAD)"
    if [ "$actual" != "$ink_commit" ]; then
        echo "reference/ink is at $actual, expected $ink_commit ($ink_tag)" >&2
        exit 1
    fi
    dotnet build "$root/tools/ink_harness" -c Release -o "$build" -nologo -v quiet >/dev/null
}

# A case id is a path below test/ground_truth without extension, such as `smoke` or
# `runtime/choices/sticky_choices`. Its source is test/ground_truth/<id>.ink, or else the
# fixture test/fixture/original/<id>.ink, or else the story test/fixture/<id>.ink. Its actions are test/ground_truth/<id>.actions, or
# `play` when that file doesn't exist.
expected_one() {
    local id="$1"
    local source="$cases/$id.ink"
    [ -f "$source" ] || source="$root/test/fixture/original/$id.ink"
    [ -f "$source" ] || source="$root/test/fixture/$id.ink"
    mkdir -p "$(dirname "$cases/$id")"
    local name
    name="$(basename "$id")"
    if [ -f "$source" ]; then
        local flags=()
        # A case can ask for ink's countAllVisits compiler option, as some Tests.cs tests do.
        [ -f "$cases/$id.count_all_visits" ] && flags=(--count-all-visits)
        if ! harness compile "$source" "$cases/$id.ink.json" ${flags[@]+"${flags[@]}"} \
            2> "$cases/$id.compile_errors"; then
            echo "compile failed: $id (see $id.compile_errors)" >&2
            rm -f "$cases/$id.ink.json" "$cases/$id.expected"
            return
        fi
        rm -f "$cases/$id.compile_errors"
    fi
    harness run "$cases/$id.ink.json" "$cases/$id.actions" "$id" > "$cases/$id.expected"
    echo "expected: $id"
}

all_ids() {
    for actions in "$cases"/*.actions; do basename "$actions" .actions; done
    (cd "$root/test/fixture/original" && find runtime -name '*.ink' -not -path '*/includes/*' | sed 's/\.ink$//' | sort)
    # The full stories at the top of test/fixture/.
    (cd "$root/test/fixture" && ls *.ink | sed 's/\.ink$//')
}

expected() {
    if [ "$#" -gt 0 ]; then
        for id in "$@"; do expected_one "$id"; done
        return
    fi
    for id in $(all_ids); do expected_one "$id"; done
}

random() {
    harness random 1000 0 1 42 2147483647 -2147483648 -1 -42 > "$cases/dotnet_random.expected"
    echo "expected: dotnet_random"
}

floats() {
    harness floats > "$cases/dotnet_floats.expected"
    echo "expected: dotnet_floats"
}

paths() {
    local ids=("$@")
    [ "${#ids[@]}" -gt 0 ] || ids=(crime_scene simple_taster_tutorial audit/unicode_paths)
    for id in "${ids[@]}"; do
        harness paths "$cases/$id.ink.json" > "$cases/$id.paths"
        echo "paths: $id"
    done
}

# One harness process per directory; it exits 3 when stories ink can't finish pile up (their
# threads can't be stopped), and a new process goes on from the first case without results.
swarm() {
    [ "$#" -gt 0 ] || { echo "usage: reference.sh swarm <dir>..." >&2; exit 2; }
    for directory in "$@"; do
        local status=3
        while [ "$status" -ne 0 ]; do
            status=0
            harness batch "$directory" 5 2> "$directory/batch.log" || status=$?
            [ "$status" -eq 0 ] || [ "$status" -eq 3 ] || {
                # ink crashed the process (a stack overflow): the story it was running is
                # marked, and the next process skips it.
                local running
                running="$(ls "$directory"/*.running 2>/dev/null | head -n 1)"
                [ -n "$running" ] || { cat "$directory/batch.log" >&2; exit "$status"; }
                mv "$running" "${running%.running}.harness_crash"
            }
        done
        echo "swarm: $directory: $(ls "$directory" | grep -c '\.expected$') played," \
            "$(ls "$directory" | grep -c '\.compile_errors$') rejected," \
            "$(ls "$directory" | grep -c '\.timeout$') timed out," \
            "$(ls "$directory" | grep -c '\.harness_crash$') crashed ink"
    done
}

# Each story's messages exactly as inklecate prints them (`warnings`), for the compiler's
# diagnostics test (P16.12).
diagnostics() {
    local dotnet_version
    dotnet_version="$(dotnet --version | cut -d. -f1-2)"
    for source in "$cases"/diagnostics/*.ink; do
        {
            echo "# generated by tools/ink_harness from ink $ink_tag ($ink_commit) on .NET" \
                "$dotnet_version; regenerate with: mise run reference:diagnostics"
            harness warnings "$source"
        } > "${source%.ink}.expected"
        echo "diagnostics: $(basename "$source" .ink)"
    done
}

command="${1:-}"
shift || true
case "$command" in
    setup) setup ;;
    expected) setup; expected "$@" ;;
    random) setup; random ;;
    paths) setup; paths "$@" ;;
    floats) setup; floats ;;
    swarm) setup; swarm "$@" ;;
    diagnostics) setup; diagnostics ;;
    *) echo "usage: reference.sh setup|expected [case...]|random|paths [case...]" >&2; exit 2 ;;
esac
