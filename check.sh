#!/usr/bin/env bash
# check.sh: checks that docs/api.md matches the doc comments in src/, then
# builds every tests/t_*.mettle and examples/*.mettle in each mode and runs
# it. A program passes when it exits 0. Release builds have had miscompiles, so every
# test runs in debug and in release.
#
#   ./check.sh                  all tests and examples
#   ./check.sh tests/t_atomic   one program
#   METTLE=/path/to/mettle ./check.sh
#
# Every mode carries -s: without it the compiler emits inserted traps as an
# inline exit that alph's crash recovery cannot catch.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 2
METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
OUT="build/check"
MODES=("-s" "-s --release")
mkdir -p "$OUT"

if [ ! -x "$METTLE" ]; then
  echo "no compiler at $METTLE (set METTLE)"
  exit 2
fi

if [ $# -gt 0 ]; then
  tests=()
  for name in "$@"; do tests+=("${name%.mettle}.mettle"); done
else
  tests=(tests/t_*.mettle examples/*.mettle)
fi

fails=0
if [ $# -eq 0 ]; then
  if tools/apidoc.sh --check > "$OUT/apidoc.log" 2>&1; then
    echo "ok    docs/api.md matches src/"
  else
    echo "FAIL  docs/api.md (see $OUT/apidoc.log)"
    sed 's/^/      /' "$OUT/apidoc.log"
    fails=$((fails + 1))
  fi
fi

for src in "${tests[@]}"; do
  name="$(basename "$src" .mettle)"
  for mode in "${MODES[@]}"; do
    tag="${mode//[- ]/}"
    exe="$OUT/$name.$tag"
    log="$OUT/$name.$tag.log"
    # shellcheck disable=SC2086
    if ! "$METTLE" --build $mode "$src" -o "$exe" > "$log" 2>&1; then
      echo "FAIL  $name [$mode] build (see $log)"
      tail -n 8 "$log" | sed 's/^/      /'
      fails=$((fails + 1))
      continue
    fi
    if timeout 60 "$exe" >> "$log" 2>&1; then
      echo "ok    $name [$mode]"
    else
      echo "FAIL  $name [$mode] exit $? (see $log)"
      tail -n 8 "$log" | sed 's/^/      /'
      fails=$((fails + 1))
    fi
  done
done

if [ "$fails" -eq 0 ]; then
  echo "PASS"
else
  echo "$fails failed"
  exit 1
fi
