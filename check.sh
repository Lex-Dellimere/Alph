#!/usr/bin/env bash
# check.sh: checks that docs/api.md matches the doc comments in src/, then
# builds every tests/t_*.mettle and examples/*.mettle in each mode and runs
# it. A program passes when it exits 0. Release builds have had miscompiles, so every
# test runs in debug and in release.
#
#   ./check.sh                  all tests and examples, then the board steps
#   ./check.sh --quick          the new layers' tests and examples in release, then the board steps
#   ./check.sh tests/t_atomic   one program (or several)
#   JOBS=4 ./check.sh           at most 4 builds or runs at once (default: one per CPU)
#   METTLE=/path/to/mettle ./check.sh
#
# Every mode carries -s: without it the compiler emits inserted traps as an
# inline exit that alph's crash recovery cannot catch.
#
# The order of work: everything is built first, JOBS at a time. Then the
# programs run, JOBS at a time, except the ones listed in ALONE below, which
# run one after another once the rest are done. Then the board steps, one
# after another. Results are printed in the same order as a serial run (tests
# then examples, debug then release), once all programs have run. JOBS=1 is
# a serial run.

set -u
started=$SECONDS
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 2
METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
OUT="build/check"
MODES=("-s" "-s --release")
MCU_LIMIT=5120  # bytes: the whole RISC-V image, board startup included
JOBS="${JOBS:-$(nproc)}"
# Tests of the first runtime that assert millisecond deadlines. On a busy
# machine they miss them, so they get three tries and the output says when
# one needed more than the first. Every other test gets one. They run alone,
# one at a time, after the parallel part, with nothing else running.
TIMED="t_bound t_fair t_shed t_shed_edge t_timer_handoff t_storm"
# Other tests that fail when the machine is loaded run alone too. The tests
# that measure where work goes by timing it (t_places t_far t_own t_machine
# t_three t_batch t_time t_wheel t_link t_parcel t_door t_seal t_poll t_proc
# t_cores) each passed 20 of 20 runs in both modes beside a full parallel
# build, so none was listed. Add a test here if it fails only in a full run.
# t_places is here since examples/frames joined the parallel part: with it
# running, the GPU was once tried only once in 300 small jobs, not twice.
LOADED="t_places"
ALONE="$TIMED $LOADED"
# Programs that listen on ports, as <name>:<lock>. They run in the parallel
# part, but two with the same lock never run at once: their ports could be
# the same. Each lock is named after the lowest port of its range.
# - Tests on ports worked out from their pid: t_door 8000-9999 and t_poll
#   9000-9899 overlap; t_link 12000-31999 overlaps t_parcel 13000-16999,
#   t_machine 14000-17999, t_three 15000-20999, t_own 21000-26999 and
#   t_wide 26000-31999, t_long 13000-16999, t_big 22000-25999 and
#   t_bundle 28000-30999, t_pieces 24000-27999 and t_clock 19000-24999; t_far
#   10000-10999 and t_seal 11000-11899 overlap only their own other mode.
# - Examples on fixed ports: their debug and release runs take the same one.
# - examples/record writes one file, so its two runs take one lock too.
PORTS="t_door:8000 t_poll:8000 t_link:12000 t_parcel:12000 t_machine:12000
  t_three:12000 t_own:12000 t_back:12000 t_wide:12000 t_long:12000
  t_big:12000 t_bundle:12000 t_pieces:12000 t_clock:12000 t_far:10000 t_seal:11000
  far:7401 talk:7411 run:7441 share:7451 picture:7471 frames:7481 record:record"
# --quick: the new layers only, for use between small edits.
QUICK_TESTS="t_actor t_cores t_time t_wheel t_places t_life t_link t_seal t_door t_far t_parcel t_poll t_proc t_tether t_batch t_machine t_three t_own t_cross t_back t_once t_serial t_tether_sure t_wide t_long t_big t_bundle t_pieces t_clock t_record"
QUICK_EXAMPLES="count primes spread render far run share picture frames tiles talk record"
mkdir -p "$OUT"

