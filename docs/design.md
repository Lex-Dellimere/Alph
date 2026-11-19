# Design

alph runs work where it will finish first: on this core, another core, a GPU or another machine. The program says what the work is. alph decides where it goes. The same source builds for a microcontroller with no OS and for a cluster of servers. This page says why alph is built this way and what was measured. [start.md](start.md) says how to use it.

## The model

`src/actor` is the whole model:

- An **actor** is a state and a handler.
- A **message** is four words: tag, sender, argument, ref.
- A **node** holds the actors and runs one message at a time.

A pid names a place, a slot there and which actor the slot held. A slot gives out 8,191 pids on `mcu` and 16 million on `host` before they repeat. The slot free the longest is used next, so a pid kept after its actor ended stays dead for a long time, not for ever.

A node is one place. Mail for any other place goes to the node's `far` function, which a layer above sets. That one hook is how a message reaches another core, a GPU or another machine. Everything else sends messages: a timer sends a tick, a socket sends "readable", a GPU sends "done". The core knows none of them.

The node owns no memory. The caller hands it the actor slots and the mailboxes, so a small board and a large server use the same code.

## Ports

What differs between devices is in a port, a folder picked at build time with `-I ports/<name>`:

| Port | Device | Word | Actors in a node | Places | How it waits | How senders exclude each other |
|---|---|---|---|---|---|---|
| `mcu` | one hart, no OS | 32 bits | 1,024 | 256 | `wfi` | interrupts off |
| `harts` | several harts, no OS | 32 bits | 1,024 | 256 | `wfi`, woken by the software interrupt | interrupts off and a lock |
| `pico2` | a Raspberry Pi Pico 2, one of its RISC-V cores | as `mcu` | as `mcu` | as `mcu` | as `mcu` | as `mcu` |
| `host` | an x86-64 Linux process | 64 bits | 16 million | 32,768 | looks for mail for about 10 µs, then a futex | a spin lock |

`arm64` is 64-bit ARM Linux, such as a Raspberry Pi or a Jetson, built with `-I ports/arm64 -I ports/host`. It holds only what differs from `host`: the system call numbers (`port/sys`, which every other file names them through) and the guard. On ARM a handler that crashes ends the process, because the guard needs inline assembly that Mettle does not emit for ARM yet. Every test and example of these layers builds for it. Linked by hand and run under an ARM emulator on an x86-64 machine, 18 of the 19 tests passed (the one that crashes handlers on purpose cannot), and so did the Linux side of every board example with a RISC-V board in QEMU. Nothing has run on an ARM machine, and an emulator on x86-64 keeps memory in a stricter order than a real ARM chip, so a fault of ordering would not show.

A port is a few files of 30 to 130 lines each: the gate, the alarm, the crash guard, how a core is started, and the wire or line to other machines. A new device is a new port. Ports stack: `harts` and `pico2` have only what differs from `mcu`, and are built with `-I ports/harts -I ports/mcu` or `-I ports/pico2 -I ports/mcu`.

A board program calls `alph_board_start()` first, which is the port's, so the examples in `examples/mcu` are the same source on a QEMU board and on a Pico 2. On the Pico 2 they have run on the compiler's model of the chip, not yet on a real board: the blink prints its five counts from five timer interrupts, and the tether answers every question whole.

## Places

A place is anything that can run work: a core, a GPU, another node. Each has a cost to reach it and a speed once there. Sending to an actor on this core costs nanoseconds, a GPU launch about 6 µs plus moving the data, and another machine a network round trip. Work goes where it will finish first, judged from measured costs, with one decision for every kind of place.

### Cores

`src/cores` runs one node per core: a thread each in a Linux process, a hart each on a chip that has several. Starting a core is the port's business, so the layer is the same code on both (`examples/mcu/harts.mettle` uses both harts of a RISC-V board). A pid's place is the core's number, so a message for another core is put straight into that core's node. `spawn` picks the core with the fewest actors, and an actor stays there. Work moves when a program hands it out in pieces, as `examples/spread.mettle` does.

### The GPU

`src/place` knows nothing about GPUs. A job has a kind and a size. The program gives a function for a core and one for the GPU, both calling the same Mettle code, so the answer is the same bits either way. A place is an actor that runs jobs one way. The GPU is one place on a core of its own, because a GPU belongs to the thread that opened it. Every other core that takes work is a place too. alph times each way for each kind and size, and sends a job to the place where the work already waiting plus this job's own time is least:

- A way not yet tried is tried.
- A way that lost is tried again once the time spent since is 16 times what a run of it costs.
- A size not yet timed is guessed from the two nearest that were, so a core is not handed a huge job only to learn that it is slow.
- A way that cannot run (no GPU in the machine) is dropped and its jobs go the other way.

`examples/render.mettle` renders a Mandelbrot picture in tiles of four sizes, on three cores and an RTX 4070 laptop GPU. Every pixel matches the picture computed on one core. Four runs on a busy machine, times in milliseconds for the whole step:

| Pixels a tile | Tiles | 3 cores only | GPU only | alph | Where alph sent them |
|---|---|---|---|---|---|
| 64 | 4,096 | 30 to 71 | 52 to 90 | 17 to 44 | about 80% to cores, 20% to the GPU |
| 1,024 | 1,024 | 65 to 102 | 15 to 29 | 14 to 22 | about 90% to the GPU |
| 16,384 | 256 | 270 to 288 | 5 to 8 | 4 to 10 | all to the GPU |
| 262,144 | 64 | 1,050 to 1,070 | 3 to 6 | 4 to 5 | all to the GPU |

For the smallest tiles alph beats both, because it uses both. For the rest it matches the GPU.

### Other machines

`src/link` joins machines over UDP. Each machine owns a run of place numbers, so a pid says which machine its actor is on, and an actor sends to it the way it sends next door. A message is one datagram. On the wire a pid is its three parts, because a 32-bit board and a 64-bit server pack them differently.

- Messages to a machine are numbered, and the machine says how far it has them. What it has not got in 40 ms is sent again. So messages arrive once and in order while both machines are up. A message for an actor whose mailbox is full is not taken either: it is sent again, and what is behind it waits, so a full mailbox slows a sender down and loses nothing.
- Every machine tells its peers it is alive 20 times a second. One quiet for half a second is down: sends to it are refused and a watcher actor is told.
- A machine only out of reach carries on where it was. One that was restarted counts as a new machine, so mail meant for the old one is not handed to the new.

**Bytes.** A message can carry up to 1,024 bytes in a parcel, with the same numbering. The parcels are a pool the program gives the link. Half of it is kept for what arrives, so two machines sending to each other cannot each fill their pool and never take the other's. A machine with no parcel free takes no more, and the sender waits longer each time before sending again.

**Sealing.** A link is in the clear unless sealed. `src/seal` encrypts and signs every datagram (XChaCha20-Poly1305) with one key the whole network shares. A datagram made without the key, changed or played again is dropped, and so is everything from a run earlier than the latest heard, so a recording of an old run cannot make a dead machine look alive. It is its own layer, so a program that does not seal needs no crypto package.

**Work.** `src/place` has a third way to run a job: a worker actor on another machine, which the program finds by name through the door. To alph that is one more place with a time of its own, the network included, so a job goes there when that is where it will finish first.

- The job is one word in and one word out. It can carry up to a parcel's worth of bytes instead of the word in, and give back up to 1,016 bytes with the word out.
- If the worker ends or its machine is lost, the jobs it had not answered are done here and nothing more is sent to it.
- Given a clock, a job not answered in eight times its usual time, and at least a second, is given up on and placed again.

`examples/far.mettle` counts the primes below two million on two machines. `examples/run.mettle` runs twelve commands, as a build would: each command's text is the bytes of a job, and its exit status comes back. The other machine runs it on its own cores through its own places, so the choice is made twice: which machine, then which core.

### Boards

`src/tether` ties a node to one other machine by a line of bytes, such as a board's serial port. It is the small way for a microcontroller to be a place: no numbering, no beats, nothing sent again. A message is 34 bytes on the line, and each side's actors reach the other's by pid. A pid from a bigger machine has to fit the board's 32-bit word, which holds for actors spawned at the start. `examples/mcu/tether.mettle` is the board and `examples/mcu/tether_host.mettle` the Linux process on its serial line.

Two boards can be tied the same way with no bigger machine: one device with several chips, each chip a place. `examples/mcu/asker.mettle` asks the first board for fifty numbers. The machine on the line can also pass the board's mail on (`src/tether/relay.mettle`), so the other machines of the link reach the board's actors by pid, and the board theirs. `examples/mcu/relay_host.mettle` has a third machine ask the board this way.

