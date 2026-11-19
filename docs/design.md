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

The node owns no memory. The caller hands it the actor slots and the mailboxes, so a small board and a large server use the same code.

## Lives

A handler that returns non-zero ends its actor, and what it returned is the reason. A handler that crashes (a null pointer, a division by zero, an index past the end, a fault signal) ends its actor with the reason `ALPH_CRASHED` and the node goes on: the port's guard saves a place to resume before each handler, and Mettle's runtime comes back to it instead of ending the process. This is on Linux, in a program built with `-s`. On a microcontroller a crash is still the board's trap.

`src/life` decides what an end means for others:

- **Watching.** A watcher is sent `ALPH_ENDED` with the reason when the actor it watches ends. Watching one that is already gone says so at once. An actor is gone before anyone is told, so a watcher that hears of an end can no longer reach it.
- **Keeping.** A kept actor that fails or crashes is not ended. Its state is set up again and it goes on with the same pid and the mail it had, so nothing that knows it has to learn a new pid. After its last allowed restart it ends like any other.
- **Lost machines.** When a link reports a machine down, every actor watched on that machine ends for its watchers with the reason `ALPH_LOST`.

Not built: restart limits counted over time rather than in all, and groups that restart together.

## Names and the door

`src/name` gives a pid a name: a number the program chooses.

`src/door` is how machines find and watch each other's actors, with nothing but messages. The door is the first actor a machine spawns, so its pid can be worked out from the machine's first place alone. An actor asks another machine's door for the pid behind a name and gets it back as a message. Watching works for an actor anywhere: for one on another machine, the door there keeps the watch and tells the watcher's door when the actor ends, and if that machine is lost first, the actor has ended with `ALPH_LOST`. Between two machines in one process: an actor found by name, a request answered, an end told across, and a lost machine's actors ended in about 540 ms.

Not built: a watch cannot be dropped across machines.

## Time

A timer is something that sends a message later, so it is a layer (`src/time`), not part of the core. `after` sends a message in so many milliseconds and returns a ref, `cancel` takes it back. The port's alarm rings when the soonest timer is due: the board's timer interrupt on `mcu`, one sleeping thread on `host`.

Every operation looks at every timer slot. That is the smallest code and right for tens of timers. A server with thousands needs a timer wheel behind the same four functions, which is not built.

## Polls

`src/poll` is how a socket, or any file descriptor, sends a message when it is ready. Handlers never wait: they read and write what can be done now, and ask to be told when there is more. One thread sleeps in the kernel until something is ready and sends the messages. Each asking is for one message, so a busy socket cannot flood a mailbox and an actor that is not ready for more is not told. The host port has the TCP calls that go with it, none of which waits. `examples/talk.mettle` is an echo server with an actor for each connection, and the test runs twenty clients against one at once. This is Linux only.

## Ports

What differs between devices is in a port, a folder picked at build time with `-I ports/<name>`:

| Port | Device | Word | Actors in a node | Places | How it waits | How senders exclude each other |
|---|---|---|---|---|---|---|
| `mcu` | one hart, no OS | 32 bits | 1,024 | 256 | `wfi` | interrupts off |
| `host` | an x86-64 Linux process | 64 bits | 16 million | 32,768 | looks for mail for about 10 µs, then a futex | a spin lock |

A port is a few files of 30 to 130 lines each: the gate, the alarm, the guard that catches a crash, and the wire to other machines. A new device is a new port.

## Size

`examples/mcu/blink.mettle` is two actors and a timer on 32-bit RISC-V. The whole image, board startup included, is 3,256 bytes: about 1.3 KB of core, 1.1 KB of timers and alarm, the rest the board and the program. `check.sh` builds it, runs it in QEMU and fails above 5 KB.

## Places

A place is anything that can run work: a core, a GPU, another node. Each has a cost to reach it and a speed once there. Sending to an actor on this core costs nanoseconds. A GPU launch costs about 6 µs plus moving the data. Another machine costs a network round trip.