# Any exit, Ctrl-C included, stops every process this script started and
# anything those started: a test left running holds a CPU and its ports.
# Programs run under timeout, which puts itself in a process group of its own,
# so they are found by parent pid, not by process group.
descendants() {
  local child
  for child in $(ps -o pid= --ppid "$1"); do
    echo "$child"
    descendants "$child"
  done
}
# A second Ctrl-C, or the copy of the signal that reaches the script through
# its process group, must not cut this short, so signals are ignored while it
# runs. It goes over the tree twice: a job can start its next program between
# the listing and the kill.
stop_children() {
  local pids _
  trap '' INT TERM
  for _ in 1 2; do
    pids=$(descendants $$)
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -TERM $pids 2> /dev/null
  done
  wait 2> /dev/null
}
trap stop_children EXIT
trap 'trap "" INT TERM; echo "interrupted"; exit 130' INT TERM

# Runs the function $1 once for each further argument, at most JOBS at once,
# and returns when all are done. Each job writes its results to files, never
# to the terminal, so nothing interleaves.
# set -m puts each job in a process group of its own. Then Ctrl-C, which goes
# to the whole foreground group, reaches only this script, which stops the
# jobs whole. Without it a job and flock die at once and leave the program
# they started running, no longer below this script.
pool() {
  local fn="$1" item
  shift
  set -m
  for item in "$@"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    "$fn" "$item" < /dev/null &
  done
  wait
  set +m
}

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

case "$JOBS" in
  '' | *[!0-9]* | 0) echo "JOBS must be a number above 0, not '$JOBS'"; exit 2 ;;
esac

if [ ! -x "$METTLE" ]; then
  echo "no compiler at $METTLE (set METTLE)"
  exit 2
fi

full=0   # the docs check, every program in both modes
boards=0 # the board steps
if [ "${1:-}" = "--quick" ]; then
  shift
  boards=1
  MODES=("-s --release")
  tests=()
  for name in $QUICK_TESTS; do tests+=("tests/$name.mettle"); done
  for name in $QUICK_EXAMPLES; do tests+=("examples/$name.mettle"); done
