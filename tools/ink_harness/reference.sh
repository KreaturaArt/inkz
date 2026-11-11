#!/usr/bin/env bash
# Orchestrates the ink reference harness (plan D19). Called by the mise tasks in mise.toml:
#   setup               fetch ink at the pinned commit and build the harness
#   expected [case...]  regenerate test/ground_truth/<case>.{ink.json,expected}
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

expected_one() {
    local name="$1"
    if [ -f "$cases/$name.ink" ]; then
        harness compile "$cases/$name.ink" "$cases/$name.ink.json"
    fi
    harness run "$cases/$name.ink.json" "$cases/$name.actions" > "$cases/$name.expected"
    echo "expected: $name"
}

expected() {
    if [ "$#" -gt 0 ]; then
        for name in "$@"; do expected_one "$name"; done
        return
    fi
    for actions in "$cases"/*.actions; do expected_one "$(basename "$actions" .actions)"; done
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