`src/board` makes a board a place that takes work. The board says which kinds it does, each a function from one word to one word. The machines find out by asking, and from then on the board is one more place, chosen by the same rule as a core or a GPU. A kind is not only done faster in one place than another: some kinds can be done in one place only. A machine with no way of its own to do a kind sends every job of it away, so work that only a board can do (read a sensor, move an arm) is asked for like any other. `examples/mcu/arm.mettle` and `examples/mcu/arm_host.mettle` are a board and a computer that share two kinds, one that both can do and one that only the board can.

A board is too small for a door and sends no beats, so two things differ from a Linux helper:

- The machine asks the board twice a second which kinds it does. A board silent for two seconds is taken for lost, its jobs are placed again, and it is found again when it answers.
- A pid inside a message does not cross the line, only the sender and the receiver do. So the board's answer about who does a kind is sent as from that actor.

A board asks for work too. It asks the door at the other end of its line who does a kind, and sends the job there. A door answers as from the actor it found, so the board learns that pid from who the answer is from. The other end can be a computer or another board, so two boards on one line share work with nothing else (`examples/mcu/two.mettle`).

A board must also know when its machine is gone, because a board that moves something has to stop then. The machine's question twice a second is the sign of life: the board counts them (`heard`), and a program that sees the count stand still for a second or two stops what it drives. It costs the board one add.

The board runs one job at a time, so a machine sends it at most four and a place has a limit for that. Nothing on the line is sent again: a job or an answer lost there is given up on after a second and placed again.

### Done at most once

A job whose answer is lost is placed again, so it can be done twice. For work that changes something that is wrong, so a kind can be marked as done at most once. The rule the asker then follows: a job not answered is sent again to the same worker under the same ref, and never placed anywhere else. The worker remembers, for each of four askers, the last four jobs it did and what each gave, and answers a job sent again from that memory.

What makes this hard is everything else that can happen: a copy that arrives late, a worker that was restarted and remembers nothing, an asker that was restarted and numbers its jobs from the start again, a worker wrongly taken for lost. The first design was explored by a program that tries every order of those events for small sizes. It found seven ways to do a job twice or to answer one job with another's result, the shortest in eight steps. The design that came through millions of states with none is this:

- A ref is a run and a number in it. An asker says hello before its first job, and each hello starts a run never used before (it is named by the clock). The hello wipes what the worker remembered of that asker.
- A job of any other run, or from an asker the worker does not know, is refused as lost. The asker then tells the program that every job it had out is lost: done or not, it cannot say. It never guesses.
- A ref at or under the worker's floor is an old copy and is dropped.
- A refusal counts as "not done" only for a job that was sent once. After a second sending only an answer settles it.
- No more jobs are out to a worker than it remembers.

It holds as long as the way between the two never delivers a message twice, which the link and the tether do not. In the test an asker and a worker have a way between them that loses a fifth of the messages each way, the worker is restarted every 600 ms and the asker is told it ended when it did not: of 150 jobs about 124 were done once and answered, about 26 were told lost (some done, some not), 15 to 19 were answered from memory, and none was done twice, in 60 runs of 60.

## Crossings

A message to another core moves cache lines over the memory bus. A job for the GPU moves data over PCIe. A message to another machine is a datagram. These are one thing, a crossing, and data is what makes a crossing expensive: a message is four words, data is megabytes. Two rules follow.

**Work travels, data stays.** Data has a home: the host, the GPU, or nowhere yet. A job names its data's home and goes there, and data crosses only when someone on the other side needs it. alph keeps separate times for a job run where its data is and one run away from it, so the cost of the crossing is part of choosing a place. In the test, where crossing costs 400 µs either way, 197 of 200 jobs with data on the host stayed on the cores and 191 of 200 with data on the GPU stayed on the GPU. When a core is to run a job whose data is on the GPU, the GPU's own place brings the data first, because only that thread may touch the GPU.

The render example first copied every tile back to the host as it finished. Measured on the GPU alone, a 64-pixel tile cost 13 µs that way, 9 µs with only a wait for it to finish, and 3.7 µs when the pixels stayed on the GPU and the picture was fetched once. For whole pictures the copy back was 80% of the job. The example now brings the picture to the host in one crossing, which made its GPU steps 5 to 15 times faster than before.

