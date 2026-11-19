# Design

alph runs work where it is cheapest to run: on this core, another core, a GPU or another machine. The program says what the work is. alph decides where it goes.

The same source builds for a microcontroller with no OS and for a cluster of servers.

## The core

`src/actor` is the whole model:

- An **actor** is a state and a handler.
- A **message** is four words: tag, sender, argument, ref.
- A **node** holds the actors and runs one message at a time.

A pid names a place, a slot there and which actor the slot held. A slot gives out 8,191 pids on `mcu` and 16 million on `host` before they repeat, and the slot free the longest is used next, so a pid kept after its actor ended stays dead for a long time, not for ever. A node is one place. Mail for any other place goes to the node's `far` function, which a layer above sets: that one hook is how a message reaches another core, a GPU or another machine.

Everything else is something that sends messages. A timer interrupt sends a tick. A socket sends "readable". A GPU sends "done". Another machine sends whatever its actors sent. The core does not know any of them.

The node owns no memory. The caller hands it the actor slots and the mailboxes, so a board with 2 KB of RAM and a server with a million actors use the same code.

## Time

A timer is something that sends a message later, so it is a layer (`src/time`), not part of the core. `after` sends a message in so many milliseconds and returns a ref, `cancel` takes it back. The port's alarm rings when the soonest timer is due: the board's timer interrupt on `mcu`, one sleeping thread on `host`.

Every operation looks at every timer slot. That is the smallest code and right for tens of timers. A server with thousands needs a timer wheel behind the same four functions, which is not built.

## Ports

What differs between devices is in a port, a folder picked at build time with `-I ports/<name>`:

| Port | Device | Word | Actors in a node | Places | How it waits | How senders exclude each other |
|---|---|---|---|---|---|---|
| `mcu` | one hart, no OS | 32 bits | 1,024 | 256 | `wfi` | interrupts off |
| `host` | an x86-64 Linux process | 64 bits | 16 million | 32,768 | looks for mail for about 10 µs, then a futex | a spin lock |

A port is two files, the gate and the alarm, of 30 to 100 lines each. A new device is a new port.

## Size

`examples/mcu/blink.mettle` is two actors and a timer on 32-bit RISC-V. The whole image, board startup included, is 3,192 bytes: about 1.2 KB of core, 1.1 KB of timers and alarm, the rest the board and the program. `check.sh` builds it, runs it in QEMU and fails above 5 KB.

## Places

A place is anything that can run work: a core, a GPU, another node. Each has a cost to reach it and a speed once there. Sending to an actor on this core costs nanoseconds. A GPU launch costs about 6 µs plus moving the data. Another machine costs a network round trip.

Placement is one decision made from measured costs, not three separate features. The places arrive in this order:

1. **Cores.** Built: `src/cores` runs one node per thread. A pid's place is the core's number, so a message for another core is put straight into that core's node. `spawn` picks the core with the fewest actors. Measured on a busy 16-CPU laptop: about 20 ns per message inside a node, 150 to 300 ns between two cores, and 4.8 million messages sent at random among 64 actors on 8 cores at about 90 ns each. An actor stays on the core it was spawned on. Work moves when a program hands it out in pieces, as `examples/spread.mettle` does.
2. **GPU.** Built as `src/place`, which knows nothing about GPUs. A job has a kind and a size, and a kind can be run more than one way: the program gives a function for a core and a function for the GPU, both calling the same Mettle code, so the answer is the same bits either way. A place is an actor that runs jobs one way. The GPU is one place on a core of its own, because a GPU belongs to the thread that opened it; every other core that takes work is a place too. alph times each way for each kind and size, and sends a job to the place where the work already waiting plus this job's own time is least. A way not yet tried is tried. A way that lost is tried again once the time spent since is 16 times what a run of it costs. A size not yet timed is guessed from the two nearest that were, so a core is not handed a huge job just to learn that it is slow. A way that cannot run (no GPU in the machine) is dropped and its jobs go the other way.

   `examples/render.mettle` renders a Mandelbrot picture in tiles of four sizes, on three cores and an RTX 4070 laptop GPU. Every pixel matches the picture computed on one core. Small tiles (64 pixels) go to the cores, where they take a tenth of the GPU's time or less. Whole pictures (262,144 pixels) go to the GPU, 10 to 40 times faster than the cores. In between alph splits the work. The machine was busy while this was measured and the times moved by a factor of two from run to run, so no closer numbers are claimed. One limit is real: alph predicts a job's time from its size, and a Mandelbrot tile's time depends on where in the picture it is, so for the middle sizes alph's choice was sometimes slower than the GPU alone.
3. **Machines.** Started, as `src/link`. Each machine owns a run of place numbers, so a pid says which machine its actor is on and an actor sends to it the way it sends next door. A message crosses in one UDP datagram. On the wire a pid is its three parts, because a 32-bit board and a 64-bit server pack them differently. Every machine tells its peers it is alive 20 times a second. One that stays quiet for half a second is down: sends to it are refused and a watcher actor is told. A machine that comes back counts as a new one, so mail meant for the old one is not handed to the new. Measured between two machines in one process over this computer's loopback: a request and its reply in under 40 µs, a lost machine noticed in 500 to 570 ms over 50 runs.

   What it does not do yet: a message arrives once or not at all, and nothing is sent again; nothing is encrypted or signed, so it is for a network you trust; peers are listed by hand; a job from `src/place` cannot go to another machine; and there is no link for the `mcu` port. The first runtime's `src/net/dist` has encryption and remote links and monitors, which move over later.

## The old runtime

Everything outside `src/actor` and `ports` is the first runtime: 13,000 lines for x86-64 Linux, with supervision, IO, timers and distribution. It works and its tests run. It is the reference while its parts are rebuilt on the core, one layer at a time, and each part is deleted from the old code when its replacement passes the same tests.