Placement is one decision made from measured costs, not three separate features. The places arrive in this order:

1. **Cores.** Built: `src/cores` runs one node per thread. A pid's place is the core's number, so a message for another core is put straight into that core's node. `spawn` picks the core with the fewest actors. Measured on a busy 16-CPU laptop: about 20 ns per message inside a node, 150 to 300 ns between two cores, and 4.8 million messages sent at random among 64 actors on 8 cores at about 90 ns each. An actor stays on the core it was spawned on. Work moves when a program hands it out in pieces, as `examples/spread.mettle` does.
2. **GPU.** Built as `src/place`, which knows nothing about GPUs. A job has a kind and a size, and a kind can be run more than one way: the program gives a function for a core and a function for the GPU, both calling the same Mettle code, so the answer is the same bits either way. A place is an actor that runs jobs one way. The GPU is one place on a core of its own, because a GPU belongs to the thread that opened it; every other core that takes work is a place too. alph times each way for each kind and size, and sends a job to the place where the work already waiting plus this job's own time is least. A way not yet tried is tried. A way that lost is tried again once the time spent since is 16 times what a run of it costs. A size not yet timed is guessed from the two nearest that were, so a core is not handed a huge job just to learn that it is slow. A way that cannot run (no GPU in the machine) is dropped and its jobs go the other way.

   `examples/render.mettle` renders a Mandelbrot picture in tiles of four sizes, on three cores and an RTX 4070 laptop GPU. Every pixel matches the picture computed on one core. Four runs on a busy machine, times in milliseconds for the whole step:

   | Pixels a tile | Tiles | 3 cores only | GPU only | alph | Where alph sent them |
   |---|---|---|---|---|---|
   | 64 | 4,096 | 30–71 | 52–90 | 17–44 | about 80% to cores, 20% to the GPU |
   | 1,024 | 1,024 | 65–102 | 15–29 | 14–22 | about 90% to the GPU |
   | 16,384 | 256 | 270–288 | 5–8 | 4–10 | all to the GPU |
   | 262,144 | 64 | 1,050–1,070 | 3–6 | 4–5 | all to the GPU |

   For the smallest tiles alph beats both, because it uses both. For the rest it matches the GPU. One limit is real: alph predicts a job's time from its size, and a Mandelbrot tile's time depends on where in the picture it is.

3. **Machines.** Built as `src/link`. Each machine owns a run of place numbers, so a pid says which machine its actor is on and an actor sends to it the way it sends next door. A message crosses in one UDP datagram. On the wire a pid is its three parts, because a 32-bit board and a 64-bit server pack them differently. Messages to a machine are numbered, the machine says how far it has them, and what it has not got in 40 ms is sent again, so between two machines messages arrive once and in order while both are up. Every machine tells its peers it is alive 20 times a second. One that stays quiet for half a second is down: sends to it are refused and a watcher actor is told. One that was only out of reach carries on where it was. One that was restarted counts as a new machine, so mail meant for the old one is not handed to the new. Measured between two machines in one process over this computer's loopback, on a busy machine: a request and its reply in 45 to 65 µs, every request still crossing with a quarter to a third of the messages deliberately lost, a lost machine noticed in 500 to 570 ms.

   A link is in the clear unless it is sealed. `src/seal` encrypts and signs every datagram (XChaCha20-Poly1305) with one key the whole network shares. The number used once for each datagram is its clear header: the sender's first place, when the sender's run began, a count that goes up with every datagram, and four random bytes. A datagram made without the key, changed on the way or played again is dropped, and so is everything from a run earlier than the latest heard. A machine counts as alive only when it answers this run of ours, so a recording of an old run cannot make a dead machine look alive. It is its own layer, so a program that does not seal its link does not need the crypto package.

   What it does not do yet: a full mailbox at the far end drops its message and the sender is not told; a sealed link has one key for all, so any holder can speak as any machine, and there is no forward secrecy; and peers are listed by hand. A microcontroller joins by a serial line instead: see the tether below.