**A crossing carries everything that is waiting.** One lock, one launch or one datagram for a batch, not one each. The fetch above is this rule by hand.

Letting a node take eight messages in one visit to its lock, where it took one, made no difference: the 8-core storm, the two-core ping and the single-node ping all measured the same within noise, so it was taken out. The cost of a message between cores is the cache lines the sender and the receiver both touch, not how often the receiver takes its lock.

So `src/cores/lanes.mettle` gives each pair of cores a lane: a ring that only the sending core's thread writes and only the receiving core's thread reads, with no lock. The receiver empties its lanes into its actors' mailboxes when its queue is empty and after every sixteen messages. A sender wakes the receiver only when it is about to sleep in the kernel. A core knows a send is its own by the thread's id, so sends from any other thread (a timer, a socket, the link) keep taking the lock.

Measured in one program, lanes off and on in turn, on a machine at load 21 to 37: a stream from one core to another went from about 255 ns a message to 70, and a storm among 64 actors on 8 cores from 105 to 58. Two actors on two cores trading one message did not gain: 255 to 275 ns without, 290 to 300 with. Lanes are opt-in because they change what a sender is told. A message is in the lane, not yet in the mailbox, so a sender no longer hears that an actor is gone, and a full mailbox holds up its lane instead of refusing the sender. They are for Linux: on a board an interrupt runs on the hart it stops, so a hart cannot tell its own sends from an interrupt's. A board's image is the same to the byte with the lanes in the tree.

## Lives

A handler that returns non-zero ends its actor, and what it returned is the reason. A handler that crashes (a null pointer, a division by zero, an index past the end, a fault signal) ends its actor with the reason `ALPH_CRASHED`, and the node goes on. The port's guard saves a place to resume before each handler, and Mettle's runtime comes back to it. This is on Linux, in a program built with `-s`.

`src/life` decides what an end means for others:

- **Watching.** A watcher is sent `ALPH_ENDED` with the reason when the actor it watches ends. Watching one already gone says so at once. An actor is gone before anyone is told, so a watcher that hears of an end can no longer reach it.
- **Keeping.** A kept actor that fails or crashes is not ended. Its state is set up again and it goes on with the same pid and the mail it had, so nothing that knows it learns a new pid. After its last allowed restart it ends like any other.
- **Lost machines.** When a link reports a machine down, every actor watched on that machine ends for its watchers with the reason `ALPH_LOST`.

## Time

A timer sends a message later, so it is a layer (`src/time`), not part of the core. `after` sends a message in so many milliseconds and returns a ref, `cancel` takes it back. The port's alarm rings when the soonest timer is due: the board's timer interrupt on `mcu`, one sleeping thread on `host`.

`AlphTime` looks at every timer slot on every operation. That is the smallest code and right for tens of timers, so a board uses it. `src/time/wheel.mettle` is `AlphWheel`, the same four functions for thousands of timers. A timer waits in the spoke of the tick it is due in, so setting and cancelling one take the same time however many wait. With 10,000 timers waiting, a set and a cancel cost about 330 ns on the wheel against about 35,000 ns on the plain timers.

## Sockets and other programs

`src/poll` is how a socket, or any file descriptor, sends a message when it is ready. Handlers never wait. They read and write what can be done now, and ask to be told when there is more. One thread sleeps in the kernel until something is ready and sends the messages. Each asking is for one message, so a busy socket cannot flood a mailbox. The host port has TCP calls that never wait: `examples/talk.mettle` is an echo server with an actor for each connection, and the test runs twenty clients against one at once. The host port can also start another program and give back a descriptor that is ready when it has ended, so its end is a message too.

## Names and the door

`src/name` gives a pid a name: a number the program chooses.

`src/door` is how machines find and watch each other's actors, with nothing but messages. The door is the first actor a machine spawns, so its pid can be worked out from the machine's first place alone. An actor asks another machine's door for the pid behind a name and gets it back as a message. Watching works for an actor anywhere: the door on the actor's machine keeps the watch and tells the watcher's door when the actor ends. If that machine is lost first, the actor has ended with `ALPH_LOST`.

## The short way

A program that uses several layers repeats the same setup and bookkeeping. Two layers on top take that away. `src/machine` is a Linux machine with every layer set up in one call, with sizes that suit most programs. `src/batch` hands out one kind of work in pieces, takes each answer, hands out again what could not be placed, and says when all is back.

