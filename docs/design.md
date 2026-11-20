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

- Messages to a machine are numbered, and the machine says how far it has them. What it has not got in 40 ms is sent again. So messages arrive once and in order while both machines are up. A message for an actor whose mailbox is full is not taken either: it is sent again, and what is behind it waits, so a full mailbox slows a sender down and loses nothing. An actor with no room for half a second is not reading, and its message is then dropped: one stuck actor must not hold up everything else its machine is sent.
- Every machine tells its peers it is alive 20 times a second. One quiet for half a second is down: sends to it are refused and a watcher actor is told.
- A machine only out of reach carries on where it was. One that was restarted counts as a new machine, so mail meant for the old one is not handed to the new.

**Bytes.** A message can carry up to 1,024 bytes in a parcel, with the same numbering. The parcels are a pool the program gives the link. Half of it is kept for what arrives, so two machines sending to each other cannot each fill their pool and never take the other's. A machine with no parcel free takes no more, and the sender waits longer each time before sending again.

More bytes go as a long message. The link cuts it into pieces of 1,024 bytes, each numbered like any message, and the other end puts them together in a long buffer from a pool of its own. So the bytes are whole and in order for the same reason messages are, and nothing new had to be made sure. The pieces are sent straight from the sender's buffer as the window opens, and leave a quarter of the window to other messages, which would otherwise wait for as long as a long message takes. A long message that is too long for the other machine arrives without its bytes, so the actor it was for can say so. Between two machines in one process, 400 messages of 65,536 bytes crossed in about 200 ms, 125 MB a second, with a sum checked at the far end. With one datagram in seven lost each way, forty of up to 70,000 bytes all arrived whole.

A lost datagram used to cost the wait of a clock: 40 ms before the sender sent again. For single messages that is seldom felt. For a long message it was ruinous: with one datagram in a hundred lost, the 125 MB a second fell to 1.5. Now a machine that gets a message too early, which shows the one before it was lost, says so at once, and the sender sends again from there. With one in a thousand lost the same transfer runs at 96 MB a second, with one in a hundred at 64, and with one in twenty at 59. What follows a lost message is still sent again with it, because the receiver keeps nothing that came too early.

A message that finds its actor's mailbox full is not taken, and the sender is told. Most often the mailbox is full for a moment only: its actor was asleep and is awake now. The sender used to wait 5 ms before sending again. It now waits a tenth of a millisecond, and twice as long each time it is refused again, up to 4 ms. A stream of a million short messages to one actor, which fills its mailbox several hundred times on the way, went from about 140,000 a second to about 200,000. Plain datagrams between two threads on the same computer go at 256,000 a second, so one message a datagram cannot do much better.

So a datagram carries several. A short message that an actor sends is not put on the wire at once. It waits until its node next looks for mail, which is when the handler has returned and the node has nothing more to run, or a twentieth of a millisecond while it has. Whatever the node's actors sent meanwhile goes with it, thirteen to a datagram. A message sent alone leaves as soon as its handler returns, so a request and its reply took the same 27 µs as before. A burst does not pay for a datagram each: the same million messages now cross at about 1.2 million a second, six times faster and nearly five times what one datagram a message could ever do. What is sent again after a loss goes the same way, so a window of 64 is five datagrams, not 64.

Two things keep this from costing anything elsewhere. The link must know whether the thread that sends is one that runs a node, since only such a thread comes back to send what it held. It knows by where the thread's stack is, which costs no system call. And a node asks whether mail is held with one load of a word, so a node with no link, and every board, runs as before. A message from a thread that runs no node goes at once. One held by a handler that then works for a long time is sent by the link's own thread within a few milliseconds, or at once if the handler calls `flush`.

Most of what was left of those 27 µs was sleep. The link's thread slept in the kernel until the next datagram, and the core that had asked slept until its answer, each to be woken microseconds later, and a sleep and its wake cost more than the wait. Now the link looks for the next datagram for a twentieth of a millisecond after one has come before it sleeps. And a node learns how long to look for mail before it sleeps: one that was woken within a tenth of a millisecond of going to sleep looks twice as long next time, up to a limit, and one that slept long looks half as long, down to where it began. A request and its reply between two machines went from 27 to 30 µs down to 15 to 18, measured one after another 50,000 times on a busy computer. A node with nothing to do still sleeps.

