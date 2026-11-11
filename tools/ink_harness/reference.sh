#!/usr/bin/env bash
# Orchestrates the ink reference harness (plan D19). Called by the mise tasks in mise.toml:
#   setup               fetch ink at the pinned commit and build the harness
#   expected [case...]  regenerate test/ground_truth/<case>.{ink.json,expected} (all by default)
#   random              regenerate test/ground_truth/dotnet_random.expected
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

command="${1:-}"
shift || true
case "$command" in
    setup) setup ;;
    expected) setup; expected "$@" ;;
    random) setup; random ;;
    *) echo "usage: reference.sh setup|expected [case...]|random" >&2; exit 2 ;;
esac