4. **Work on other machines.** Built into `src/place` as a third way. A job that is one word in and one word out can be done by a worker actor on another machine, which the program finds by name through the door. To alph that is one more place with a time of its own, the network included, so a job goes to another machine when that is where it will finish first, and stays here when it is not. If the worker ends or its machine is lost, the jobs it had not answered are done here and nothing more is sent to it. Given a clock, a job not answered in eight times its usual time, and at least a second, is given up on and placed again. `examples/far.mettle` counts the primes below two million on two machines: run with no arguments it is both machines in one process; run as `far helper <address>` and `far boss <address>` it is two computers. With two cores here and one worker there, about a third of the chunks went across. A job with data of its own cannot leave the machine yet.

5. **A board among bigger machines.** Built as `src/tether`: a node tied to one other machine by a line of bytes, such as a board's serial port. It is the small way for a microcontroller to be a place: no numbering, no beats, nothing sent again. A message is 34 bytes on the line. `examples/mcu/tether.mettle` is a board whose one actor answers a number with the next one, in a 3,784-byte image, and `examples/mcu/tether_host.mettle` is a Linux process at the other end of its serial line. `check.sh` runs the board in QEMU with the process on its line: 200 requests and replies, each actor reaching the other by its pid. A pid from a bigger machine has to fit the board's 32-bit word, which holds for actors spawned at the start. Not built: a board on the UDP link, a line that sends again what was lost, and passing a board's messages on to a third machine.

## Crossings

A message to another core moves cache lines over the memory bus. A job for the GPU moves data over PCIe. A message to another machine is a datagram. These are one thing, a crossing, and data is what makes a crossing expensive: a message is four words, data is megabytes. Two rules follow.

**Work travels, data stays.** Data has a home. A job goes to where its data is, and data crosses only when someone on the other side needs it. The render example first copied every tile back to the host as it finished. Measured on the GPU alone, a 64-pixel tile cost 13 µs that way, 9 µs with only a wait for it to finish, and 3.7 µs when the pixels stayed on the GPU and the picture was fetched once. For whole pictures the copy back was 80% of the job. The example now leaves the pixels where they were rendered and brings the picture to the host in one crossing, which made its GPU steps 5 to 15 times faster than before; an earlier version of this page blamed the GPU for a cost that was the bus, and for start-up time that had been counted in the first step.

**A crossing carries everything that is waiting.** One lock, one launch or one datagram for a batch, not one each. The fetch above is this rule by hand. It is not yet built into the cores or the link, where every message still crosses alone.

alph knows where a job's data is. A job names its data's home: the host, the GPU, or nowhere yet. alph keeps separate times for a job run where its data is and one run away from it, so the cost of the crossing is part of choosing a place and a job tends to stay with its data. In the test, where crossing costs 400 µs either way, 197 of 200 jobs with data on the host stayed on the cores and 191 of 200 with data on the GPU stayed on the GPU. When a core is to run a job whose data is on the GPU, the GPU's own place brings the data first, because only that thread may touch the GPU. A program asks for its data on the host the same way: a job only a core can run, on data that is on the GPU. That is how the render example gets its picture back.

What was tried and did not help: letting a node take eight messages in one visit to its lock, where it took one. The 8-core storm, the two-core ping and the single-node ping all measured the same within noise, so it was taken out. The cost of a message between cores is the cache lines the sender and the receiver both touch, not how often the receiver takes its lock. Removing it needs a queue per pair of cores that the sender writes without touching anything the receiver owns, which changes what a full mailbox can tell a sender. Not built.

## The old runtime

Everything outside `src/actor` and `ports` is the first runtime: 13,000 lines for x86-64 Linux, with supervision, IO, timers and distribution. It works and its tests run. It is the reference while its parts are rebuilt on the core, one layer at a time, and each part is deleted from the old code when its replacement passes the same tests.