A long message on its way to a machine that goes down is given up, and so is one arriving from it. Their buffers are free again at once, where a short message waits for the machine to come back. Otherwise one lost machine would hold the buffers that the others' work needs.

**Sealing.** A link is in the clear unless sealed. `src/seal` encrypts and signs every datagram (XChaCha20-Poly1305) with one key the whole network shares. A datagram made without the key, changed or played again is dropped, and so is everything from a run earlier than the latest heard, so a recording of an old run cannot make a dead machine look alive. It is its own layer, so a program that does not seal needs no crypto package.

**Work.** `src/place` has a third way to run a job: a worker actor on another machine, which the program finds by name through the door. To alph that is one more place with a time of its own, the network included, so a job goes there when that is where it will finish first.

- The job is one word in and one word out. It can carry up to a parcel's worth of bytes instead of the word in, and give back up to 1,016 bytes with the word out. With long buffers on both machines it carries and gives back as much as one buffer holds: a camera's frame, say. A machine whose buffers are too small for a job refuses it once, and no job as big is sent there again.
- If the worker ends or its machine is lost, the jobs it had not answered are done here and nothing more is sent to it.
- Given a clock, a job not answered in eight times its usual time, and at least a second, is given up on and placed again.

The other machine places the job again among its own cores and GPU, so a machine with no GPU uses another machine's by asking for the same kind of work. In `examples/picture.mettle` a boss with two working cores and no GPU draws 1,200 rows of 1,000 pixels with a helper that has one working core and an RTX 4070: the boss drew 296 to 402 rows itself and sent 798 to 904, of which the helper drew 742 to 810 on its GPU, in five runs, and every pixel matched the picture drawn on one core. With the helper's GPU hidden, 389 rows went to it and 811 stayed. The first job on a GPU pays for opening it, most of a second, so the helper opens its GPU before work arrives. A first job to another machine that takes that long is given up on and done here, and when its answer comes after all it is counted as that machine's warm-up, not as its speed.

`examples/frames.mettle` is the same with real data going both ways. A frame of 61,440 bytes is a job, and what comes back is the frame made smooth, each pixel the mean of the 225 around it: 9.5 ms on a core, 50 µs on the GPU. One function is the work on both, called on the frame where each has it. The boss has two working cores and no GPU, so 200 frames would take it about 950 ms. With the helper it took 190 to 220 ms: 180 frames went there as long messages, 178 of them to its GPU, and all 200 came back the same bytes as a core here makes. The frame crossing the link twice costs about a millisecond, which is why this work goes and cheap work stays: with a job that only finds edges, 60 µs on a core, alph kept 196 of 200 frames here.

`examples/far.mettle` counts the primes below two million on two machines. `examples/run.mettle` runs twelve commands, as a build would: each command's text is the bytes of a job, and its exit status comes back. The other machine runs it on its own cores through its own places, so the choice is made twice: which machine, then which core.

### Boards

`src/tether` ties a node to one other machine by a line of bytes, such as a board's serial port. It is the small way for a microcontroller to be a place: no numbering, no beats, nothing sent again. Each side's actors reach the other's by pid. A serial line is the slowest thing in such a machine, about 11 bytes a millisecond at 115,200 baud, so a message is made short for it: its nine numbers each go in as few bytes as they need, seven bits to a byte. A message that was 35 bytes on the line is 12 to 15, so a job's question and answer take about 2.5 ms of line where they took 6. The code that does it is kept out of line, and the board's image came out 344 bytes smaller than with the fixed layout, not bigger. The same was then tried on every function a board uses, one at a time: the compiler copies a small function into each place that calls it, and on a 32-bit chip reading the clock is not small, because the time is 64 bits. Kept out of line it took another 208 bytes off every image with timers. A pid from a bigger machine has to fit the board's 32-bit word, which holds for actors spawned at the start. `examples/mcu/tether.mettle` is the board and `examples/mcu/tether_host.mettle` the Linux process on its serial line.