A machine says how a kind of job is done and that it is shared. It then does that kind for other machines, through its own places, and its own jobs of the kind may go to them. Every machine runs the same program, and the one whose actor begins a batch hands the work out. A job taken for another machine is not sent on again. Another machine does several jobs at once, so its cost is not its queue times one job. alph measures its pace, the time from one answer to the next while it has work, and takes a job sent now to be answered after everything waiting there and itself have each taken one pace, and never sooner than one job takes. With that a helper with many cores is given as much as it can do at once. With a boss of one working core and a helper of four, eight and twelve, 4,000 jobs of 2 ms took 1,734, 960 and 684 ms, where every core busy all the time would take about 1,600, 888 and 615: within a tenth. By the queue alone the same helpers were used as if they had two or three cores (800 jobs took 850 to 970 ms whatever the helper's size).

Each other machine is a place of its own, with its own work waiting and its own measured time, so a slow machine and a quick one that do the same kind are told apart. With one time for both, 80 jobs asked for one at a time all went to the slow machine, because it was listed first. With a time each, 78 went to the quick one. `examples/share.mettle` is about forty lines of its own.

## What was measured

The measurements that decide a choice are in the section for that choice: the render table, the crossing costs and the timer wheel. The rest are here, all on a busy machine. Tests with several machines run them in one process.

- Images: `examples/mcu/blink.mettle` is 3,256 bytes with board startup, about 1.3 KB of core, 1.1 KB of timers and alarm and the rest the board and the program. `check.sh` fails above 5 KB. `examples/mcu/harts.mettle` is 4,360 bytes and the `examples/mcu/tether.mettle` board 3,784.
- Cores, on a 16-CPU laptop: a message inside a node about 20 ns, between two cores 150 to 300 ns, and 4.8 million sent at random among 64 actors on 8 cores about 90 ns each.
- Link, over this computer's loopback: a request and its reply in 45 to 65 µs. With a quarter to a third of the messages deliberately lost, every request still crossed. A lost machine was noticed in 500 to 570 ms. 300 parcels of 1 to 1,024 bytes crossed whole and in order with a fifth to a quarter of the messages lost.
- Door: a lost machine's actors ended in about 540 ms.
- Work: `examples/far.mettle` with two cores here and one worker there sent about a third of the chunks across.
- Tether: a board in QEMU with a process on its line did 200 requests and replies.
- Board: the `examples/mcu/arm.mettle` image is 5,520 bytes with its kind done at most once and 4,544 without, and each of the two boards of `examples/mcu/two.mettle`, with timers, is 6,504. All 6 jobs only the board could do went to it. Of 200 chunks of primes that both could count, the computer did 196 and the board in QEMU 4. With the computer's chunks slowed to two milliseconds each and the board on another machine's line, the board did 7 of 400 and the machine on its line 191: the asking machine had timed each and sent the board little. When the board was stopped in the middle of a batch, all 400 pieces were still answered.
- Share: two machines each handed out 200 pieces at once and each answered all of its own rightly. With three machines and 300 pieces, the one that handed out did 110 and the other two 92 and 98. When one of the three was lost in the middle of a second batch, every piece was still answered.

## What is not built

- Restart limits counted over time rather than in all, and groups that restart together.
- Dropping a watch across machines.
- A crossing that carries everything waiting in the link, where every message is still a datagram of its own.
- A sealed link has one key for all, so any holder can speak as any machine and there is no forward secrecy. Peers are listed by hand.
- A board on the UDP link itself. A board joins through a serial line to one machine, and a line that sends again what was lost.
- A board that sends its work to the best of several places. It asks the machine at the other end of its line.
- A job for another machine with more than 1,024 bytes in or 1,016 back, or with its data on a GPU.
- A job's time predicted from more than its size. A Mandelbrot tile's time depends on where in the picture it is, so such work is placed less well.
- Sizes for `src/machine` other than the fixed ones.
- Sockets off Linux, and file IO.
- Catching a crash on a microcontroller, where it is still the board's trap.

## The first runtime

`src/core`, `src/heal`, `src/work`, `src/net`, `src/io`, `src/sched` and `src/sys` are the first runtime: 13,000 lines for x86-64 Linux, with supervision, IO, timers and distribution. It works and its tests run. It is the reference while its parts are rebuilt on the core, one layer at a time. What it still has that the new layers do not: a heap for each actor, and shutdown on a signal.
