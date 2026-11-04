#!/usr/bin/env bash
# Builds the sim demo into build/sim. alph needs -s, so every build carries it.
#
#   bash demos/sim/build.sh
#   METTLE=/path/to/mettle bash demos/sim/build.sh
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METTLE="${METTLE:-$HERE/../../../Mettle/bin/mettle}"
if [ ! -x "$METTLE" ]; then
  echo "no compiler at $METTLE (set METTLE)" >&2
  exit 2
fi
mkdir -p "$HERE/build"
cd "$HERE"
"$METTLE" --build -s --release sim.mettle -o build/sim
echo "built $HERE/build/sim"
