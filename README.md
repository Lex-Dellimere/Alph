# alph runtime

Erlang-style actors, supervision and self-healing for [Mettle](https://github.com/The-Mettle-Project/Mettle), written in Mettle.

An actor is a state block, a bounded mailbox and a handler that runs one message to completion. A crash inside a handler ends only that actor, and its links and monitors see it.

Healing comes in two kinds:
- **Passive:** supervisors restart failed actors the OTP way.
- **Proactive:** a medic repairs a crashed actor in place, on the same pid, without anyone else seeing the crash.

It runs on one node, on x86-64 Linux. Distribution is next.

## Example

```mettle
import "std/io";
import "alph/alph";

const TAG_ADD: int64 = ALPH_TAG_USER;

struct Counter {
  total: int64;
}

fn counter(ctx: AlphCtx*, m: AlphMsg*) -> int64 {
  var c: Counter* = (Counter*)ctx->state;
  if (m->tag == TAG_ADD) {
    c->total = c->total + m->arg;
    if (c->total >= 6) {
      println("total {c->total}");
      alph_halt(ctx, 0);
    }
  }
  return ALPH_CONTINUE;
}

var g_node: AlphNode;

fn main() -> int32 {
  var cfg: AlphConfig;
  alph_config(&cfg);
  if (!alph_node_start(&g_node, &cfg)) {
    return 1;
  }
  var c: Counter;
  c.total = 0;
  var pid: int64 = alph_node_spawn_value<Counter>(&g_node, &c, &counter);
  for i: int64 in 1..4 {
    alph_node_send(&g_node, pid, TAG_ADD, i);
  }
  return (int32)alph_node_wait(&g_node);
}
```

This is [examples/counter.mettle](examples/counter.mettle). The other examples show [requests](examples/request.mettle), [a supervisor](examples/supervised.mettle) and [a medic](examples/medic.mettle).

## Use

Map the runtime in your app's `mettle.deps`, then `import "alph/alph"`:

```text
alph=<path to alph>/src
```

Build with the dev compiler from the Mettle repo, always with `-s`:

```bash
../Mettle/bin/mettle --build -s --release app.mettle
```

Without `-s`, the compiler turns failed checks (bounds, divide) into an inline exit that alph cannot catch.

- [Guide](docs/guide.md): how to use the runtime, from starting a node to both kinds of healing.
- [API reference](docs/api.md): every function, type and constant, with its inputs, outputs and which thread may call it.
- [Design](DESIGN.md): how it works, what was taken from BEAM and OTP, and what comes next.

## Test

```bash
./check.sh
```

It checks that `docs/api.md` matches the source, then builds every test and example in debug and release and runs it. After changing a doc comment, run `tools/apidoc.sh` to rebuild the reference.

## Layout

```text
src/alph.mettle  the runtime in one import
src/core/        the node, actors and messages
src/heal/        supervisors and medics
src/sys/         the x86-64 Linux layer: atomics, threads, crash recovery, clock
docs/            guide and API reference
examples/        small programs, run by check.sh
tests/           self-checking test programs
tools/           apidoc.sh, which builds docs/api.md
```