Two boards can be tied the same way with no bigger machine: one device with several chips, each chip a place. `examples/mcu/asker.mettle` asks the first board for fifty numbers. The machine on the line can also pass the board's mail on (`src/tether/relay.mettle`), so the other machines of the link reach the board's actors by pid, and the board theirs. `examples/mcu/relay_host.mettle` has a third machine ask the board this way.

A line can be made sure (`AlphTether_sure`). Each message then goes out behind a seven-byte header with its number, how far the sender has the other side's messages, and each side's life, and what is not acknowledged is sent again. A board has no clock and nothing that differs from one start to the next, so a side that starts takes as its life one more than the life it first hears itself called: a restart shows as a change of life, and the numbering begins again by itself. Only one side needs a clock to drive resends, and on a machine the relay's thread is that clock. With a quarter of the frames lost each way and some damaged, 300 requests and replies arrived once each and in order in 20 runs of 20, in 19 to 27 seconds a run. It costs a board 1,128 bytes, and a board that does not turn it on is the same image to the byte.

`src/board` makes a board a place that takes work. The board says which kinds it does, each a function from one word to one word. The machines find out by asking, and from then on the board is one more place, chosen by the same rule as a core or a GPU. A kind is not only done faster in one place than another: some kinds can be done in one place only. A machine with no way of its own to do a kind sends every job of it away, so work that only a board can do (read a sensor, move an arm) is asked for like any other. `examples/mcu/arm.mettle` and `examples/mcu/arm_host.mettle` are a board and a computer that share two kinds, one that both can do and one that only the board can.

A board is too small for a door and sends no beats, so two things differ from a Linux helper:

- The machine asks the board twice a second which kinds it does. A board silent for two seconds is taken for lost, its jobs are placed again, and it is found again when it answers.
- A pid inside a message does not cross the line, only the sender and the receiver do. So the board's answer about who does a kind is sent as from that actor.

A board asks for work too. It asks the door at the other end of its line who does a kind, and sends the job there. A door answers as from the actor it found, so the board learns that pid from who the answer is from. The other end can be a computer or another board, so two boards on one line share work with nothing else (`examples/mcu/two.mettle`).

A computer has up to four serial lines, a board on each, so the two chips of an arm and the computer that plans are one machine. Each board is a place of its own with its own measured time. With two boards that both read angles, 60 jobs went 30 and 30.

On a board the outside world arrives as interrupts. `src/board/irq.mettle` makes a message of each: the port's interrupt handler passes a source that is not its own to a hook, and the hook sends the actor that asked for that source a message with a count. So a handler for a sensor is written like any other and may take its time, and the interrupt itself only quiets the device and puts four words in a mailbox. A board that uses no such source pays for one test in its interrupt handler.

A board must also know when its machine is gone, because a board that moves something has to stop then. The machine's question twice a second is the sign of life: the board counts them (`heard`), and a program that sees the count stand still for a second or two stops what it drives. It costs the board one add.

The board runs one job at a time, so a machine sends it at most four and a place has a limit for that. Nothing on the line is sent again: a job or an answer lost there is given up on after a second and placed again.

### Done at most once

A job whose answer is lost is placed again, so it can be done twice. For work that changes something that is wrong, so a kind can be marked as done at most once. The rule the asker then follows: a job not answered is sent again to the same worker under the same ref, and never placed anywhere else. The worker remembers, for each of eight askers, the last four jobs it did and what each gave, and answers a job sent again from that memory.

What makes this hard is everything else that can happen: a copy that arrives late, a worker that was restarted and remembers nothing, an asker that was restarted and numbers its jobs from the start again, a worker wrongly taken for lost. The first design was explored by a program that tries every order of those events for small sizes. It found seven ways to do a job twice or to answer one job with another's result, the shortest in eight steps. The design that came through millions of states with none is this:

- A ref is a run and a number in it. An asker says hello before its first job, and each hello starts a run never used before (it is named by the clock). The hello wipes what the worker remembered of that asker.
- A job of any other run, or from an asker the worker does not know, is refused as lost. The asker then tells the program that every job it had out is lost: done or not, it cannot say. It never guesses.
- A ref at or under the worker's floor is an old copy and is dropped.
- A refusal counts as "not done" only for a job that was sent once. After a second sending only an answer settles it.
- No more jobs are out to a worker than it remembers.

It holds as long as the way between the two never delivers a message twice, which the link and the tether do not. In the test an asker and a worker have a way between them that loses a fifth of the messages each way, the worker is restarted every 600 ms and the asker is told it ended when it did not: of 150 jobs about 124 were done once and answered, about 26 were told lost (some done, some not), 15 to 19 were answered from memory, and none was done twice, in 60 runs of 60.

A board follows the same rule when it asks (`src/board/asks.mettle`), with one difference. A computer names a run by its clock. A board has no clock that outlives a restart, so its port gives the number: the emulator's clock in QEMU, 18 random bits from the chip's ring oscillator on a Pico 2. In QEMU the first number after a start waits for the clock's next step, so it cannot be one from before the restart. On a Pico 2 each bit is 64 readings of the oscillator folded into one, because readings one after another are alike. Random bits repeat once in 262,144 starts at best, and a repeat only matters if a copy of an old job is still on its way then. In the check one board asks another for 32 jobs while every third answer is thrown away, the worker forgets everything once and the asker forgets everything once: most are done and answered rightly, the rest are told lost or were out when the asker forgot, and none is done twice. With the resend changed to take a new number, which is what a plain retry does, the same check fails.

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

A piece of work costs about half a microsecond to hand out and gather, two messages between cores and one actor that sees every answer, so a batch of very small pieces did not get faster with more cores. For work that is a function from a number to a number (`AlphMachine_piece`), `pieces` hands out several to a job: it does the first 32 alone to time one, then sends the rest in jobs of about a quarter of a millisecond of work, up to 64 pieces, whose answers come back as bytes. 200,000 pieces of no work at all went from 500 ns each to 20. Pieces of a microsecond take 130 to 170 ns each on eight cores, where they took 500. Pieces of 20 µs sent to a helper of eight cores go at about 330,000 a second, where one job a piece gave 110,000 to 190,000, because a job now holds more work than the way there and back takes. The same function is what a board shares, so one piece of code is the work on a board, a core and another machine.

A batch places late. A machine is told how many cores each other machine works on, and a batch's piece is sent only where fewer than two pieces wait for each core. A piece that would only wait stays with the batch until an answer is back, and then goes to whichever place is free. So how many pieces are out follows the cores there are, not a fixed number, and a place that turns slow holds two pieces a core and not a queue. A machine gives its batches the room for that (`AlphMachine_batch`). A boss of one working core and three helpers of 15 then did 4,000 jobs of 2 ms in about 180 ms, where every core busy would take about 173. With 16 out at most it took 562. Two helpers of 12 took 330 ms against 527, and three of 8 took 330 to 345 against 538. On one machine, and with one helper, the times are the same as before.

Each other machine is a place of its own, with its own work waiting and its own measured time, so a slow machine and a quick one that do the same kind are told apart. With one time for both, 80 jobs asked for one at a time all went to the slow machine, because it was listed first. With a time each, 78 went to the quick one. `examples/share.mettle` is about forty lines of its own.

## What was measured

The measurements that decide a choice are in the section for that choice: the render table, the crossing costs and the timer wheel. The rest are here, all on a busy machine. Tests with several machines run them in one process.

