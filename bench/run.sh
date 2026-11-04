#!/usr/bin/env bash
# run.sh: builds the alph and Erlang twin of each benchmark, runs both, and
# prints one table. See bench/README.md for what each workload does.
#
#   bash bench/run.sh              all workloads
#   bash bench/run.sh ring fanin   only those
#   RUNS=5 bash bench/run.sh       runs per program (default 3); the table
#                                  shows the median of each metric
#   METTLE=/path/to/mettle bash bench/run.sh
#
# distping needs two BEAM nodes. For each BEAM run this script starts a server
# node (erl -sname, serving the registered names), runs the client node
# against it, and stops the server node afterwards. An epmd this script
# started is stopped at the end too.
#
# Exit status: 0 when every build and run succeeded, 1 otherwise. A run
# fails when the program exits nonzero, prints FAIL, does not print exactly
# one RESULT line with the expected name, or runs over TIMEOUT seconds
# (default 120). An alph build fails when the compiler prints any warning.
#
# Ratio column: always alph relative to BEAM, and above 1 always means alph
# is better. For throughput metrics (higher is better: *_per_s) it is
# alph / beam. For time metrics (lower is better: ns_per_*, *_ns, *_us) it is
# beam / alph.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2
METTLE="${METTLE:-$ROOT/../Mettle/bin/mettle}"
RUNS="${RUNS:-3}"
TIMEOUT="${TIMEOUT:-120}"
OUT="build/bench"
ALL=(spawn ring pingpong fanin pairs restart distping)

if [ $# -gt 0 ]; then
  names=("$@")
else
  names=("${ALL[@]}")
fi

for n in "${names[@]}"; do
  if [ ! -f "bench/$n.mettle" ] || [ ! -f "bench/erl/$n.erl" ]; then
    echo "no such workload: $n (known: ${ALL[*]})"
    exit 2
  fi
done
if [ ! -x "$METTLE" ]; then
  echo "no compiler at $METTLE (set METTLE)"
  exit 2
fi
if ! command -v erl > /dev/null || ! command -v erlc > /dev/null; then
  echo "erl and erlc are required"
  exit 2
fi

mkdir -p "$OUT/erl"
export ERL_CRASH_DUMP_SECONDS=0   # a failed Erlang run must not drop erl_crash.dump here
fails=0
rows=()   # "workload|metric|alph|beam|ratio"

SRV_PID=""      # the BEAM server node of a distping run, while one runs
EPMD_STARTED=0  # 1 when no epmd was running before this script

stop_server() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2> /dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SRV_PID" 2> /dev/null || break
      sleep 0.2
    done
    kill -9 "$SRV_PID" 2> /dev/null
    wait "$SRV_PID" 2> /dev/null
    SRV_PID=""
  fi
}

cleanup() {
  stop_server
  if [ "$EPMD_STARTED" -eq 1 ]; then
    epmd -kill > /dev/null 2>&1
  fi
}
trap cleanup EXIT

for n in "${names[@]}"; do
  if [ "$n" = distping ] && command -v epmd > /dev/null && ! epmd -names > /dev/null 2>&1; then
    EPMD_STARTED=1
  fi
done

# beam_once NAME: runs the BEAM side of one workload once, output on this
# function's stdout and stderr. distping runs as two nodes: a server node in
# the background and the client node in the foreground, then the server node
# is stopped.
beam_once() {
  local name="$1"
  if [ "$name" != distping ]; then
    timeout "$TIMEOUT" erl -noshell -pa "$OUT/erl" -eval "$name:main(), halt()."
    return
  fi
  local tag="${name}_$$_$RANDOM" host status
  host="$(hostname -s 2> /dev/null || hostname)"
  erl -noshell -sname "srv_$tag" -setcookie distping_bench -pa "$OUT/erl" \
      -eval "distping:serve(), halt()." > /dev/null 2>&1 &
  SRV_PID=$!
  DISTPING_PEER="srv_$tag@$host" timeout "$TIMEOUT" \
    erl -noshell -sname "cli_$tag" -setcookie distping_bench -pa "$OUT/erl" -eval "$name:main(), halt()."
  status=$?
  stop_server
  return $status
}

# median of the numbers on stdin
median() {
  sort -g | awk '{ v[NR] = $1 } END { if (NR == 0) exit 1; print v[int((NR + 1) / 2)] }'
}

# higher_is_better METRIC: true for throughput metrics
higher_is_better() {
  case "$1" in
    *_per_s) return 0 ;;
    *) return 1 ;;
  esac
}

