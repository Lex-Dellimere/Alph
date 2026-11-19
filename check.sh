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
  if tools/apidoc.sh --new --check > "$OUT/apidoc_new.log" 2>&1; then
    echo "ok    docs/reference.md matches the source"
  else
    echo "FAIL  docs/reference.md (see $OUT/apidoc_new.log)"
    sed 's/^/      /' "$OUT/apidoc_new.log"
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
      timeout 60 "$exe" >> "$log" 2>&1
      code=$?
      if [ "$code" -eq 0 ]; then
        if [ "$try" -eq 1 ]; then
          echo "ok    $name [$mode]"
        else
          echo "ok    $name [$mode] (try $try: it asserts deadlines and the machine was busy)"
        fi
        break
      fi
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

# A board tied to this machine by its serial line: the board in QEMU, the
# other end a Linux process, 200 requests and replies between them.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1; then
  bin="$OUT/tether.bin"
  host="$OUT/tether_host"
  log="$OUT/tether.log"
  if ! "$METTLE" --release examples/mcu/tether.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$bin" -I ports/mcu > "$log" 2>&1 ||
     ! "$METTLE" --build -s --release examples/mcu/tether_host.mettle -I ports/host -o "$host" >> "$log" 2>&1; then
    echo "FAIL  mcu/tether build (see $log)"
    fails=$((fails + 1))
  else
    size=$(stat -c %s "$bin")
    port=$((7421 + $$ % 500))
    "$host" "$port" >> "$log" 2>&1 &
    host_pid=$!
    sleep 0.3
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port" -device loader,file="$bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
    board=$?
    wait "$host_pid"
    code=$?
    if [ "$code" -eq 0 ] && [ "$board" -eq 0 ] && [ "$size" -lt "$MCU_LIMIT" ]; then
      echo "ok    mcu/tether [riscv32, $size bytes, with a Linux process on its line]"
    else
      echo "FAIL  mcu/tether: host exit $code, board exit $board, $size bytes (see $log)"
      tail -n 4 "$log" | sed 's/^/      /'
      fails=$((fails + 1))
    fi
  fi
fi

# The same board reached from a third machine, through the one on its line.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1 && [ -f "$OUT/tether.bin" ]; then
  bin="$OUT/tether.bin"
  host="$OUT/relay_host"
  log="$OUT/relay.log"
  if ! "$METTLE" --build -s --release examples/mcu/relay_host.mettle -I ports/host -o "$host" > "$log" 2>&1; then
    echo "FAIL  mcu/relay build (see $log)"
    fails=$((fails + 1))
  else
    port=$((8431 + $$ % 300 * 3))
    "$host" "$port" >> "$log" 2>&1 &
    host_pid=$!
    sleep 0.3
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port" -device loader,file="$bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
    board=$?
    wait "$host_pid"
    code=$?
    if [ "$code" -eq 0 ] && [ "$board" -eq 0 ]; then
      echo "ok    mcu/relay [a third machine reaches the board through the one on its line]"
    else
      echo "FAIL  mcu/relay: hosts exit $code, board exit $board (see $log)"
      tail -n 4 "$log" | sed 's/^/      /'
      fails=$((fails + 1))
    fi
  fi
fi

# The same board programs for a Raspberry Pi Pico 2. They are built, and the
# blink runs on the compiler's model of the chip when a C compiler is here
# to build that model.
if [ "$#" -eq 0 ]; then
  log="$OUT/pico2.log"
  : > "$log"
  built=1
  for name in blink tether asker arm two_a; do
    if ! "$METTLE" --release "examples/mcu/$name.mettle" --target riscv32-none --board pico2 \
        --emit-flat "$OUT/pico2_$name.bin" -I ports/pico2 -I ports/mcu >> "$log" 2>&1; then
      echo "FAIL  pico2/$name build (see $log)"
      fails=$((fails + 1))
      built=0
    fi
  done
  sim="$(dirname "$METTLE")/../tools/riscv-sim/rvsim.c"
  if [ "$built" -eq 1 ] && [ -f "$sim" ] && command -v gcc > /dev/null 2>&1 &&
     gcc -std=c99 -O2 -o "$OUT/rvsim" "$sim" -lm >> "$log" 2>&1; then
    got=$(timeout 30 "$OUT/rvsim" --machine rp2350 --load "$OUT/pico2_blink.bin" --until-ms 3000 2>> "$log" | tr -d '\r\n')
    if [ "$got" = "12345" ]; then
      echo "ok    pico2/blink [on the chip's model, $(stat -c %s "$OUT/pico2_blink.bin") bytes; tether, asker, arm and two build]"
    else
      echo "FAIL  pico2/blink printed '$got' on the model"
      fails=$((fails + 1))
    fi
  elif [ "$built" -eq 1 ]; then
    echo "ok    pico2 [blink, tether, asker, arm and two build; no model here to run them on]"
  fi
fi