- Images: `examples/mcu/blink.mettle` is 3,048 bytes with board startup, about 1.3 KB of core, 0.9 KB of timers and alarm and the rest the board and the program. `check.sh` fails above 5 KB. `examples/mcu/harts.mettle` is 4,360 bytes and the `examples/mcu/tether.mettle` board 3,784.
- Cores, on a 16-CPU laptop: a message inside a node about 20 ns, between two cores 150 to 300 ns, and 4.8 million sent at random among 64 actors on 8 cores about 90 ns each.
- Link, over this computer's loopback: a request and its reply in 15 to 18 µs. With a quarter to a third of the messages deliberately lost, every request still crossed. A lost machine was noticed in 500 to 570 ms. 300 parcels of 1 to 1,024 bytes crossed whole and in order with a fifth to a quarter of the messages lost.
- Door: a lost machine's actors ended in about 540 ms.
- Work: `examples/far.mettle` with two cores here and one worker there sent about a third of the chunks across.
- Tether: a board in QEMU with a process on its line did 200 requests and replies.
- Board: the `examples/mcu/arm.mettle` image is 5,152 bytes with its kind done at most once and 4,176 without, and each of the two boards of `examples/mcu/two.mettle`, with timers, is 5,920. All 6 jobs only the board could do went to it. Of 200 chunks of primes that both could count, the computer did 196 and the board in QEMU 4. With the computer's chunks slowed to two milliseconds each and the board on another machine's line, the board did 7 of 400 and the machine on its line 191: the asking machine had timed each and sent the board little. When the board was stopped in the middle of a batch, all 400 pieces were still answered.
- Wide: with two helpers of eight working cores, a batch of 600 pieces had more than 34 out at once, never more than 16 waiting at a helper or 2 at the core here, and each helper did about 280.
- Share: two machines each handed out 200 pieces at once and each answered all of its own rightly. With three machines and 300 pieces, the one that handed out did 110 and the other two 92 and 98. When one of the three was lost in the middle of a second batch, every piece was still answered.

### One time

A robot's parts stamp what they measure, and a stamp is only worth something if the parts agree what time it is. Each machine has a clock of its own that started when it did. A machine's timekeeper asks the machine with the lowest places it reaches what time it is, takes the answer plus half the way there and back as the time now, and keeps the answer whose way was shortest, since that one was least in doubt. An older answer's way counts an eighth longer each round, so a clock that drifts is followed. The machine the others follow asks nobody. If it is lost the next lowest goes on from the time it had.

With three machines in one process whose clocks were set seven seconds ahead and three behind, readings taken together were 0 to 33 µs apart, and with the first machine lost the other two stayed within 20 µs while the time went on without a jump. That is over loopback, where the way there and back is about 15 µs. Over a real network it is as good as that way is steady.

A board asks the machine at the other end of its line for work, and that machine places the job as it would one of its own: on a core, on its GPU, or on another machine. So a board of a few kilobytes reaches whatever the network has, and never knows more than its one line. A job that came from another machine is still never sent on, so no job goes round. In the check a board asks a computer that cannot count primes for six chunks, and another computer counts them.

A board is too small to follow anyone, and has no need to. It stamps what it measures with its own clock and sends the stamp along. The machine on its line already asks the board's door something twice a second, and a board that has set its clock answers with what the clock reads. From the answer with the shortest way there and back the machine knows what the board's clock read at one moment of the shared time, and turns any stamp of the board's into that time. A board's tick is 1,024 µs, so this is good to a millisecond or two. Forty stamps of a board in QEMU all fell inside the moment their job was out. It cost the board's image no bytes.

## What is not built

- Restart limits counted over time rather than in all, and groups that restart together.
- Dropping a watch across machines.
- A crossing that carries everything waiting between the cores of one machine without lanes, and for messages with bytes, which still take a datagram each.
- A sealed link has one key for all, so any holder can speak as any machine and there is no forward secrecy. Peers are listed by hand.
- A board on the UDP link itself. A board joins through a serial line to one machine.
- A job for another machine with more bytes than a long buffer holds, or with its data on a GPU.
- A job's time predicted from more than its size. A Mandelbrot tile's time depends on where in the picture it is, so such work is placed less well.
- Sizes for `src/machine` other than the fixed ones.
- Sockets off Linux, and file IO.
- Catching a crash on a microcontroller, where it is still the board's trap.

## The first runtime

`src/core`, `src/heal`, `src/work`, `src/net`, `src/io`, `src/sched` and `src/sys` are the first runtime: 13,000 lines for x86-64 Linux, with supervision, IO, timers and distribution. It works and its tests run. It is the reference while its parts are rebuilt on the core, one layer at a time. What it still has that the new layers do not: a heap for each actor, and shutdown on a signal.