# run_side SIDE NAME: runs one program RUNS times. On success prints
# "metric value" lines (the median over the runs), on failure returns 1.
run_side() {
  local side="$1" name="$2" i line out status
  local dir="$OUT/tmp.$name.$side"
  rm -rf "$dir"
  mkdir -p "$dir"
  for ((i = 1; i <= RUNS; i++)); do
    if [ "$side" = alph ]; then
      timeout "$TIMEOUT" "$OUT/$name" > "$dir/out.$i" 2> /dev/null
    else
      beam_once "$name" > "$dir/out.$i" 2> /dev/null
    fi
    status=$?
    out="$(cat "$dir/out.$i")"
    if [ $status -ne 0 ] || grep -q '^FAIL' <<< "$out" ||
       [ "$(grep -c '^RESULT ' <<< "$out")" -ne 1 ] ||
       ! grep -q "^RESULT $name " <<< "$out"; then
      echo "  $side $name run $i failed (exit $status):" >&2
      sed 's/^/    | /' <<< "$out" | head -20 >&2
      echo "    stderr of a rerun:" >&2
      if [ "$side" = alph ]; then
        timeout "$TIMEOUT" "$OUT/$name" 2>&1 > /dev/null | head -20 | sed 's/^/    | /' >&2
      else
        beam_once "$name" 2>&1 > /dev/null | head -20 | sed 's/^/    | /' >&2
      fi
      return 1
    fi
    grep '^RESULT ' "$dir/out.$i" | tr ' ' '\n' | grep '=' | tr '=' ' ' > "$dir/kv.$i"
  done
  local metrics
  metrics="$(awk '{ print $1 }' "$dir/kv.1")"
  for m in $metrics; do
    local med
    med="$(for ((i = 1; i <= RUNS; i++)); do awk -v m="$m" '$1 == m { print $2 }' "$dir/kv.$i"; done | median)"
    echo "$m $med"
  done
  rm -rf "$dir"
}

for name in "${names[@]}"; do
  echo "== $name"

  # build
  build_log="$OUT/$name.build.log"
  if ! "$METTLE" --build -s --release "bench/$name.mettle" -o "$OUT/$name" > "$build_log" 2>&1; then
    echo "  alph build failed:"
    sed 's/^/    | /' "$build_log"
    fails=$((fails + 1))
    continue
  fi
  if grep -qi 'warning' "$build_log"; then
    echo "  alph build has warnings:"
    sed 's/^/    | /' "$build_log"
    fails=$((fails + 1))
    continue
  fi
  if ! erlc +warnings_as_errors -o "$OUT/erl" "bench/erl/$name.erl" > "$OUT/$name.erlc.log" 2>&1; then
    echo "  erlc failed:"
    sed 's/^/    | /' "$OUT/$name.erlc.log"
    fails=$((fails + 1))
    continue
  fi

  # run
  if ! a="$(run_side alph "$name")"; then
    fails=$((fails + 1))
    continue
  fi
  if ! b="$(run_side beam "$name")"; then
    fails=$((fails + 1))
    continue
  fi
  while read -r metric aval; do
    bval="$(awk -v m="$metric" '$1 == m { print $2 }' <<< "$b")"
    if [ -z "$bval" ]; then
      echo "  beam $name printed no $metric"
      fails=$((fails + 1))
      continue
    fi
    if higher_is_better "$metric"; then
      ratio="$(awk -v a="$aval" -v b="$bval" 'BEGIN { printf "%.2f", a / b }')"
    else
      ratio="$(awk -v a="$aval" -v b="$bval" 'BEGIN { printf "%.2f", b / a }')"
    fi
    rows+=("$name|$metric|$aval|$bval|$ratio")
  done <<< "$a"
done

echo
echo "alph vs BEAM (Erlang/OTP $(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().')), $(nproc) CPUs, median of $RUNS runs"
echo "ratio = alph relative to BEAM, above 1 means alph is better:"
echo "  throughput metrics (*_per_s, higher is better): alph / beam"
echo "  time metrics (ns_per_*, *_ns, *_us, lower is better): beam / alph"
echo
printf '%-10s %-20s %14s %14s %8s\n' workload metric alph beam ratio
printf '%-10s %-20s %14s %14s %8s\n' ---------- -------------------- -------------- -------------- --------
for r in "${rows[@]+"${rows[@]}"}"; do
  IFS='|' read -r w m a b x <<< "$r"
  printf '%-10s %-20s %14s %14s %8s\n' "$w" "$m" "$a" "$b" "$x"
done

if [ $fails -ne 0 ]; then
  echo
  echo "$fails failure(s)"
  exit 1
fi
exit 0
