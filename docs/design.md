# Design

alph runs work where it is cheapest to run: on this core, another core, a GPU or another machine. The program says what the work is. alph decides where it goes.

The same source builds for a microcontroller with no OS and for a cluster of servers.

## The core

`src/actor` is the whole model:

- An **actor** is a state and a handler.
- A **message** is four words: tag, sender, argument, ref.
- A **node** holds the actors and runs one message at a time.

Everything else is something that sends messages. A timer interrupt sends a tick. A socket sends "readable". A GPU sends "done". Another machine sends whatever its actors sent. The core does not know any of them.

The node owns no memory. The caller hands it the actor slots and the mailboxes, so a board with 2 KB of RAM and a server with a million actors use the same code.

## Ports

What differs between devices is in a port, a folder picked at build time with `-I ports/<name>`:

| Port | Device | Word | How it waits | How senders exclude each other |
|---|---|---|---|---|
| `mcu` | one hart, no OS | 32 bits | `wfi` | interrupts off |
| `host` | a Linux process | 64 bits | futex | a spin lock |

A port is one file of about 40 lines. A new device is a new port.

## Size

`examples/mcu/blink.mettle` is two actors driven by a timer interrupt on 32-bit RISC-V. The whole image, board startup included, is 2,416 bytes. The core's share is about 1.2 KB. `check.sh` builds it, runs it in QEMU and fails above 5 KB.

## Places

A place is anything that can run work: a core, a GPU, another node. Each has a cost to reach it and a speed once there. Sending to an actor on this core costs nanoseconds. A GPU launch costs about 6 µs plus moving the data. Another machine costs a network round trip.

Placement is one decision made from measured costs, not three separate features. This is planned, in this order:

1. **Cores.** Many nodes in one process, one per core, with work moving between them. The old runtime (`src/core`) does this today with its own code. Its methods move onto the new core.
2. **GPU.** One actor owns the device, because a GPU context belongs to one thread. Work is a function that Mettle compiles for both CPU and GPU. alph times both and sends each job where it finishes first.
3. **Machines.** A remote actor is a local proxy. A dead machine is noticed in under a second.

## The old runtime

Everything outside `src/actor` and `ports` is the first runtime: 13,000 lines for x86-64 Linux, with supervision, IO, timers and distribution. It works and its tests run. It is the reference while its parts are rebuilt on the core, one layer at a time, and each part is deleted from the old code when its replacement passes the same tests.
