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
MCU_LIMIT=5120  # bytes: the whole RISC-V image, board startup included
# Tests of the first runtime that assert millisecond deadlines. On a busy
# machine they miss them, so they get three tries and the output says when
# one needed more than the first. Every other test gets one.
TIMED="t_bound t_fair t_shed t_shed_edge t_timer_handoff t_storm"
mkdir -p "$OUT"

# mettle.deps is generated (mbuild writes it on every build). Without mbuild,
# write the two mappings the compiler needs, in mbuild's own block so a later
# mbuild run replaces them instead of warning.
# alph is a Mettle project: no Erlang or Elixir sources may be tracked.
foreign=$(git ls-files 2>/dev/null | grep -E '\.(erl|hrl|ex|exs)$')
if [ -n "$foreign" ]; then
  echo "FAIL  Erlang/Elixir sources are tracked in git:"
  echo "$foreign"
  exit 1
fi

if [ ! -f mettle.deps ]; then
  printf '# >>> mbuild: generated, edits inside this block are overwritten\nalph=./src\ncryptex=../cryptex/src\n# <<< mbuild\n' > mettle.deps
fi

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
    if ! "$METTLE" --build $mode "$src" -I ports/host -o "$exe" > "$log" 2>&1; then
      echo "FAIL  $name [$mode] build (see $log)"
      tail -n 8 "$log" | sed 's/^/      /'
      fails=$((fails + 1))
      continue
    fi
    tries=1
    case " $TIMED " in *" $name "*) tries=3 ;; esac
    try=1
    while true; do
      if timeout 60 "$exe" >> "$log" 2>&1; then
        if [ "$try" -eq 1 ]; then
          echo "ok    $name [$mode]"
        else
          echo "ok    $name [$mode] (try $try: it asserts deadlines and the machine was busy)"
        fi
        break
      fi
      code=$?
      if [ "$try" -ge "$tries" ]; then
        echo "FAIL  $name [$mode] exit $code (see $log)"
        tail -n 8 "$log" | sed 's/^/      /'
        fails=$((fails + 1))
        break
      fi
      try=$((try + 1))
    done
  done
done

# The core on a bare 32-bit RISC-V board: it must run and stay small.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1; then
  bin="$OUT/blink.bin"
  log="$OUT/blink.log"
  if ! "$METTLE" --release examples/mcu/blink.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$bin" -I ports/mcu > "$log" 2>&1; then
    echo "FAIL  mcu/blink build (see $log)"
    fails=$((fails + 1))
  else
    size=$(stat -c %s "$bin")
    got=$(timeout 20 qemu-system-riscv32 -M virt -bios none -nographic \
      -device loader,file="$bin",addr=0x80000000,force-raw=on 2>> "$log" | tr -d '\r\n')
    if [ "$got" = "12345" ] && [ "$size" -lt "$MCU_LIMIT" ]; then
      echo "ok    mcu/blink [riscv32, $size bytes]"
    else
      echo "FAIL  mcu/blink printed '$got', $size bytes (limit $MCU_LIMIT)"
      fails=$((fails + 1))
    fi
  fi
fi

if [ "$fails" -eq 0 ]; then
  echo "PASS"
else
  echo "$fails failed"
  exit 1
fi