elif [ $# -gt 0 ]; then
  tests=()
  for name in "$@"; do tests+=("${name%.mettle}.mettle"); done
else
  full=1
  boards=1
  tests=(tests/t_*.mettle examples/*.mettle)
fi
qemu=0
command -v qemu-system-riscv32 > /dev/null 2>&1 && qemu=1

fails=0
if [ "$full" -eq 1 ]; then
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

# Building. A program's two modes are built one after the other in one job:
# the compiler names its object file after the output without its extension,
# so t_x.s and t_x.srelease both write t_x.o.
# Each build or run writes what it would print to $OUT/<name>.<tag>.result.
build_program() {
  local src="$1" name mode tag exe log result
  name="$(basename "$src" .mettle)"
  for mode in "${MODES[@]}"; do
    tag="${mode//[- ]/}"
    exe="$OUT/$name.$tag"
    log="$OUT/$name.$tag.log"
    result="$OUT/$name.$tag.result"
    : > "$result"
    rm -f "$exe"
    # shellcheck disable=SC2086
    if ! "$METTLE" --build $mode "$src" -I ports/host -o "$exe" > "$log" 2>&1; then
      {
        echo "FAIL  $name [$mode] build (see $log)"
        tail -n 8 "$log" | sed 's/^/      /'
      } > "$result"
    fi
  done
}

# A program in one mode, given as "<src>|<mode>". It runs only if it built.
run_program() {
  local src="${1%%|*}" mode="${1#*|}" name tag exe log result tries try code lock entry
  name="$(basename "$src" .mettle)"
  tag="${mode//[- ]/}"
  exe="$OUT/$name.$tag"
  log="$OUT/$name.$tag.log"
  result="$OUT/$name.$tag.result"
  [ -s "$result" ] && return
  tries=1
  case " $TIMED " in *" $name "*) tries=3 ;; esac
  lock=()
  for entry in $PORTS; do
    [ "${entry%%:*}" = "$name" ] && lock=(flock "$OUT/ports.${entry#*:}.lock")
  done
  try=1
  while true; do
    "${lock[@]}" timeout 60 "$exe" >> "$log" 2>&1
    code=$?
    if [ "$code" -eq 0 ]; then
      if [ "$try" -eq 1 ]; then
        echo "ok    $name [$mode]" > "$result"
      else
        echo "ok    $name [$mode] (try $try: it asserts deadlines and the machine was busy)" > "$result"
      fi
      break
    fi
    if [ "$try" -ge "$tries" ]; then
      {
        echo "FAIL  $name [$mode] exit $code (see $log)"
        tail -n 8 "$log" | sed 's/^/      /'
      } > "$result"
      break
    fi
    try=$((try + 1))
  done
}

# The board images and the Linux programs on their lines are built here, with
# the rest, and each board step further down runs what was built. A step's
# builds stay together in one job, in the order the step had them, so its log
# reads as before. The exit status goes to $OUT/<step>.built.
build_board() {
  local step="$1" bin host log status=0
  case "$step" in
    blink)
      bin="$OUT/blink.bin"
      log="$OUT/blink.log"
      "$METTLE" --release examples/mcu/blink.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$bin" -I ports/mcu > "$log" 2>&1 || status=1
      ;;
    tether)
      bin="$OUT/tether.bin"
      host="$OUT/tether_host"
      log="$OUT/tether.log"
      "$METTLE" --release examples/mcu/tether.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$bin" -I ports/mcu > "$log" 2>&1 &&
      "$METTLE" --build -s --release examples/mcu/tether_host.mettle -I ports/host -o "$host" >> "$log" 2>&1 || status=1
      ;;
    relay)
      host="$OUT/relay_host"
      log="$OUT/relay.log"
      "$METTLE" --build -s --release examples/mcu/relay_host.mettle -I ports/host -o "$host" > "$log" 2>&1 || status=1
      ;;
    pico2)
      # The four images, then the chip's model when a C compiler is here.
      # status 2: the images built but there is no model to run them on.
      log="$OUT/pico2.log"
      : > "$log"
      for name in blink tether asker arm two_a; do
        if ! "$METTLE" --release "examples/mcu/$name.mettle" --target riscv32-none --board pico2 \
            --emit-flat "$OUT/pico2_$name.bin" -I ports/pico2 -I ports/mcu >> "$log" 2>&1; then
          echo "$name" >> "$OUT/pico2.unbuilt"
          status=1
        fi
      done
      # What speaks to the tether image on the model, and checks its answers.
      "$METTLE" --build -s --release tests/mcu/model_line.mettle -I ports/host -o "$OUT/model_line" >> "$log" 2>&1 || status=1
      sim="$(dirname "$METTLE")/../tools/riscv-sim/rvsim.c"
      if [ "$status" -eq 0 ] && ! { [ -f "$sim" ] && command -v gcc > /dev/null 2>&1 &&
         gcc -std=c99 -O2 -o "$OUT/rvsim" "$sim" -lm >> "$log" 2>&1; }; then
        status=2
      fi
      ;;
    arm)
      bin="$OUT/arm.bin"
      log="$OUT/arm.log"
      "$METTLE" --release examples/mcu/arm.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$bin" -I ports/mcu > "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/slow_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/slow_board.bin" -I ports/mcu >> "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/asking_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/asking_board.bin" -I ports/mcu >> "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/safe_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/safe_board.bin" -I ports/mcu >> "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/second_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/second_board.bin" -I ports/mcu >> "$log" 2>&1 &&
      "$METTLE" --build -s --release examples/mcu/arm_host.mettle -I ports/host -o "$OUT/arm_host" >> "$log" 2>&1 &&
      "$METTLE" --build -s --release examples/mcu/line_watch.mettle -I ports/host -o "$OUT/line_watch" >> "$log" 2>&1 &&
      "$METTLE" --build -s --release tests/mcu/arm_test.mettle -I ports/host -o "$OUT/arm_test" >> "$log" 2>&1 || status=1
      ;;
    harts)
      bin="$OUT/harts.bin"
      log="$OUT/harts.log"
      "$METTLE" --release examples/mcu/harts.mettle --target riscv32-none --board qemu-virt --isa rv32imac \
        --emit-flat "$bin" -I ports/harts -I ports/mcu > "$log" 2>&1 || status=1
      ;;
    pair)
      bin="$OUT/asker.bin"
      log="$OUT/pair.log"
      "$METTLE" --release examples/mcu/asker.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$bin" -I ports/mcu > "$log" 2>&1 || status=1
      ;;
    sure)
      log="$OUT/sure.log"
      "$METTLE" --release tests/mcu/sure_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/sure_board.bin" -I ports/mcu > "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/sure_arm_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/sure_arm_board.bin" -I ports/mcu >> "$log" 2>&1 &&
      "$METTLE" --build -s --release tests/mcu/sure_host.mettle -I ports/host -o "$OUT/sure_host" >> "$log" 2>&1 &&
      "$METTLE" --build -s --release tests/mcu/sure_arm.mettle -I ports/host -o "$OUT/sure_arm" >> "$log" 2>&1 || status=1
      ;;
    irq)
      log="$OUT/irq.log"
      "$METTLE" --release tests/mcu/irq_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/irq_board.bin" -I ports/mcu > "$log" 2>&1 || status=1
      ;;
    once)
      # The asking board also as a Pico 2 image, for the board's own source
      # of fresh numbers: built, not run.
      log="$OUT/once.log"
      "$METTLE" --release tests/mcu/once_asker.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/once_asker.bin" -I ports/mcu > "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/once_worker.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/once_worker.bin" -I ports/mcu >> "$log" 2>&1 &&
      "$METTLE" --release tests/mcu/once_asker.mettle --target riscv32-none --board pico2 \
        --emit-flat "$OUT/pico2_once_asker.bin" -I ports/pico2 -I ports/mcu >> "$log" 2>&1 || status=1
      ;;
    clock)
      log="$OUT/clock.log"
      "$METTLE" --release tests/mcu/clock_board.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/clock_board.bin" -I ports/mcu > "$log" 2>&1 &&
      "$METTLE" --build -s --release tests/mcu/clock_host.mettle -I ports/host -o "$OUT/clock_host" >> "$log" 2>&1 || status=1
      ;;
    two)
      log="$OUT/two.log"
      "$METTLE" --release examples/mcu/two_a.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/two_a.bin" -I ports/mcu > "$log" 2>&1 &&
      "$METTLE" --release examples/mcu/two_b.mettle --target riscv32-none --board qemu-virt \
        --emit-flat "$OUT/two_b.bin" -I ports/mcu >> "$log" 2>&1 || status=1
      ;;
    arm64)
      # Every test and example of the new layers as an object for 64-bit ARM
      # Linux. Linking needs an ARM machine.
      for src in tests/t_actor tests/t_cores tests/t_cross tests/t_time tests/t_wheel tests/t_places \
          tests/t_life tests/t_link tests/t_seal tests/t_door tests/t_far tests/t_parcel tests/t_poll \
          tests/t_proc tests/t_tether tests/t_batch tests/t_machine tests/t_three tests/t_own \
          tests/t_serial tests/t_back tests/t_once tests/t_wide tests/t_long tests/t_big tests/t_bundle tests/t_pieces tests/t_clock tests/t_record examples/record examples/tiles examples/render examples/share \
          examples/picture examples/frames examples/primes examples/run examples/count examples/spread examples/far examples/talk \
          examples/mcu/arm_host examples/mcu/tether_host examples/mcu/relay_host tests/mcu/arm_test; do
        name=$(basename "$src")
        if ! "$METTLE" -s --release --target aarch64-linux "$src.mettle" -I ports/arm64 -I ports/host \
            -o "$OUT/arm64_$name.o" > "$OUT/arm64_$name.log" 2>&1; then
          echo "$name" >> "$OUT/arm64.unbuilt"
          status=1
        fi
      done
      ;;
  esac
  echo "$status" > "$OUT/$step.built"
}
built() { [ "$(cat "$OUT/$1.built" 2> /dev/null)" = "${2:-0}" ]; }

board_steps=()
if [ "$boards" -eq 1 ]; then
  board_steps=(pico2 arm64)
  [ "$qemu" -eq 1 ] && board_steps+=(blink tether relay arm harts pair two once clock sure irq)
  rm -f "$OUT"/*.built "$OUT/pico2.unbuilt" "$OUT/arm64.unbuilt"
fi

echo "..    building ${#tests[@]} programs in ${#MODES[@]} mode(s) and ${#board_steps[@]} board steps, $JOBS at a time"
pool build_program "${tests[@]}"
pool build_board "${board_steps[@]}"

# Running. The programs not in ALONE run JOBS at a time; then the ones in it
# run one at a time, with nothing else running.
together=()
alone=()
for src in "${tests[@]}"; do
  name="$(basename "$src" .mettle)"
  for mode in "${MODES[@]}"; do
    case " $ALONE " in
      *" $name "*) alone+=("$src|$mode") ;;
      *) together+=("$src|$mode") ;;
    esac
  done
done
echo "..    running ${#together[@]} programs $JOBS at a time ($((SECONDS - started))s so far)"
pool run_program "${together[@]}"
if [ "${#alone[@]}" -gt 0 ]; then
  echo "..    running ${#alone[@]} programs alone ($((SECONDS - started))s so far)"
  JOBS=1 pool run_program "${alone[@]}"
fi

for src in "${tests[@]}"; do
  name="$(basename "$src" .mettle)"
  for mode in "${MODES[@]}"; do
    result="$OUT/$name.${mode//[- ]/}.result"
    cat "$result"
    grep -q '^FAIL' "$result" && fails=$((fails + 1))
  done
done

# The board steps run one after another: each takes ports worked out from
# this script's pid, and some of those ranges overlap.

# The core on a bare 32-bit RISC-V board: it must run and stay small.
step_blink() {
  local bin="$OUT/blink.bin" log="$OUT/blink.log" size got
  if ! built blink; then
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
}

# A board tied to this machine by its serial line: the board in QEMU, the
# other end a Linux process, 200 requests and replies between them.
step_tether() {
  local bin="$OUT/tether.bin" host="$OUT/tether_host" log="$OUT/tether.log" size port host_pid board code
  if ! built tether; then
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
}

# The same board reached from a third machine, through the one on its line.
step_relay() {
  local bin="$OUT/tether.bin" host="$OUT/relay_host" log="$OUT/relay.log" port host_pid board code
  [ -f "$OUT/tether.bin" ] || return
  if ! built relay; then
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
}

# The same board programs for a Raspberry Pi Pico 2. They are built, and the
# blink runs on the compiler's model of the chip when a C compiler is here
# to build that model.
step_pico2() {
  local log="$OUT/pico2.log" name got
  if built pico2 1; then
    while read -r name; do
      echo "FAIL  pico2/$name build (see $log)"
      fails=$((fails + 1))
    done < "$OUT/pico2.unbuilt"
  elif built pico2; then
    got=$(timeout 30 "$OUT/rvsim" --machine rp2350 --load "$OUT/pico2_blink.bin" --until-ms 3000 2>> "$log" | tr -d '\r\n')
    if [ "$got" = "12345" ]; then
      echo "ok    pico2/blink [on the chip's model, $(stat -c %s "$OUT/pico2_blink.bin") bytes; asker and two build]"
    else
      echo "FAIL  pico2/blink printed '$got' on the model"
      fails=$((fails + 1))
    fi
    # The tether image on the model: fifty questions come in on the chip's
    # UART at 115,200 baud, as a computer on the line would send them, and
    # its fifty answers are read back. Any use of the chip the model finds
    # wrong ends the run.
    "$OUT/model_line" script 50 > "$OUT/pico2_line.script"
    got=$(timeout 60 "$OUT/rvsim" --machine rp2350 --load "$OUT/pico2_tether.bin" --until-ms 400 --strict-fatal \
      --uart-script "$OUT/pico2_line.script" 2>> "$log" | "$OUT/model_line" check 50)
    if [ "$got" = "50 answers over the board's UART, 0 wrong" ]; then
      echo "ok    pico2/tether [on the chip's model, $(stat -c %s "$OUT/pico2_tether.bin") bytes: $got, at 115,200 baud]"
    else
      echo "FAIL  pico2/tether on the model: '$got' (see $log)"
      fails=$((fails + 1))
    fi
    # The arm image the same way: the computer's side asks who does each
    # kind, then for six angles, four chunks of primes, and moves that must
    # not be made twice, one of them sent a second time.
    "$OUT/model_line" arm > "$OUT/pico2_arm.script"
    got=$(timeout 60 "$OUT/rvsim" --machine rp2350 --load "$OUT/pico2_arm.bin" --until-ms 400 --strict-fatal \
      --uart-script "$OUT/pico2_arm.script" 2>> "$log" | "$OUT/model_line" armcheck | tail -n 1)
    if [ "$got" = "18 answers over the board's UART, 0 wrong" ]; then
      echo "ok    pico2/arm [on the chip's model, $(stat -c %s "$OUT/pico2_arm.bin") bytes: angles, primes and a move made once though asked for twice]"
    else
      echo "FAIL  pico2/arm on the model: '$got' (see $log)"
      fails=$((fails + 1))
    fi
  else
    echo "ok    pico2 [blink, tether, asker, arm and two build; no model here to run them on]"
  fi
}

# A board that shares work with the machine on its line: the six jobs only
# the board can do all go to it, and it takes some of the rest. Then the
# board is lost in the middle of a batch, then it is reached from a machine
# that is not the one on its line, and last a board whose jobs take 700 ms
# each is waited for.
step_arm() {
  local bin="$OUT/arm.bin" log="$OUT/arm.log" base at run port prog mode board_bin host_pid board code
  if ! built arm; then
    echo "FAIL  mcu/arm build (see $log)"
    fails=$((fails + 1))
  else
    base=$((9441 + $$ % 300 * 12))
    at=0
    for run in "arm_host" "arm_test lost" "arm_test beyond" "arm_test slow" "arm_test asks" "arm_test quiet" "arm_test passes"; do
      port=$((base + at * 3))
      at=$((at + 1))
      prog=${run%% *}
      mode=${run#"$prog"}
      board_bin="$bin"
      if [ "$run" = "arm_test slow" ]; then
        board_bin="$OUT/slow_board.bin"
      fi
      if [ "$run" = "arm_test asks" ] || [ "$run" = "arm_test passes" ]; then
        board_bin="$OUT/asking_board.bin"
      fi
      if [ "$run" = "arm_test quiet" ]; then
        board_bin="$OUT/safe_board.bin"
      fi
      # shellcheck disable=SC2086
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
}

# The arm example over a serial device in place of a TCP port: QEMU gives
# its serial line a pseudo-terminal, and the computer's side opens that as
# it would open a real board's /dev/ttyUSB0.
step_device() {
  local log="$OUT/device.log" board_pid dev n code board
  built arm || return
  : > "$log"
  timeout 50 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
    -serial pty -device loader,file="$OUT/arm.bin",addr=0x80000000,force-raw=on > "$log" 2>&1 &
  board_pid=$!
  n=0
  until grep -q '/dev/pts/' "$log" || [ "$n" -ge 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  dev=$(grep -o '/dev/pts/[0-9]*' "$log" | head -n 1)
  timeout 40 "$OUT/arm_host" "$dev" > "$log.host" 2>&1
  code=$?
  wait "$board_pid"
  board=$?
  cat "$log.host" >> "$log"
  if [ -n "$dev" ] && [ "$code" -eq 0 ] && [ "$board" -eq 0 ]; then
    echo "ok    mcu/device [the arm example with the board on a serial device, not a TCP port]"
  else
    echo "FAIL  mcu/device: host exit $code, board exit $board, device '$dev' (see $log)"
    fails=$((fails + 1))
  fi
  # The tool for the first day with a real board: it asks the board's door
  # three questions over the same kind of device and shows the answers.
  timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
    -serial pty -device loader,file="$OUT/arm.bin",addr=0x80000000,force-raw=on > "$log.watch" 2>&1 &
  board_pid=$!
  n=0
  until grep -q '/dev/pts/' "$log.watch" || [ "$n" -ge 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  dev=$(grep -o '/dev/pts/[0-9]*' "$log.watch" | head -n 1)
  timeout 20 "$OUT/line_watch" "$dev" 8 3 > "$log.host" 2>&1
  code=$?
  kill "$board_pid" 2> /dev/null
  wait "$board_pid" 2> /dev/null
  cat "$log.host" >> "$log"
  if [ "$code" -eq 0 ] && [ "$(grep -c '(here), arg 1' "$log.host")" -eq 3 ]; then
    echo "ok    mcu/watch [line_watch shows a board's three answers on a serial device]"
  else
    echo "FAIL  mcu/watch: exit $code (see $log)"
    fails=$((fails + 1))
  fi
}

# One computer with two boards, each on a serial line of its own: work only
# a board can do goes to both.
step_lines() {
  local log="$OUT/arm.log" port host_pid first_pid first second code
  built arm || return
  port=$((16431 + $$ % 300 * 3))
  timeout 60 "$OUT/arm_test" "$port" two > "$log.host" 2>&1 &
  host_pid=$!
  sleep 0.3
  timeout 50 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
    -serial "tcp:127.0.0.1:$port" -device loader,file="$OUT/arm.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1 &
  first_pid=$!
  sleep 0.5
  timeout 50 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
    -serial "tcp:127.0.0.1:$((port + 1))" -device loader,file="$OUT/second_board.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
  second=$?
  wait "$first_pid"
  first=$?
  wait "$host_pid"
  code=$?
  cat "$log.host" >> "$log"
  if [ "$code" -eq 0 ] && [ "$first" -eq 0 ] && [ "$second" -eq 0 ]; then
    echo "ok    mcu/arm_test two [$(tail -n 1 "$log.host")]"
  else
    echo "FAIL  mcu/arm_test two: host exit $code, boards exit $first and $second (see $log)"
    tail -n 4 "$log.host" | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

# Both harts of one board: the cores layer with a node on each.
step_harts() {
  local bin="$OUT/harts.bin" log="$OUT/harts.log" got
  if ! built harts; then
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
}

# Two boards as one: each in its own QEMU, their serial lines joined.
step_pair() {
  local bin="$OUT/asker.bin" log="$OUT/pair.log" port other asked answered
  [ -f "$OUT/tether.bin" ] || return
  if ! built pair; then
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
}

# Two boards that share work with no bigger machine: each does one kind for
# the other and asks the other for the kind it cannot do.
step_two() {
  local log="$OUT/two.log" port other first second
  if ! built two; then
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
}

# A board asks another for work done at most once, with answers lost and
# both boards forgetting everything once: no job is done twice.
step_once() {
  local log="$OUT/once.log" port other asked worked
  if ! built once; then
    echo "FAIL  mcu/once build (see $log)"
    fails=$((fails + 1))
  else
    port=$((16431 + $$ % 500))
    timeout 40 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port,server=on,wait=off" \
      -device loader,file="$OUT/once_worker.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1 &
    other=$!
    sleep 0.4
    timeout 40 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port" -device loader,file="$OUT/once_asker.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
    asked=$?
    wait "$other"
    worked=$?
    if [ "$asked" -eq 0 ] && [ "$worked" -eq 0 ]; then
      echo "ok    mcu/once [a board of $(stat -c %s "$OUT/once_asker.bin") bytes asks another for 32 jobs done at most once: answers lost, both forget everything once, none done twice]"
    else
      echo "FAIL  mcu/once: asking board exit $asked, working board exit $worked (see $log)"
      fails=$((fails + 1))
    fi
  fi
}

# A board's stamps in the machines' time: forty jobs each give back what the
# board's clock read, and each reading falls in the moment its job was out.
step_clock() {
  local log="$OUT/clock.log" port host_pid board code
  if ! built clock; then
    echo "FAIL  mcu/clock build (see $log)"
    fails=$((fails + 1))
  else
    port=$((17431 + $$ % 500))
    timeout 40 "$OUT/clock_host" "$port" > "$log.host" 2>&1 &
    host_pid=$!
    sleep 0.3
    timeout 30 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
      -serial "tcp:127.0.0.1:$port" -device loader,file="$OUT/clock_board.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
    board=$?
    wait "$host_pid"
    code=$?
    cat "$log.host" >> "$log"
    if [ "$code" -eq 0 ] && [ "$board" -eq 0 ]; then
      echo "ok    mcu/clock [$(stat -c %s "$OUT/clock_board.bin") bytes: $(tail -n 1 "$log.host")]"
    else
      echo "FAIL  mcu/clock: host exit $code, board exit $board (see $log)"
      fails=$((fails + 1))
    fi
  fi
}

# An interrupt as a message: the QEMU board's clock raises five alarms, and
# each reaches an actor as a message.
step_irq() {
  local log="$OUT/irq.log" code
  if ! built irq; then
    echo "FAIL  mcu/irq build (see $log)"
    fails=$((fails + 1))
    return
  fi
  timeout 20 qemu-system-riscv32 -M virt -bios none -display none -monitor none -serial null \
    -device loader,file="$OUT/irq_board.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
  code=$?
  if [ "$code" -eq 0 ]; then
    echo "ok    mcu/irq [$(stat -c %s "$OUT/irq_board.bin") bytes: five interrupts from the board's clock arrive as five messages]"
  else
    echo "FAIL  mcu/irq: board exit $code (see $log)"
    fails=$((fails + 1))
  fi
}

# A sure line that loses about a quarter of the frames each way and damages
# some: 300 requests and replies arrive once each and in order. Then the
# machine on the line leaves in the middle of its questions and comes back
# as a new run, and the two go on by themselves. Then a machine shares work
# with a board over such a line.
step_sure() {
  local log="$OUT/sure.log" port run prog bin board_pid host_pid first code board
  if ! built sure; then
    echo "FAIL  mcu/sure build (see $log)"
    fails=$((fails + 1))
    return
  fi
  port=$((13101 + $$ % 300 * 3))
  for run in lossy restart arm; do
    : > "$log.host"
    if [ "$run" = restart ]; then
      timeout 60 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
        -serial "tcp:127.0.0.1:$port,server=on,wait=off" \
        -device loader,file="$OUT/sure_board.bin",addr=0x80000000,force-raw=on >> "$log" 2>&1 &
      board_pid=$!
      sleep 0.3
      timeout 60 "$OUT/sure_host" "$port" first >> "$log.host" 2>&1
      first=$?
      timeout 60 "$OUT/sure_host" "$port" second >> "$log.host" 2>&1
      code=$((first + $?))
      wait "$board_pid"
      board=$?
    else
      prog="$OUT/sure_host"
      bin="$OUT/sure_board.bin"
      if [ "$run" = arm ]; then
        prog="$OUT/sure_arm"
        bin="$OUT/sure_arm_board.bin"
      fi
      # shellcheck disable=SC2046
      timeout 60 "$prog" "$port" $([ "$run" = lossy ] && echo lossy) >> "$log.host" 2>&1 &
      host_pid=$!
      sleep 0.3
      timeout 60 qemu-system-riscv32 -M virt -bios none -display none -monitor none \
        -serial "tcp:127.0.0.1:$port" -device loader,file="$bin",addr=0x80000000,force-raw=on >> "$log" 2>&1
      board=$?
      wait "$host_pid"
      code=$?
    fi
    port=$((port + 1))
    cat "$log.host" >> "$log"
    if [ "$code" -eq 0 ] && [ "$board" -eq 0 ]; then
      echo "ok    mcu/sure $run [$(tail -n 1 "$log.host")]"
    else
      echo "FAIL  mcu/sure $run: host exit $code, board exit $board (see $log)"
      tail -n 4 "$log.host" | sed 's/^/      /'
      fails=$((fails + 1))
    fi
  done
}

# The same layers for 64-bit ARM Linux (a Raspberry Pi, a Jetson): built,
# not run here.
step_arm64() {
  local name
  if built arm64; then
    echo "ok    arm64 [the new layers' tests and examples build for ARM Linux; not run here]"
  else
    while read -r name; do
      echo "FAIL  arm64/$name build (see $OUT/arm64_$name.log)"
      fails=$((fails + 1))
    done < "$OUT/arm64.unbuilt"
  fi
}

# In the order the steps have always run.
if [ "$boards" -eq 1 ]; then
  echo "..    board steps ($((SECONDS - started))s so far)"
  [ "$qemu" -eq 1 ] && step_blink
  [ "$qemu" -eq 1 ] && step_tether
  [ "$qemu" -eq 1 ] && step_relay
  step_pico2
  [ "$qemu" -eq 1 ] && step_arm
  [ "$qemu" -eq 1 ] && step_device
  [ "$qemu" -eq 1 ] && step_lines
  [ "$qemu" -eq 1 ] && step_harts
  [ "$qemu" -eq 1 ] && step_pair
  [ "$qemu" -eq 1 ] && step_two
  [ "$qemu" -eq 1 ] && step_once
  [ "$qemu" -eq 1 ] && step_clock
  [ "$qemu" -eq 1 ] && step_sure
  [ "$qemu" -eq 1 ] && step_irq
  step_arm64
fi

echo "..    took $((SECONDS - started))s"
if [ "$fails" -eq 0 ]; then
  echo "PASS"
else
  echo "$fails failed"
  exit 1
fi
