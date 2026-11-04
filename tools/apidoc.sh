#!/usr/bin/env bash
# apidoc.sh: builds docs/api.md from the doc comments in src/.
#
# Every exported item must have a // comment directly above it; a run of
# exported constants shares the comment above its first line. The script
# fails, naming the item, when one is missing.
#
#   tools/apidoc.sh           writes docs/api.md
#   tools/apidoc.sh --check   fails if docs/api.md is out of date

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Modules in reading order: what applications use first, internals last.
MODULES=(
  src/alph.mettle
  src/core/node.mettle
  src/core/mailbox.mettle
  src/heal/supervisor.mettle
  src/heal/medic.mettle
  src/heal/dynamic.mettle
  src/work/pool.mettle
  src/work/limiter.mettle
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

out="$(render)" || exit 1

if [ "${1:-}" = "--check" ]; then
  if [ "$out" != "$(cat docs/api.md 2>/dev/null)" ]; then
    echo "docs/api.md is out of date: run tools/apidoc.sh"
    exit 1
  fi
  exit 0
fi

mkdir -p docs
printf '%s\n' "$out" > docs/api.md
echo "wrote docs/api.md"
