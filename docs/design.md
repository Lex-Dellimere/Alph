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

## Ports

What differs between devices is in a port, a folder picked at build time with `-I ports/<name>`:

| Port | Device | Word | Actors in a node | Places | How it waits | How senders exclude each other |
|---|---|---|---|---|---|---|
| `mcu` | one hart, no OS | 32 bits | 1,024 | 256 | `wfi` | interrupts off |
| `host` | an x86-64 Linux process | 64 bits | 16 million | 32,768 | looks for mail for about 10 µs, then a futex | a spin lock |

A port is one file of 30 to 100 lines. A new device is a new port.

## Size

`examples/mcu/blink.mettle` is two actors driven by a timer interrupt on 32-bit RISC-V. The whole image, board startup included, is 2,440 bytes. The core's share is about 1.2 KB. `check.sh` builds it, runs it in QEMU and fails above 5 KB.

## Places

A place is anything that can run work: a core, a GPU, another node. Each has a cost to reach it and a speed once there. Sending to an actor on this core costs nanoseconds. A GPU launch costs about 6 µs plus moving the data. Another machine costs a network round trip.

Placement is one decision made from measured costs, not three separate features. The places arrive in this order:

1. **Cores.** Built: `src/cores` runs one node per thread. A pid's place is the core's number, so a message for another core is put straight into that core's node. `spawn` picks the core with the fewest actors. Measured on a busy 16-CPU laptop: about 20 ns per message inside a node, 150 to 300 ns between two cores, and 4.8 million messages sent at random among 64 actors on 8 cores at about 90 ns each. An actor stays on the core it was spawned on. Work moves when a program hands it out in pieces, as `examples/spread.mettle` does.
2. **GPU.** Planned. One actor owns the device, because a GPU context belongs to one thread. Work is a function that Mettle compiles for both CPU and GPU. alph times both and sends each job where it finishes first.
3. **Machines.** Planned. A remote actor is reached through the same `far` hook. A dead machine is noticed in under a second.

## The old runtime

Everything outside `src/actor` and `ports` is the first runtime: 13,000 lines for x86-64 Linux, with supervision, IO, timers and distribution. It works and its tests run. It is the reference while its parts are rebuilt on the core, one layer at a time, and each part is deleted from the old code when its replacement passes the same tests.