# A board that shares work with the machine on its line: the six jobs only
# the board can do all go to it, and it takes some of the rest. Then the
# board is lost in the middle of a batch, then it is reached from a machine
# that is not the one on its line, and last a board whose jobs take 700 ms
# each is waited for. Last the board asks the computer for work.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1; then
  bin="$OUT/arm.bin"
  log="$OUT/arm.log"
  if ! "$METTLE" --release examples/mcu/arm.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$bin" -I ports/mcu > "$log" 2>&1 ||
     ! "$METTLE" --release tests/mcu/slow_board.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$OUT/slow_board.bin" -I ports/mcu >> "$log" 2>&1 ||
     ! "$METTLE" --release tests/mcu/asking_board.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$OUT/asking_board.bin" -I ports/mcu >> "$log" 2>&1 ||
     ! "$METTLE" --build -s --release examples/mcu/arm_host.mettle -I ports/host -o "$OUT/arm_host" >> "$log" 2>&1 ||
     ! "$METTLE" --build -s --release tests/mcu/arm_test.mettle -I ports/host -o "$OUT/arm_test" >> "$log" 2>&1; then
    echo "FAIL  mcu/arm build (see $log)"
    fails=$((fails + 1))
  else
    base=$((9441 + $$ % 300 * 12))
    at=0
    for run in "arm_host" "arm_test lost" "arm_test beyond" "arm_test slow" "arm_test asks"; do
      port=$((base + at * 3))
      at=$((at + 1))
      prog=${run%% *}
      mode=${run#"$prog"}
      board_bin="$bin"
      if [ "$run" = "arm_test slow" ]; then
        board_bin="$OUT/slow_board.bin"
      fi
      if [ "$run" = "arm_test asks" ]; then
        board_bin="$OUT/asking_board.bin"
      fi
      timeout 60 "$OUT/$prog" "$port" $mode > "$log.host" 2>&1 &
      host_pid=$!
      sleep 0.3
      timeout 50 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
        -serial "tcp:127.0.0.1:$port" -device loader,file="$board_bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
      board=$?
      wait "$host_pid"
      code=$?
      cat "$log.host" >> "$log"
      if [ "$code" -eq 0 ] && [ "$board" -eq 0 ]; then
        echo "ok    mcu/$run [$(stat -c %s "$board_bin") bytes: $(tail -n 1 "$log.host")]"
      else
        echo "FAIL  mcu/$run: host exit $code, board exit $board (see $log)"
        tail -n 4 "$log.host" | sed 's/^/      /'
        fails=$((fails + 1))
      fi
    done
  fi
fi

# Both harts of one board: the cores layer with a node on each.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1; then
  bin="$OUT/harts.bin"
  log="$OUT/harts.log"
  if ! "$METTLE" --release examples/mcu/harts.mettle --target riscv32-none --board qemu-virt --isa rv32imac \
      --emit-flat "$bin" -I ports/harts -I ports/mcu > "$log" 2>&1; then
    echo "FAIL  mcu/harts build (see $log)"
    fails=$((fails + 1))
  else
    got=$(timeout 20 qemu-system-riscv32 -M virt -smp 2 -bios none -nographic \
      -device loader,file="$bin",addr=0x80000000,force-raw=on 2>> "$log" | tr -d '\r\n')
    case "$got" in
      *" 2262 ") echo "ok    mcu/harts [riscv32, two harts, $(stat -c %s "$bin") bytes: chunks by hart and primes: $got]" ;;
      *) echo "FAIL  mcu/harts printed '$got'"; fails=$((fails + 1)) ;;
    esac
  fi
fi

# Two boards as one: each in its own QEMU, their serial lines joined.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1 && [ -f "$OUT/tether.bin" ]; then
  bin="$OUT/asker.bin"
  log="$OUT/pair.log"
  if ! "$METTLE" --release examples/mcu/asker.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$bin" -I ports/mcu > "$log" 2>&1; then
    echo "FAIL  mcu/pair build (see $log)"
    fails=$((fails + 1))
  else
    port=$((9431 + $$ % 500))
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port,server=on,wait=off" \
      -device loader,file="$OUT/tether.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1 &
    other=$!
    sleep 0.4
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port" -device loader,file="$bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
    asked=$?
    wait "$other"
    answered=$?
    if [ "$asked" -eq 0 ] && [ "$answered" -eq 0 ]; then
      echo "ok    mcu/pair [two boards, $(stat -c %s "$bin") and $(stat -c %s "$OUT/tether.bin") bytes, on one serial line]"
    else
      echo "FAIL  mcu/pair: asking board exit $asked, answering board exit $answered (see $log)"
      fails=$((fails + 1))
    fi
  fi
fi

# Two boards that share work with no bigger machine: each does one kind for
# the other and asks the other for the kind it cannot do.
if [ "$#" -eq 0 ] && command -v qemu-system-riscv32 > /dev/null 2>&1; then
  log="$OUT/two.log"
  if ! "$METTLE" --release examples/mcu/two_a.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$OUT/two_a.bin" -I ports/mcu > "$log" 2>&1 ||
     ! "$METTLE" --release examples/mcu/two_b.mettle --target riscv32-none --board qemu-virt \
      --emit-flat "$OUT/two_b.bin" -I ports/mcu >> "$log" 2>&1; then
    echo "FAIL  mcu/two build (see $log)"
    fails=$((fails + 1))
  else
    port=$((14431 + $$ % 500))
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port,server=on,wait=off" \
      -device loader,file="$OUT/two_b.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1 &
    other=$!
    sleep 0.4
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port" -device loader,file="$OUT/two_a.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
    first=$?
    wait "$other"
    second=$?
    if [ "$first" -eq 0 ] && [ "$second" -eq 0 ]; then
      echo "ok    mcu/two [two boards of $(stat -c %s "$OUT/two_a.bin") bytes each do a kind of work for the other]"
    else
      echo "FAIL  mcu/two: first board exit $first, second board exit $second (see $log)"
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
