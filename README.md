# alph runtime

<img width="3419" height="1389" alt="image" src="https://github.com/user-attachments/assets/f685df06-1016-4a6d-a726-b67c24c767b5" />


alph runs work where it will finish first: on this core, another core, a GPU or another machine. It is written in [Mettle](https://github.com/The-Mettle-Project/Mettle), and the same source builds for a microcontroller with no OS and for several computers working together.

The whole model is small. An actor is a state and a handler. A message is four words. A node runs one message at a time. Everything else (time, a GPU, other cores, other machines) is something that sends messages, added as a layer you can leave out.

## Example

```mettle
import "std/io";
import "alph/actor/actor";

const ADD: Word = 1;

struct Counter {
  total: Word;
}

fn counter(a: AlphActor*, m: AlphMsg*) -> Word {
  var c: Counter* = (Counter*)a->state;
  c->total = c->total + m->arg;
  if (c->total >= 6) {
    println("total {c->total}");
    a->node->stop();
  }
  return 0;
}

var g_node: AlphNode;
var g_actors: AlphActor[4];
var g_mail: AlphMsg[32];

fn main() -> int32 {
  var c: Counter;
  c.total = 0;
  g_node.init(&g_actors[0], 4, &g_mail[0], 8);
  var pid: Word = g_node.spawn(&counter, (rawptr)&c);
  for i in 1..4 {
    g_node.send(pid, ADD, (Word)i);
  }
  g_node.run();
  return 0;
}
```

This is [examples/count.mettle](examples/count.mettle). The node owns no memory: the program hands it the actor slots and the mailboxes, which is why the same code fits a microcontroller.

## What is here

| Layer | What it does | Where |
|---|---|---|
| Core | Actors, messages, the run loop. A handler that crashes ends only its actor | [src/actor](src/actor/actor.mettle) |
| Cores | One node per thread. An actor sends to another core the way it sends next door | [src/cores](src/cores/cores.mettle) |
| Time | A message sent later | [src/time](src/time/time.mettle) |
| Places | A job goes to a core, the GPU or another machine, whichever alph has timed as finishing it first. A job stays where its data is | [src/place](src/place/place.mettle) |
| Lives | Watch an actor to be told when it ends and why. Keep one, and a crash restarts it in place with the same pid | [src/life](src/life/life.mettle) |
| Links | Other machines over UDP. Messages arrive once and in order, and a lost machine is noticed in half a second | [src/link](src/link/link.mettle) |
| Names and the door | Find an actor on another machine by name, and watch it | [src/name](src/name/name.mettle), [src/door](src/door/door.mettle) |
| Ports | What differs per device: `mcu` (one hart, no OS) and `host` (x86-64 Linux) | [ports](ports) |

[docs/design.md](docs/design.md) explains each of these, what was measured, and what is not built yet.

## Try it

Map alph in your program's `mettle.deps`, then pick a port when you build:

```text
alph=<path to alph>/src
```

```bash
mettle --build -s --release examples/count.mettle -I ports/host -o count
```

Build with `-s`: without it the compiler turns a failed check (a bad index, a division by zero) into an exit that alph cannot catch.

Work spread over four cores, [examples/spread.mettle](examples/spread.mettle):

```bash
mettle --build -s --release examples/spread.mettle -I ports/host -o spread
```

Tiles of a picture rendered on cores or on the GPU, whichever should finish each first, with the same pixels either way, [examples/render.mettle](examples/render.mettle). Without a GPU it runs on the cores:

```bash
mettle --build -s --release examples/render.mettle -I ports/host -o render
```

Work shared with another machine, [examples/far.mettle](examples/far.mettle). With no arguments both machines run in one process. On two computers, start `./far helper <the boss's address>` on one and `./far boss <the helper's address>` on the other. If the other machine is not there, or is lost on the way, the work is done here:

```bash
mettle --build -s --release examples/far.mettle -I ports/host -o far
```

Two actors and a timer on a bare 32-bit RISC-V board, in a 3.3 KB image, [examples/mcu/blink.mettle](examples/mcu/blink.mettle):

```bash
mettle --release examples/mcu/blink.mettle --target riscv32-none --board qemu-virt --emit-flat blink.bin -I ports/mcu
qemu-system-riscv32 -M virt -bios none -nographic -device loader,file=blink.bin,addr=0x80000000,force-raw=on
```

## What it does not do yet

- Nothing on the link is encrypted or signed: it is for a network you trust.
- A job with data of its own cannot go to another machine, only a job of one word in and one word out.
- Timers look at every timer slot: right for tens of timers, not thousands.
- There is no socket or file IO on the new core.
- A message between two cores costs 150 to 300 ns against about 20 ns inside a node.
- The microcontroller port has no link to other machines.

## Test

```bash
./check.sh
```

It builds every test and example in debug and release and runs it, builds the RISC-V example, runs it in QEMU and fails if the image is over 5 KB. It also checks that `docs/api.md` matches the first runtime's source.

## The first runtime

Everything under `src/core`, `src/heal`, `src/work`, `src/net`, `src/io`, `src/sched` and `src/sys` is the runtime alph started as: Erlang-style actors for x86-64 Linux with supervisors, medics, a heap per actor, non-blocking IO and TCP, child processes, a worker pool and Noise-encrypted distribution, in one import (`alph/alph`). It works and its tests run. It is the reference while its parts are rebuilt on the small core, and each part goes when its replacement does the same job.

- [Guide](docs/guide.md): how to use the first runtime.
- [API reference](docs/api.md): every function, type and constant of the first runtime.

## Layout

```text
src/actor/actor.mettle      the core: actors, messages, the run loop
src/cores/cores.mettle      the core on several threads, one node each
src/time/time.mettle        timers: a message sent later
src/place/place.mettle      places: a job goes to a core, the GPU or another machine
src/life/life.mettle        lives: watching and keeping actors
src/link/link.mettle        links: other machines, over UDP
src/name/name.mettle        names: a number for a pid
src/door/door.mettle        the door: find and watch actors on other machines
ports/mcu, ports/host       what differs per device, picked with -I ports/<name>
src/alph.mettle             the first runtime in one import
src/core, src/heal, src/work, src/net, src/io, src/sched, src/sys
                            the first runtime
docs/design.md              the design of the new alph, with what was measured
docs/guide.md, docs/api.md  the first runtime's guide and reference
examples/                   small programs, run by check.sh
tests/                      self-checking test programs
tools/                      apidoc.sh, which builds docs/api.md
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
