#!/usr/bin/env bash
# apidoc.sh: builds docs/api.md and docs/reference.md from the doc comments
# in the source.
#
# For docs/api.md every exported item must have a // comment directly above
# it; a run of exported constants shares the comment above its first line.
# The script fails, naming the item, when one is missing.
#
# For docs/reference.md an item with no comment is shown by its signature
# alone, and a list of those items is printed to standard error at the end.
#
#   tools/apidoc.sh                  writes docs/api.md
#   tools/apidoc.sh --check          fails if docs/api.md is out of date
#   tools/apidoc.sh --new            writes docs/reference.md
#   tools/apidoc.sh --new --check    fails if docs/reference.md is out of date

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

new=0
check=0
for arg in "$@"; do
  case "$arg" in
    --new) new=1 ;;
    --check) check=1 ;;
    *) echo "usage: tools/apidoc.sh [--new] [--check]"; exit 2 ;;
  esac
done

# Modules in reading order: what applications use first, internals last.
MODULES=(
  src/alph.mettle
  src/io/reactor.mettle
  src/sched/exec.mettle
  src/core/node.mettle
  src/core/mailbox.mettle
  src/heal/supervisor.mettle
  src/heal/medic.mettle
  src/heal/dynamic.mettle
  src/work/pool.mettle
  src/work/limiter.mettle
  src/work/task.mettle
  src/work/agent.mettle
  src/net/port.mettle
  src/net/dist.mettle
  src/net/noise.mettle
  src/sys/atomic.mettle
  src/sys/clock.mettle
  src/sys/thread.mettle
  src/sys/recover.mettle
  src/sys/fd.mettle
  src/sys/linux.mettle
  src/core/heap.mettle
  src/core/queue.mettle
)

# The layers after the first runtime, in reading order: the short way, the
# core, then each layer, then the ports a program calls directly.
NEW_MODULES=(
  src/machine/machine.mettle
  src/batch/batch.mettle
  src/board/board.mettle
  src/actor/actor.mettle
  src/cores/cores.mettle
  src/time/time.mettle
  src/time/wheel.mettle
  src/place/place.mettle
  src/place/words.mettle
  src/life/life.mettle
  src/name/name.mettle
  src/door/door.mettle
  src/door/words.mettle
  src/link/link.mettle
  src/seal/seal.mettle
  src/poll/poll.mettle
  ports/host/port/net.mettle
  ports/host/port/proc.mettle
  ports/host/port/wire.mettle
  ports/host/port/line.mettle
  ports/host/port/serial.mettle
  src/tether/tether.mettle
  src/tether/relay.mettle
  ports/mcu/port/board.mettle
)

render() {
  echo "# alph runtime API"
  echo
  echo "Every exported function, type and constant, with its doc comment. Built by \`tools/apidoc.sh\` from \`src/\`; do not edit by hand."
  echo
  echo "Functions are grouped by module. Names that take \`ctx\` run inside a handler; names starting \`alph_node_\` take the node and work from any thread."
  echo
  for file in "${MODULES[@]}"; do
    awk -v file="$file" -f "$ROOT/tools/apidoc.awk" "$file" || return 1
  done
}

# The heading of a section: the import path of a source file, or the port
# file's name and which port it belongs to.
title_of() {
  case "$1" in
    src/*) t="${1#src/}"; echo "alph/${t%.mettle}" ;;
    ports/*/port/*) p="${1#ports/}"; echo "port/$(basename "${1%.mettle}") (${p%%/*} port)" ;;
    *) echo "$1" ;;
  esac
}

render_new() {
  echo "# alph reference"
  echo
  echo "This page lists the structs, constants and functions of the newer layers, with the comment from the source above each. It is built by \`tools/apidoc.sh --new\` from the source files, so do not edit it by hand. [docs/start.md](start.md) shows how to use the layers and [docs/design.md](design.md) says why they are built this way. A function named \`Type_name__ptr\` is a method: the line under its signature shows how to call it."
  echo
  for file in "${NEW_MODULES[@]}"; do
    awk -v file="$file" -v new=1 -v title="$(title_of "$file")" -v missfile="$missing" \
      -f "$ROOT/tools/apidoc.awk" "$file" || return 1
  done
}

if [ "$new" -eq 1 ]; then
  target=docs/reference.md
  missing="$(mktemp)"
  trap 'rm -f "$missing"' EXIT
  out="$(render_new)" || exit 1
else
  target=docs/api.md
  out="$(render)" || exit 1
fi

status=0
if [ "$check" -eq 1 ]; then
  if [ "$out" != "$(cat "$target" 2>/dev/null)" ]; then
    echo "$target is out of date: run tools/apidoc.sh$([ "$new" -eq 1 ] && echo " --new")"
    status=1
  fi
else
  mkdir -p docs
  printf '%s\n' "$out" > "$target"
  echo "wrote $target"
fi

if [ "$new" -eq 1 ] && [ -s "$missing" ]; then
  cat "$missing" >&2
fi
exit "$status"
