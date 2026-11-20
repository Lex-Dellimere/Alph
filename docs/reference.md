# alph reference

This page lists the structs, constants and functions of the newer layers, with the comment from the source above each. It is built by `tools/apidoc.sh --new` from the source files, so do not edit it by hand. [docs/start.md](start.md) shows how to use the layers and [docs/design.md](design.md) says why they are built this way. A function named `Type_name__ptr` is a method: the line under its signature shows how to call it.

## alph/machine/machine

A machine: everything a Linux process needs to be one machine among
several, set up in one call. It is the layers put together with sizes
that suit most programs: up to 16 cores, 32 actors a core, 8 other
machines. A program that needs other sizes puts the layers together
itself, as this file does.

The first core has the door, a place for each other machine that work
can be sent to, and the program's own first actors. Every other core
takes work. With a GPU, the last core is the GPU's.

Sharing: a kind of job that is shared is done by whichever machine should
finish it first. Every machine runs the same program: each says how the
kind is done (kind) and that it is shared (share). The machine that asks
for work is the one that hands it out.

A board on a serial line (src/board) shares too, and a machine has up to
four serial lines, a board on each. It has no door and
sends no beats, so the machine asks it twice a second which kinds it
does. A board that has not answered for two seconds is taken for lost,
and found again when it answers. A board gets four jobs at a time and
each is one word in and one word out.

### `AlphMachine`

```mettle
export struct AlphMachine {
  cores: AlphCores;
  link: AlphLink;
  names: AlphNames;
  life: AlphLife;
  door: AlphDoor;
  time: AlphTime;
  places: AlphPlaces;
  far_place: Word;   // the place that sends work to the first other machine
  far_places: Word[8];  // and to each, in the order they were added
  peer_count: Word;
  steward: Word;     // the actor that finds other machines' workers
  told: Word;        // the program's actor that hears of machines coming and going
  served: Word;      // jobs done here for other machines
  shared: Word[8];   // by kind: shared or not
  asked: Word[64];   // by other machine and kind: the ref of the question to its door
  serving: AlphServing[8];
  taken: AlphTaken[32];
  done: AlphOnce[8];      // by kind: what is remembered of jobs that must not be done twice
  tether: AlphTether;     // the line to the first board on this machine's own lines,
  more: AlphTether[3];    // and to the second, third and fourth
  lines: Word;            // how many boards are on this machine's own lines
  boards: AlphOnLine[4];  // the boards work is shared with
  board_count: Word;
  round_at: Word;         // when the boards are asked next
  round_owed: Word;       // the word to ask them could not be sent: send it with the next message
  board_refs: Word;       // refs for questions to boards: small, to fit the 32 bits a line carries
  // The memory the layers work in.
  core: AlphCore[16];
  actors: AlphActor[512];
  mail: AlphMsg[8192];
  peers: AlphPeer[8];
  parcels: AlphParcel[16];
  name_slots: AlphName[32];
  watches: AlphWatch[64];
  keeps: AlphKeep[32];
  timers: AlphTimer[32];
  seats: AlphPlace[26];
  gives: Word[8];         // by kind: the most bytes a job gives back (gives)
  longs: AlphLong[16];    // the link's long buffers, in the program's memory (longs)
  worked: AlphBatch;      // the batch of the last work (work): its counts are the program's to read
  work_actor: Word;       // the actor that hands it out
  work_kind: Word;
  work_total: Word;
  work_fill: fn(AlphBatch*, AlphJob*, Word) -> void;
  work_took: fn(AlphBatch*, AlphJob*, Word) -> void;
  work_ctx: rawptr;
  run: Word;              // pieces: how many go in one job,
  run_first: Word;        // the piece the jobs of this batch start from,
  run_total: Word;        // how many pieces there are in all,
  run_least: Word;        // the least time one piece took when tried alone here, in ns,
  run_least_far: Word;    // and on another machine, the way there and back included,
  run_undone: Word;       // pieces not done,
  run_took: fn(Word, Word, rawptr) -> void;  // and the program's function for each answer,
  run_ctx: rawptr;        // with its own
  outs: uint8[73728];     // what each job of several pieces gives back: 512 bytes a slot
  timekeeper: Word;       // the actor that keeps this machine's time in step with the others' (now)
  time_off: Word;         // what is added to this machine's own clock to give that time, in ns
  time_trip: Word;        // the way there and back of the asking it came from, in ns: -1 before any
  time_asked: Word;       // the ref of the asking that is out, 0 for none,
  time_sent: Word;        // and when it went, by this machine's own clock
  time_rounds: Word;      // askings answered
  time_skew: Word;        // for tests: added to this machine's own clock
  slots: AlphBatchSlot[128];  // room for the batches tied to this machine (batch)
  slots_used: Word;
  far_times: AlphTimes[96];  // each other machine's and board's own times, eight kinds each
  kinds: AlphKind[8];
}
```

One machine: its layers, what it shares, and the memory they work in.

### `AlphMachine_init__ptr`

```mettle
export fn AlphMachine_init__ptr(m: AlphMachine*, cores: Word, first: Word, gpu: bool)
```

Call it as `m->init(cores, first, gpu)`, or `m.init(cores, first, gpu)` on a value.

Sets the machine up with `cores` cores (1 to 16), its places starting at
`first`. With gpu, the last core is the GPU's place and takes no other
work. Call it before anything else.

### `AlphMachine_peer__ptr`

```mettle
export fn AlphMachine_peer__ptr(m: AlphMachine*, first: Word, count: Word, ip: uint32, port: int64) -> Word
```

Call it as `m->peer(first, count, ip, port)`, or `m.peer(first, count, ip, port)` on a value.

Another machine: where its places start, how many it has, and where it
listens. It gets a place of its own here, which work for it goes through.
Returns ALPH_FULL after eight.

### `AlphMachine_board__ptr`

```mettle
export fn AlphMachine_board__ptr(m: AlphMachine*, first: Word, count: Word) -> Word
```

Call it as `m->board(first, count)`, or `m.board(first, count)` on a value.

A board on one of this machine's serial lines (src/board): where its
places start and how many it has. This machine passes the board's mail
on, so the other machines and its other boards reach it too. Give the
port the line's descriptor first (alph_line_open): the board is on the
line opened last. Call it before start and run, once for each board, up
to four. Returns ALPH_FULL when there is no room for it.

### `AlphMachine_line__ptr`

```mettle
export fn AlphMachine_line__ptr(m: AlphMachine*, n: Word) -> AlphTether*
```

Call it as `m->line(n)`, or `m.line(n)` on a value.

The line to the n-th board added with board, counted from 0: for making
it sure (AlphTether_sure), say. 0 when n is not 0 to 3.

### `AlphMachine_beyond__ptr`

```mettle
export fn AlphMachine_beyond__ptr(m: AlphMachine*, peer: Word, first: Word, count: Word) -> Word
```

Call it as `m->beyond(peer, first, count)`, or `m.beyond(peer, first, count)` on a value.

A board on another machine's serial line: peer is where that machine's
places start, and it must be a peer already. Returns ALPH_GONE when it
is not, ALPH_FULL when there is no room for the board.

### `AlphMachine_kind__ptr`

```mettle
export fn AlphMachine_kind__ptr(m: AlphMachine*, kind: Word, cpu: fn(AlphJob*) -> Word, gpu: fn(AlphJob*) -> Word)
```

Call it as `m->kind(kind, cpu, gpu)`, or `m.kind(kind, cpu, gpu)` on a value.

Says how a kind of job (0 to 7) is done on a core and on the GPU, 0 for a
way it does not have.

### `AlphMachine_share__ptr`

```mettle
export fn AlphMachine_share__ptr(m: AlphMachine*, kind: Word) -> Word
```

Call it as `m->share(kind)`, or `m.share(kind)` on a value.

Shares a kind with the other machines: this machine does it for them, and
its own jobs of the kind may go to them. Call it after kind, on every
machine that should take part. A machine with no way of its own to do
the kind (kind was given 0 and 0) only sends it: that is how work only a
board can do, such as moving an arm, is asked for here. Only jobs with no
home (a word in, or bytes) leave a machine. Returns ALPH_FULL when the
first core has no room for one more actor, ALPH_GONE for a kind that is
not 0 to 7.

### `AlphMachine_longs__ptr`

```mettle
export fn AlphMachine_longs__ptr(m: AlphMachine*, memory: uint8*, each: Word, count: Word)
```

Call it as `m->longs(memory, each, count)`, or `m.longs(memory, each, count)` on a value.

Gives the machine long buffers, so that a job for another machine can
carry more bytes than a parcel holds, and give more back: `count` of
them (up to 16), each of `each` bytes, in `memory`, which must hold
count times each. A job's bytes, or what it gives back and eight bytes
more, must fit one. Half are kept for what arrives. Call it on every
machine, before start.

### `AlphMachine_gives__ptr`

```mettle
export fn AlphMachine_gives__ptr(m: AlphMachine*, kind: Word, bytes: Word)
```

Call it as `m->gives(kind, bytes)`, or `m.gives(kind, bytes)` on a value.

Says that a job of this kind (0 to 7) gives back up to `bytes` bytes.
Needed only for more than ALPH_BACK_BYTES: a job taken for another
machine then gets a long buffer to put them in (see longs). Call it on
every machine.

### `AlphMachine_batch__ptr`

```mettle
export fn AlphMachine_batch__ptr(m: AlphMachine*, b: AlphBatch*)
```

Call it as `m->batch(b)`, or `m.batch(b)` on a value.

Ties a batch to this machine, in place of the batch's own init, with
room for two pieces out for each core at work here and on the machines
it was given, for what each board holds, and for sixteen answers on
their way. Call it after the last peer
and board. The machine has room for 128
pieces out over all its batches: a batch that finds less left than it
could use takes what there is, or keeps its own sixteen.

### `AlphMachine_once__ptr`

```mettle
export fn AlphMachine_once__ptr(m: AlphMachine*, kind: Word)
```

Call it as `m->once(kind)`, or `m.once(kind)` on a value.

Says that a job of this kind (0 to 7) is never done twice, whatever is
lost on the way: see AlphPlaces_once. Call it after kind, on every
machine. A piece whose worker was lost comes back with the status
ALPH_LOST.

### `AlphMachine_tell__ptr`

```mettle
export fn AlphMachine_tell__ptr(m: AlphMachine*, pid: Word)
```

Call it as `m->tell(pid)`, or `m.tell(pid)` on a value.

The program's actor that is told ALPH_UP and ALPH_DOWN as other machines
come and go.

### `AlphMachine_start__ptr`

```mettle
export fn AlphMachine_start__ptr(m: AlphMachine*, port: int64) -> Word
```

Call it as `m->start(port)`, or `m.start(port)` on a value.

Listens on a port and joins the other machines. Returns ALPH_GONE when
the port cannot be had. A machine with no peers need not call it.

### `AlphMachine_now__ptr`

```mettle
export fn AlphMachine_now__ptr(m: AlphMachine*) -> Word
```

Call it as `m->now()`, or `m.now()` on a value.

The time the machines agree on, in nanoseconds. Every machine follows
the one with the lowest places among those it reaches, so all of them
read about the same time at the same moment: within the way to that
machine and back, which apart says. Use it to stamp what one machine
measures so that another can order it, or to act at the same moment on
several. It can step by that much when a better asking comes in. A
machine with no peers reads its own clock.

### `AlphMachine_board_now__ptr`

```mettle
export fn AlphMachine_board_now__ptr(m: AlphMachine*, first: Word, ticks: Word) -> Word
```

Call it as `m->board_now(first, ticks)`, or `m.board_now(first, ticks)` on a value.

The machines' time (now) at which a board's clock read `ticks`: a stamp
the board took with its alph_now and sent along with what it measured.
The board must have set its clock (AlphBoard's clock) and be on this
machine's own line, with its first place `first`. A board's tick is
1,024 microseconds, so this is good to a millisecond or two, and to the
way to the board and back. Returns -1 while the board's clock has not
been heard.

### `AlphMachine_apart__ptr`

```mettle
export fn AlphMachine_apart__ptr(m: AlphMachine*) -> Word
```

Call it as `m->apart()`, or `m.apart()` on a value.

How far now may be from the time of the machine this one follows, in
nanoseconds: half the way there and back of the asking it was set from.
0 on the machine the others follow, and -1 on one that has not heard
from it yet.

### `AlphMachine_work__ptr`

```mettle
export fn AlphMachine_work__ptr(m: AlphMachine*, kind: Word, total: Word,
                                fill: fn(AlphBatch*, AlphJob*, Word) -> void,
                                took: fn(AlphBatch*, AlphJob*, Word) -> void, ctx: rawptr) -> Word
```

Call it as `m->work(kind, total, fill, took, ctx)`, or `m.work(kind, total, fill, took, ctx)` on a value.

Does `total` pieces of a kind of work and returns when every one is
answered: the short way to use a batch. fill and took are a batch's (see
AlphBatch_begin), and so is ctx. fill may be 0 when a piece needs only
its number, which is the job's in. It runs the cores on this thread, so
call it from the program's main thread, after kind, the peers and start,
and not from an actor. It can be called again for more work. Returns
how many pieces were not done: those no place could run and those lost
with their worker. m->worked is the batch, for its counts by way.

### `AlphMachine_piece__ptr`

```mettle
export fn AlphMachine_piece__ptr(m: AlphMachine*, kind: Word, run: fn(Word) -> Word)
```

Call it as `m->piece(kind, run)`, or `m.piece(kind, run)` on a value.

Says how one piece of a kind (0 to 7) is done: a function from a number
to a number, with nothing else going in or out, so it can run on any
core of any machine. It takes the place of kind for such work, and
pieces then hands the work out. A board shares the same function with
AlphBoard_share. Call it on every machine, then share.

### `AlphMachine_pieces__ptr`

```mettle
export fn AlphMachine_pieces__ptr(m: AlphMachine*, kind: Word, total: Word,
                                  took: fn(Word, Word, rawptr) -> void, ctx: rawptr) -> Word
```

Call it as `m->pieces(kind, total, took, ctx)`, or `m.pieces(kind, total, took, ctx)` on a value.

Does pieces 0 to total - 1 of a kind set up with piece, and returns when
all are answered. took is called with each piece's number, what it gave,
and ctx. Pieces of little work are handed out several to a job, so that
handing out costs little beside the work: the first few are done alone
to time one, and the rest go in jobs of about a quarter of a millisecond
of work, up to 64 pieces. Call it as work is called. Returns how many
pieces were not done.

### `AlphMachine_run__ptr`

```mettle
export fn AlphMachine_run__ptr(m: AlphMachine*)
```

Call it as `m->run()`, or `m.run()` on a value.

Runs the cores until stop, the first on this thread.

### `AlphMachine_stop__ptr`

```mettle
export fn AlphMachine_stop__ptr(m: AlphMachine*)
```

Call it as `m->stop()`, or `m.stop()` on a value.

Stops the cores, so run returns. Any actor or thread may call it.

### `AlphMachine_shut__ptr`

```mettle
export fn AlphMachine_shut__ptr(m: AlphMachine*)
```

Call it as `m->shut()`, or `m.shut()` on a value.

Ends the timers and leaves the other machines. Call it after run has
returned.

## alph/batch/batch

A batch: one kind of work in many pieces. The batch hands the pieces to
the places, takes each answer, asks again for a piece that could not be
placed, and says when all are back. It is what a program would otherwise
write around the places every time.

A piece goes out only when a place can start it soon (offer), so the
batch finds by itself how many to have out: about two for each core at
work, here or on another machine. It has room for sixteen out at once.
With more cores than about eight in all, give it more room (wide).

An actor owns a batch. It begins it, and passes it every message it gets:
took says whether the message was the batch's.

### `AlphBatchSlot`

```mettle
export struct AlphBatchSlot {
  job: AlphJob;
  piece: Word;  // the piece the job carries
  free: Word;   // a list of slots not in use,
  again: Word;  // and one of pieces to hand out again
}
```

Room for one piece that is out: its job, and three words the batch keeps
its lists in.

### `AlphBatch`

```mettle
export struct AlphBatch {
  places: AlphPlaces*;
  kind: Word;
  total: Word;
  next: Word;        // the next piece not yet handed out
  back: Word;        // pieces answered
  gone: Word;        // of those, pieces no place could run,
  lost: Word;        // and pieces done at most once whose worker was lost: done or not, no one can say
  out: Word;         // pieces handed out and not yet answered
  by_way: Word[3];   // how many each way did: ALPH_CPU, ALPH_GPU, ALPH_FAR
  fill: fn(AlphBatch*, AlphJob*, Word) -> void;
  each: fn(AlphBatch*, AlphJob*, Word) -> void;  // called with every answer
  ctx: rawptr;       // the program's own
  nudged: Word;
  begun: Word;
  again_count: Word;
  free_count: Word;
  slots: AlphBatchSlot*;  // its own, or the room the program gave (wide)
  room: Word;
  own: AlphBatchSlot[16];
}
```

One batch, and the sixteen slots its pieces go out in.

### `AlphBatch_init__ptr`

```mettle
export fn AlphBatch_init__ptr(b: AlphBatch*, places: AlphPlaces*)
```

Call it as `b->init(places)`, or `b.init(places)` on a value.

Ties a batch to the places its pieces will go to. Call it once, before begin.

### `AlphBatch_wide__ptr`

```mettle
export fn AlphBatch_wide__ptr(b: AlphBatch*, slots: AlphBatchSlot*, count: Word)
```

Call it as `b->wide(slots, count)`, or `b.wide(slots, count)` on a value.

Gives a batch room for `count` pieces out at once, in place of its own
sixteen: about two for each core at work on all the machines is enough.
Call it after init, while no batch is running.

### `AlphBatch_begin__ptr`

```mettle
export fn AlphBatch_begin__ptr(b: AlphBatch*, a: AlphActor*, kind: Word, total: Word,
                               fill: fn(AlphBatch*, AlphJob*, Word) -> void,
                               took: fn(AlphBatch*, AlphJob*, Word) -> void, ctx: rawptr) -> Word
```

Call it as `b->begin(a, kind, total, fill, took, ctx)`, or `b.begin(a, kind, total, fill, took, ctx)` on a value.

Starts handing out `total` pieces of a kind. fill is called for each
piece before it goes out, with the job and the piece's number (0 to
total - 1): it sets what the job needs (size, in, data, bytes, back,
home; the job starts with size 1, in the piece's number and no home). It
may be 0 when that start is all a piece needs. took is
called with each piece's finished job: its status is ALPH_OK, ALPH_GONE
for a piece no place could run, or ALPH_LOST for a piece of a kind done
at most once whose worker was lost. ctx is the program's own, in
b->ctx. Call it from the actor that will get the answers. Returns
ALPH_OK, or ALPH_FULL when pieces of the batch before are still out: a
batch is begun again only once it is over.

### `AlphBatch_took__ptr`

```mettle
export fn AlphBatch_took__ptr(b: AlphBatch*, a: AlphActor*, m: AlphMsg*) -> bool
```

Call it as `b->took(a, m)`, or `b.took(a, m)` on a value.

Give the batch every message its actor gets. Returns true when the
message was the batch's: an answer, which it has passed to took, or its
own word to itself.

### `AlphBatch_over__ptr`

```mettle
export fn AlphBatch_over__ptr(b: AlphBatch*) -> bool
```

Call it as `b->over()`, or `b.over()` on a value.

Whether every piece of a batch that was begun has been answered. A batch
of no pieces is over at once.

## alph/board/board

A board: what a microcontroller needs to be one machine among several,
set up in one call. It is a node, the line to the machine at the other
end, and an actor for each kind of work it does for the others.

A kind here is a function from one word to one word. The bigger machines
find out by asking that the board does it (see AlphMachine_board), and
from then on the board is one more place their work can go.

A board asks for work too (ask): the machine at the other end of the
line does the kind, whether that is a computer or another board. So two
boards on one line share work with no bigger machine at all.

The board runs one job at a time, and nothing else while it does. A
machine that hears nothing from it for two seconds takes it for lost, so
a job should take well under that.

A board that stamps what it measures sets b->clock to its port's
alph_now. Its door then says what the clock reads each time it is asked,
and the machine at the other end can turn a stamp of the board's into
the time all the machines share (AlphMachine_board_now).

A machine that shares work with a board asks its door something twice a
second. b->heard goes up each time, so a board that moves something
looks at it on a timer of its own: if it has not gone up for a second
or two, the machine is gone or the line is cut, and the board stops
safely.

Sizes: 12 actors, 8 messages a mailbox, 8 kinds. A program that needs
others puts the node and the tether together itself, as this file does.

### `AlphBoard`

```mettle
export struct AlphBoard {
  node: AlphNode;
  tether: AlphTether;
  served: Word;       // jobs done for other machines
  heard: Word;        // goes up each time a machine asks this board's door anything
  workers: Word[8];   // by kind: the actor that does it, 0 for none
  helpers: Word[8];   // by kind: the actor down the line that does it, 0 while not known
  door: Word;
  clock: fn() -> Word;  // the board's own clock, 0 for none: set it to alph_now and a machine can read the board's stamps
  kinds: AlphBoardKind[8];
  actors: AlphActor[12];
  mail: AlphMsg[96];
}
```

A board: its node, its line, what it shares, and the memory they work in.

### `AlphBoard_init__ptr`

```mettle
export fn AlphBoard_init__ptr(b: AlphBoard*, place: Word, first: Word, count: Word)
```

Call it as `b->init(place, first, count)`, or `b.init(place, first, count)` on a value.

Sets the board up as place `place`, tied by the port's line to a machine
whose places are first, first + 1, ... Call it before anything else. The
program's own actors are spawned on b->node.

### `AlphBoard_share__ptr`

```mettle
export fn AlphBoard_share__ptr(b: AlphBoard*, kind: Word, run: fn(Word) -> Word) -> Word
```

Call it as `b->share(kind, run)`, or `b.share(kind, run)` on a value.

Does a kind of work (0 to 7) for the other machines: run is given a
job's in and returns its out. Returns ALPH_OK, ALPH_FULL when there is
no actor left for it, ALPH_GONE for a kind that is not 0 to 7 or is
shared already.

### `AlphBoard_ask__ptr`

```mettle
export fn AlphBoard_ask__ptr(b: AlphBoard*, a: AlphActor*, kind: Word, in: Word) -> Word
```

Call it as `b->ask(a, kind, in)`, or `b.ask(a, kind, in)` on a value.

Asks the machine at the other end of the line to do a job of a kind it
shares. The answer comes to `a` as ALPH_WORKED with the job's out in arg
and the ref this returns, or as ALPH_REFUSED when that machine cannot
take it. Returns ALPH_FULL while the board does not know yet who does
the kind there: it has asked, so ask again shortly. Returns ALPH_GONE
for a kind that is not 0 to 7. The line sends nothing again, so a
program that must have its answer asks once more when none has come.

### `AlphBoard_run__ptr`

```mettle
export fn AlphBoard_run__ptr(b: AlphBoard*)
```

Call it as `b->run()`, or `b.run()` on a value.

Runs the board until stop.

### `AlphBoard_stop__ptr`

```mettle
export fn AlphBoard_stop__ptr(b: AlphBoard*)
```

Call it as `b->stop()`, or `b.stop()` on a value.

Stops the board, so run returns.

## alph/board/once

A kind of work a board does at most once, whatever is lost on the way:
work that changes something, such as moving an arm. It is apart from
alph/board/board so that a board with no such kind pays nothing for it.

The board remembers the last jobs it did for each asker (alph/place/once
says how). A job sent again is answered from that memory and not done
again. A job from an asker the board does not know, because the board
was restarted since, is refused as lost: that asker then knows it cannot
tell whether the job was done.

### `AlphBoardOnce`

```mettle
export struct AlphBoardOnce {
  board: AlphBoard*;
  run: fn(Word) -> Word;
  memory: AlphOnce;
}
```

One such kind: how it is done and what is remembered. The program hands
it in.

### `AlphBoard_share_once__ptr`

```mettle
export fn AlphBoard_share_once__ptr(b: AlphBoard*, kind: Word, run: fn(Word) -> Word, once: AlphBoardOnce*) -> Word
```

Call it as `b->share_once(kind, run, once)`, or `b.share_once(kind, run, once)` on a value.

Does a kind of work (0 to 7) for the other machines, each job at most
once: run is given a job's in and returns its out, and `once` is the
memory for it. The machines must ask for the kind the same way
(AlphMachine_once). Returns ALPH_OK, ALPH_FULL when there is no actor
left for it, ALPH_GONE for a kind that is not 0 to 7 or is shared
already.

## alph/board/irq

Interrupts as messages, on a board. A source of external interrupts (a
pin, a sensor that has a reading, a counter that wrapped) is given an
actor and a tag: each interrupt sends that actor one message, with the
source in arg and how many there have been in ref. The handler then runs
like any other, outside the interrupt, so it may take its time.

A device that keeps asking until it is answered has to be quieted in the
interrupt itself, or the interrupt comes again at once: give a function
for that. It runs in the interrupt and should do nothing else.

If the actor's mailbox is full the message is lost and the count still
goes up, so the actor sees from ref that it missed some.

### `AlphIrq`

```mettle
export struct AlphIrq {
  source: Word;
  to: Word;
  tag: Word;
  count: Word;
  quiet: fn(Word) -> void;
}
```

One source: who is told, and how.

### `alph_irqs`

```mettle
export fn alph_irqs(node: AlphNode*, irqs: AlphIrq*, room: Word)
```

Gives the interrupts their node and the memory for `room` sources. Call
it once, before the first on.

### `alph_irq`

```mettle
export fn alph_irq(source: Word, to: Word, tag: Word, quiet: fn(Word) -> void) -> Word
```

From now on each interrupt from `source` sends `to` a message with this
tag. quiet, if not 0, is called in the interrupt first, to stop the
device asking. Returns ALPH_OK, or ALPH_FULL when every source is taken.

## alph/actor/actor

alph's core: actors, messages and the loop that runs them.

An actor is a state and a handler. A message is four words. A node holds
the actors and runs one message at a time. Everything else (time, IO, a
GPU, other cores, other machines) is something that sends messages.

A pid names a place, a slot there and which actor the slot held. A node is
one place. Mail for any other place goes to the node's far function.

The node owns no memory: the caller hands it the actor slots and the
mailboxes. What differs between devices lives in the port, picked at
build time with -I ports/<name>.

What a send returns: sent, the mailbox is full, or there is no such actor.

```mettle
export const ALPH_OK: Word = 0;
export const ALPH_FULL: Word = -1;  // the mailbox is full
export const ALPH_GONE: Word = -2;  // no such actor
export const ALPH_END: Word = 1;       // a handler returns this when its actor is finished
export const ALPH_CRASHED: Word = -9;  // the reason an actor ends with when its handler crashes
export const ALPH_LOST: Word = -8;     // the reason when an actor's machine was lost, and what a job is when no one can say whether it was done
```

### `AlphMsg`

```mettle
export struct AlphMsg {
  tag: Word;
  from: Word;
  arg: Word;
  ref: Word;
}
```

A message: four words.

### `AlphActor`

```mettle
export struct AlphActor {
  next: AlphActor*;
  node: AlphNode*;
  pid: Word;     // this slot's pid; the next one's once the actor is gone
  alive: Word;
  queued: Word;  // on the run queue, or running
  handle: fn(AlphActor*, AlphMsg*) -> Word;
  state: rawptr;
  mail: AlphMsg*;
  head: Word;
  count: Word;
}
```

An actor: a state, a handler and a mailbox. The handler is given the
actor and one message at a time.

### `AlphNode`

```mettle
export struct AlphNode {
  gate: AlphGate;
  actors: AlphActor*;
  slots: Word;
  room: Word;   // messages a mailbox holds
  free: AlphActor*;       // the slot free the longest: the next one used
  free_last: AlphActor*;
  first: AlphActor*;
  last: AlphActor*;
  live: Word;
  stopped: Word;
  refs: Word;   // the last ref given out
  place: Word;
  far: fn(AlphNode*, Word, AlphMsg*) -> Word;
  world: rawptr;  // whoever set far
  ended: fn(AlphNode*, AlphActor*, Word) -> Word;
  life: rawptr;   // whoever set ended
  guard: AlphGuard;
  running: AlphActor*;  // the actor whose handler is running
  held: int32*;  // not 0 and not at 0: mail for other machines waits for this node to send it (src/link)
}
```

A node: the actors of one place. It runs one message at a time.

### `AlphNode_init__ptr`

```mettle
export fn AlphNode_init__ptr(n: AlphNode*, actors: AlphActor*, slots: Word, mail: AlphMsg*, room: Word)
```

Call it as `n->init(actors, slots, mail, room)`, or `n.init(actors, slots, mail, room)` on a value.

mail holds slots * room messages.

### `AlphNode_join__ptr`

```mettle
export fn AlphNode_join__ptr(n: AlphNode*, place: Word, far: fn(AlphNode*, Word, AlphMsg*) -> Word,
                             world: rawptr)
```

Call it as `n->join(place, far, world)`, or `n.join(place, far, world)` on a value.

Makes the node one place of many: far takes the mail for the others.
Call it before the first spawn.

### `AlphNode_on_end__ptr`

```mettle
export fn AlphNode_on_end__ptr(n: AlphNode*, ended: fn(AlphNode*, AlphActor*, Word) -> Word, life: rawptr)
```

Call it as `n->on_end(ended, life)`, or `n.on_end(ended, life)` on a value.

Has ended called whenever a handler returns non-zero, with the actor and
what the handler returned, before the actor is gone. If ended returns
non-zero the actor is not ended: it keeps its pid and its mail.

### `AlphNode_bury__ptr`

```mettle
export fn AlphNode_bury__ptr(n: AlphNode*, a: AlphActor*)
```

Call it as `n->bury(a)`, or `n.bury(a)` on a value.

For ended to call, on an actor it will let end: from here mail for it is
refused and it counts as gone, so whoever is told next that it ended
cannot still reach it.

### `AlphNode_alive__ptr`

```mettle
export fn AlphNode_alive__ptr(n: AlphNode*, pid: Word) -> bool
```

Call it as `n->alive(pid)`, or `n.alive(pid)` on a value.

Whether a pid names an actor here that is alive now.

### `AlphNode_spawn__ptr`

```mettle
export fn AlphNode_spawn__ptr(n: AlphNode*, handle: fn(AlphActor*, AlphMsg*) -> Word,
                              state: rawptr) -> Word
```

Call it as `n->spawn(handle, state)`, or `n.spawn(handle, state)` on a value.

Returns the new actor's pid, or 0 when every slot is taken.

### `AlphNode_put__ptr`

```mettle
export fn AlphNode_put__ptr(n: AlphNode*, to: Word, m: AlphMsg*) -> Word
```

Call it as `n->put(to, m)`, or `n.put(to, m)` on a value.

Delivers a whole message. ALPH_FULL and ALPH_GONE are refusals.

### `AlphNode_deliver__ptr`

```mettle
export fn AlphNode_deliver__ptr(n: AlphNode*, to: Word, m: AlphMsg*) -> Word
```

Call it as `n->deliver(to, m)`, or `n.deliver(to, m)` on a value.

Put for an actor here, by code already inside the node's gate: what
gathers mail that came another way. Returns ALPH_OK, ALPH_FULL or
ALPH_GONE.

### `AlphNode_send__ptr`

```mettle
export fn AlphNode_send__ptr(n: AlphNode*, to: Word, tag: Word, arg: Word) -> Word
```

Call it as `n->send(to, tag, arg)`, or `n.send(to, tag, arg)` on a value.

From outside an actor: another thread, an interrupt, main.

### `AlphActor_send__ptr`

```mettle
export fn AlphActor_send__ptr(a: AlphActor*, to: Word, tag: Word, arg: Word) -> Word
```

Call it as `a->send(to, tag, arg)`, or `a.send(to, tag, arg)` on a value.

Sends a message from this actor. Returns ALPH_OK, ALPH_FULL when the
mailbox it is for is full, ALPH_GONE when there is no such actor.

### `AlphActor_ask__ptr`

```mettle
export fn AlphActor_ask__ptr(a: AlphActor*, to: Word, tag: Word, arg: Word) -> Word
```

Call it as `a->ask(to, tag, arg)`, or `a.ask(to, tag, arg)` on a value.

Sends a request. Returns its ref (above 0), which the reply carries, or
ALPH_FULL or ALPH_GONE.

### `AlphActor_reply__ptr`

```mettle
export fn AlphActor_reply__ptr(a: AlphActor*, m: AlphMsg*, tag: Word, arg: Word) -> Word
```

Call it as `a->reply(m, tag, arg)`, or `a.reply(m, tag, arg)` on a value.

Answers m: the same ref goes back to its sender.

### `AlphNode_stop__ptr`

```mettle
export fn AlphNode_stop__ptr(n: AlphNode*)
```

Call it as `n->stop()`, or `n.stop()` on a value.

Makes run return once the handler in progress is done. Before run, it
makes the next run return at once.

### `AlphNode_run__ptr`

```mettle
export fn AlphNode_run__ptr(n: AlphNode*)
```

Call it as `n->run()`, or `n.run()` on a value.

Runs actors until stop. A handler that returns non-zero ends its actor,
and what it returned is the reason. A handler that crashes ends its actor
with ALPH_CRASHED and the node goes on (on Linux, in a program built with
-s). With nothing to do the node sleeps until a message arrives.

### `AlphNode_turn__ptr`

```mettle
export fn AlphNode_turn__ptr(n: AlphNode*) -> Word
```

Call it as `n->turn()`, or `n.turn()` on a value.

Runs the messages that are waiting and returns how many that was: for a
program with a loop of its own, such as one that draws a frame each time
round. A stop ends the turn early and is left for the next run.

## alph/cores/cores

Many nodes, one on each core: a thread each in a Linux process, a hart
each on a chip with several. A core is a place: an actor
sends to a pid on another core the same way it sends next door, and the
message is put straight into that core's node.

Like the node, this owns no memory: the caller hands it the cores, the
actor slots and the mailboxes, which it shares out evenly.

### `AlphCore`

```mettle
export struct AlphCore {
  node: AlphNode;
  thread: int64;
  self: int32;  // the thread running this core, 0 when none
}
```

One core: its node and the thread or hart that runs it.

### `AlphCores`

```mettle
export struct AlphCores {
  cores: AlphCore*;
  count: Word;
  first: Word;  // the first core's place: the cores are first, first + 1, ...
  far: fn(AlphCores*, Word, AlphMsg*) -> Word;
  world: rawptr;  // whoever set far
  // Tried first for mail between the cores, only on the thread that runs
  // the sending node (src/cores/lanes). A board has none: ALPH_GATHER is 0
  // there, so the test folds away.
  cross: fn(AlphCores*, AlphNode*, Word, AlphMsg*) -> Word;
  ways: rawptr;  // whoever set cross
}
```

The cores of one machine, a node on each.

### `AlphCores_join__ptr`

```mettle
export fn AlphCores_join__ptr(c: AlphCores*, first: Word, far: fn(AlphCores*, Word, AlphMsg*) -> Word, world: rawptr)
```

Call it as `c->join(first, far, world)`, or `c.join(first, far, world)` on a value.

Makes the cores some of the places of a wider world: theirs start at
first, and far takes the mail for the rest. Call it before the first spawn.

### `AlphCores_init__ptr`

```mettle
export fn AlphCores_init__ptr(c: AlphCores*, cores: AlphCore*, count: Word, actors: AlphActor*, slots: Word,
                              mail: AlphMsg*, room: Word)
```

Call it as `c->init(cores, count, actors, slots, mail, room)`, or `c.init(cores, count, actors, slots, mail, room)` on a value.

actors holds count * slots actors, mail holds count * slots * room messages.

### `AlphCores_spawn_on__ptr`

```mettle
export fn AlphCores_spawn_on__ptr(c: AlphCores*, core: Word, handle: fn(AlphActor*, AlphMsg*) -> Word,
                                  state: rawptr) -> Word
```

Call it as `c->spawn_on(core, handle, state)`, or `c.spawn_on(core, handle, state)` on a value.

Spawns on a chosen core, counted from 0. Returns the pid, or 0 when that
core is full.

### `AlphCores_spawn__ptr`

```mettle
export fn AlphCores_spawn__ptr(c: AlphCores*, handle: fn(AlphActor*, AlphMsg*) -> Word,
                               state: rawptr) -> Word
```

Call it as `c->spawn(handle, state)`, or `c.spawn(handle, state)` on a value.

Spawns on the core with the fewest actors. Returns the pid, or 0 when
every core is full.

### `AlphCores_alive__ptr`

```mettle
export fn AlphCores_alive__ptr(c: AlphCores*, pid: Word) -> bool
```

Call it as `c->alive(pid)`, or `c.alive(pid)` on a value.

Whether a pid names an actor on one of these cores that is alive now.

### `AlphCores_send__ptr`

```mettle
export fn AlphCores_send__ptr(c: AlphCores*, to: Word, tag: Word, arg: Word) -> Word
```

Call it as `c->send(to, tag, arg)`, or `c.send(to, tag, arg)` on a value.

From outside an actor.

### `AlphActor_cores__ptr`

```mettle
export fn AlphActor_cores__ptr(a: AlphActor*) -> AlphCores*
```

Call it as `a->cores()`, or `a.cores()` on a value.

The cores an actor runs among.

### `AlphCores_run__ptr`

```mettle
export fn AlphCores_run__ptr(c: AlphCores*)
```

Call it as `c->run()`, or `c.run()` on a value.

Runs every core until stop: the first on this thread, the rest on their
own. Every run starts new threads, so what belongs to a thread (a GPU a
handler opened) does not last from one run to the next.

### `AlphCores_stop__ptr`

```mettle
export fn AlphCores_stop__ptr(c: AlphCores*)
```

Call it as `c->stop()`, or `c.stop()` on a value.

Stops every core, so run returns. Any actor or thread may call it.

## alph/cores/lanes

Lanes between cores, for src/cores on Linux. Putting into another core's
node takes its gate, so both cores write the same lines. With lanes, a
handler's message for another core goes instead into a ring for that
pair of cores that only the sending core's thread writes and only the
receiving core's thread reads, with no lock, and the receiver moves it
into the mailbox when it runs.

What a sender is told changes: ALPH_OK once the message is in the lane,
ALPH_FULL when the lane is full, never ALPH_GONE. A message for an actor
that is gone when it arrives is dropped, and one for a full mailbox waits
at the head of its lane, with what is behind it, until the actor has
room. Sends from any other thread take the gate as before.

A board has none: an interrupt runs on the hart it stops, so a hart
cannot tell a core's own sends from others.

### `AlphLetter`

```mettle
export struct AlphLetter {
  to: Word;
  msg: AlphMsg;
}
```

A message in a lane, with the pid it is for.

### `AlphLane`

```mettle
export struct AlphLane {
  tail: int32;  // where the sender puts the next message
  head_seen: int32;
  mail: AlphLetter*;
  room: int32;
  sender: int32[11];
  head: int32;  // the next message the receiver takes
  tail_seen: int32;
  receiver: int64[7];
}
```

The sender's half and the receiver's half sit on lines of their own. The
lane from a core to itself carries nothing; its tail is that core's idle:
set while it goes to sleep, when a sender must wake it.

### `AlphCores_lanes__ptr`

```mettle
export fn AlphCores_lanes__ptr(c: AlphCores*, lanes: AlphLane*, mail: AlphLetter*, room: Word)
```

Call it as `c->lanes(lanes, mail, room)`, or `c.lanes(lanes, mail, room)` on a value.

Turns lanes on. lanes holds count * count lanes, mail count * count *
room letters, and a lane holds room - 1. Call it before run.

## alph/time/time

Timers: a message sent later. Time stays out of the core, because a timer
is one more thing that sends messages.

The timers wait in the caller's array. The port's alarm rings when the
soonest is due: the board's timer interrupt on a microcontroller, a
sleeping thread on Linux.

Setting, cancelling and sending a timer each look at every slot. That is
the smallest code and right for tens of timers, not for thousands.

### `AlphTimer`

```mettle
export struct AlphTimer {
  at: Word;   // in the port's ticks
  to: Word;
  tag: Word;
  arg: Word;
  ref: Word;  // 0 while the slot is free
}
```

One timer: the message it will send and when.

### `AlphTime`

```mettle
export struct AlphTime {
  gate: AlphGate;
  alarm: AlphAlarm;
  node: AlphNode*;
  slots: AlphTimer*;
  room: Word;
  refs: Word;
}
```

The timers of one node.

### `AlphTime_init__ptr`

```mettle
export fn AlphTime_init__ptr(t: AlphTime*, node: AlphNode*, timers: AlphTimer*, room: Word)
```

Call it as `t->init(node, timers, room)`, or `t.init(node, timers, room)` on a value.

timers holds room timers. Messages go out through node.

### `AlphTime_after__ptr`

```mettle
export fn AlphTime_after__ptr(t: AlphTime*, ms: Word, to: Word, tag: Word, arg: Word) -> Word
```

Call it as `t->after(ms, to, tag, arg)`, or `t.after(ms, to, tag, arg)` on a value.

Sends tag and arg to an actor ms milliseconds from now: never sooner, and
up to a tick later. The message
carries the ref this returns (above 0) and comes from pid 0. Returns
ALPH_FULL when every timer is in use.

### `AlphTime_cancel__ptr`

```mettle
export fn AlphTime_cancel__ptr(t: AlphTime*, ref: Word) -> Word
```

Call it as `t->cancel(ref)`, or `t.cancel(ref)` on a value.

Takes a timer back. ALPH_GONE when its message was already sent.

### `AlphTime_stop__ptr`

```mettle
export fn AlphTime_stop__ptr(t: AlphTime*)
```

Call it as `t->stop()`, or `t.stop()` on a value.

No timer's message is sent after this returns. Waiting timers are dropped.

## alph/time/wheel

Timers for programs with thousands of them: a timer wheel. It behaves as
AlphTime does, but setting and cancelling a timer take the same time
however many wait.

The wheel is a ring of spokes, one per tick, that goes round every
spoke_count ticks. A timer waits in the spoke of the tick it is due in,
in a list threaded through the timers themselves. When the alarm rings
the wheel steps tick by tick from where it stopped up to now, and in each
spoke sends the timers due by then. A timer due a turn or more later
shares the spoke and stays. Free timers wait on a list of their own.

A timer's ref says which slot it is in, so cancel goes straight to it.

Limits: a turn of the wheel should be longer than most delays, or the
alarm rings once a turn for a far timer and sends nothing. A ring more
than a whole turn late sends what is that overdue with its spoke, so
among those the soonest may not go first.

### `AlphWheelTimer`

```mettle
export struct AlphWheelTimer {
  at: Word;    // in the port's ticks
  to: Word;
  tag: Word;
  arg: Word;
  ref: Word;   // 0 while the slot is free
  next: Word;  // slot indexes; a spoke's list is a ring, so its first's prev is its last
  prev: Word;
}
```

One timer on the wheel: the message it will send, when, and its
neighbours in its spoke.

### `AlphWheel`

```mettle
export struct AlphWheel {
  gate: AlphGate;
  alarm: AlphAlarm;
  node: AlphNode*;
  slots: AlphWheelTimer*;
  room: Word;
  spokes: Word*;
  mask: Word;
  free: Word;
  waiting: Word;
  done: Word;     // the last tick whose spoke was sent
  armed: Word;
  next: Word;     // the tick the alarm is set for, while armed
  serial: Word;
  serials: Word;  // serial stays below this, so a ref never overflows
}
```

A timer wheel: the timers and the spokes they wait in.

### `AlphWheel_init__ptr`

```mettle
export fn AlphWheel_init__ptr(w: AlphWheel*, node: AlphNode*, timers: AlphWheelTimer*, room: Word,
    spokes: Word*, spoke_count: Word)
```

Call it as `w->init(node, timers, room, spokes, spoke_count)`, or `w.init(node, timers, room, spokes, spoke_count)` on a value.

timers holds room timers. spokes holds spoke_count list heads, at least
one; a count that is not a power of two is rounded down to one. Messages
go out through node.

### `AlphWheel_after__ptr`

```mettle
export fn AlphWheel_after__ptr(w: AlphWheel*, ms: Word, to: Word, tag: Word, arg: Word) -> Word
```

Call it as `w->after(ms, to, tag, arg)`, or `w.after(ms, to, tag, arg)` on a value.

Sends tag and arg to an actor ms milliseconds from now: never sooner, and
up to a tick later. The message carries the ref this returns (above 0)
and comes from pid 0. Returns ALPH_FULL when every timer is in use.

### `AlphWheel_cancel__ptr`

```mettle
export fn AlphWheel_cancel__ptr(w: AlphWheel*, ref: Word) -> Word
```

Call it as `w->cancel(ref)`, or `w.cancel(ref)` on a value.

Takes a timer back. ALPH_GONE when its message was already sent.

### `AlphWheel_stop__ptr`

```mettle
export fn AlphWheel_stop__ptr(w: AlphWheel*)
```

Call it as `w->stop()`, or `w.stop()` on a value.

No timer's message is sent after this returns. Waiting timers are dropped.

## alph/place/place

Places: a job goes where it will finish first.

A job is a piece of work of some kind and size. A kind can be run in more
than one way: on a CPU core or on a GPU. A place is an actor that runs jobs
one way, so a GPU is one place and every core that takes work is another.

For each way, kind and size, alph keeps how long a job takes. A new job
goes to the place where the work already waiting plus this job's own time
is least. A way not yet tried is tried. A way that lost is tried again
once the time spent since is 16 times what a run of it costs, so a wrong
number costs little and is found.

Work travels, data stays. A job says where its data is: its home. Running
it the other way means the data must cross first, so alph keeps separate
times for a job run where its data is and one run away from it, and a job
tends to stay with its data. Data on the GPU that a core needs is brought
by the GPU's own place, the only thread that may touch the GPU.

A third way is another machine. A job that is one word in and one word
out, or that carries a few bytes, can be sent to an actor there that does
the kind's work and answers. Each other machine is one more place, with
its own work waiting, so work goes to another machine when that is where
it will finish first, and to the one of several that is least busy.

The program writes the two ways. alph only times them, so nothing here
knows what a GPU is. Linux, like the cores.

The ways a job can be run, and where its data can be.

```mettle
export const ALPH_CPU: Word = 0;
export const ALPH_GPU: Word = 1;
export const ALPH_FAR: Word = 2;       // on another machine
export const ALPH_NOWHERE: Word = -1;  // a job's home when it has no data yet
export const ALPH_RUN: Word = -1;    // to a place: run the job in arg
export const ALPH_DONE: Word = -2;   // from a place: the job in arg is done
```

```mettle
export const ALPH_BACK_BYTES: Word = 1016;  // the most bytes a job on another machine gives back
```

### `AlphJob`

```mettle
export struct AlphJob {
  kind: Word;
  size: Word;    // how much work, in the program's own unit
  data: rawptr;
  in: Word;      // what a job that can go to another machine is given,
  out: Word;     // and what it gives back
  bytes: uint8*; // bytes that go with it to another machine, up to ALPH_PARCEL_BYTES,
  count: Word;   // and how many: 0 for none
  back: uint8*;  // where bytes the job gives back are put, 0 for none,
  back_room: Word;   // how many fit there (from another machine at most ALPH_BACK_BYTES),
  back_count: Word;  // and how many came
  stay: Word;    // not 0: it must be done on this machine
  home: Word;    // where its data is: ALPH_CPU, ALPH_GPU or ALPH_NOWHERE. alph sets it to where the job ran
  status: Word;  // ALPH_OK, ALPH_GONE when no place can run it, ALPH_FULL to ask again
  way: Word;     // how it was run
  ns: Word;      // how long that took, bringing its data included
  asker: Word;
  ref: Word;
  owed: Word;
  at: Word;      // which of the kind's times this run is
  was_home: Word;  // its home when its place was picked
  moved: Word;   // ns spent bringing its data
  far_ref: Word; // the ref its request to another machine carries,
  far_to: Word;  // the worker it went to,
  far_seen: Word; // how many answers its place had had by then,
  far_resent: Word; // a job done at most once: it was sent a second time,
  far_asked: Word;  // and when it was last sent,
  began: Word;   // and when
  to: AlphPlace*;
  next: AlphJob*;
}
```

A job: what it is, what it is given, and, once done, what came of it. The
program fills in the first fields and alph the rest.

### `AlphKind`

```mettle
export struct AlphKind {
  cpu: fn(AlphJob*) -> Word;
  gpu: fn(AlphJob*) -> Word;
  bring: fn(AlphJob*) -> Word;
  once: Word;      // a job of this kind is never done twice
  far: Word;       // an actor on another machine that does this kind's work, 0 when no machine does
  off: Word[3];    // this way cannot run the kind
  warm: Word[3];   // its first run is over: that one pays for starting up
  // Times are kept by way, by whether the data was at home there or had to
  // cross, and by size.
  est: Word[192];   // ns a job takes on average, 0 when not known
  low: Word[192];   // ns it takes when nothing gets in its way
  last: Word[192];  // the time before, 0 when there was none
  since: Word[192]; // ns of work done other ways since this one was timed
}
```

A kind of job: how it is run each way, and how long that has taken.

### `AlphTimes`

```mettle
export struct AlphTimes {
  est: Word[32];
  low: Word[32];
  last: Word[32];
  since: Word[32];
  warm: Word;
}
```

A far place's own times for one kind of work, by size. Without them
every far place goes by the kind's one time for work sent away.

### `AlphPlace`

```mettle
export struct AlphPlace {
  places: AlphPlaces*;
  pid: Word;
  way: Word;
  waiting: Word;      // jobs sent here and not yet done
  backlog: Word;      // the ns they are expected to take
  ran: Word;
  unsent: AlphJob*;   // done, but the asker's mailbox was full
  nudged: Word;       // a nudge is on its way
  open: AlphJob*;     // sent to another machine and not yet answered
  far_refs: Word;
  workers: Word[16];  // a far place: by kind, the actor on its machine that does it, 0 for none
  looking: Word;      // a timer to look at the open jobs is set
  limit: Word;        // no more jobs than this are here at once, 0 for any number
  wide: Word;         // how many jobs it does at once, 0 when not known
  answers: Word;      // a far place: answers that have come back,
  answered: Word;     // and when the last one did
  gave_ref: Word[4];  // the last jobs given up on: the ref each went out with,
  gave_began: Word[4];  // when,
  gave_at: Word[4];   // and its kind times 192 plus which of the kind's times it is
  gave_next: Word;
  once_known: Word[16];  // by kind, for jobs done at most once: 0 the worker must be said hello to, 1 hello sent, 2 it answered
  once_ref: Word[16];    // the last ref given out in this run of refs
  once_hello: Word[16];  // the ref of the hello sent
  once_at: Word[16];     // when it was sent
  once_run: Word[16];    // the run it started
  pace: Word[16];     // a far place, by kind: ns from one answer to the next while it has work, 0 when not known
  busy: Word;         // it still had work when its last answer came,
  paced: Word;        // and when that was
  own: AlphTimes*;    // a far place's own times, one for each of its first own_kinds kinds, 0 for none
  own_kinds: Word;
  too_big: Word;      // a far place: a job with this many bytes or more does not fit its machine, 0 when none was refused
}
```

A place: an actor that runs jobs one way, and the work waiting at it.

### `AlphPlaces`

```mettle
export struct AlphPlaces {
  gate: AlphGate;
  places: AlphPlace*;
  room: Word;
  count: Word;
  kinds: AlphKind*;
  kind_count: Word;
  time: AlphTime*;  // for far jobs that are never answered, 0 for none
  link: AlphLink*;  // for far jobs that carry bytes, 0 for none
  late: Word;       // far jobs given up on and placed again
}
```

The places of one machine and the kinds of job they run.

### `AlphPlaces_init__ptr`

```mettle
export fn AlphPlaces_init__ptr(p: AlphPlaces*, places: AlphPlace*, room: Word, kinds: AlphKind*, count: Word)
```

Call it as `p->init(places, room, kinds, count)`, or `p.init(places, room, kinds, count)` on a value.

places holds room places, kinds holds count kinds.

### `AlphPlaces_kind__ptr`

```mettle
export fn AlphPlaces_kind__ptr(p: AlphPlaces*, kind: Word, cpu: fn(AlphJob*) -> Word,
                               gpu: fn(AlphJob*) -> Word)
```

Call it as `p->kind(kind, cpu, gpu)`, or `p.kind(kind, cpu, gpu)` on a value.

Says how a kind is run each way. A way the kind does not have is 0. Each
returns 0, or non-zero when it cannot run here (no GPU, say): the job then
goes another way and that way is not tried again.

### `AlphPlaces_once__ptr`

```mettle
export fn AlphPlaces_once__ptr(p: AlphPlaces*, kind: Word)
```

Call it as `p->once(kind)`, or `p.once(kind)` on a value.

Says that a job of this kind is never done twice, whatever is lost on
the way: for work that changes something, such as moving an arm. On
this machine a job runs once anyway. Sent to another machine it goes as
ALPH_WORK_ONCE, to a worker that remembers what it has done (a board or
a machine does, see alph/place/once). A job not answered is sent again
to the same worker and never placed anywhere else. If the worker or its
machine is lost, or was restarted, the job comes back with the status
ALPH_LOST: it may or may not have been done, and the program decides.
Such a job carries a word, not bytes, and gives a word back. Call it
after kind.

### `AlphPlaces_bring__ptr`

```mettle
export fn AlphPlaces_bring__ptr(p: AlphPlaces*, kind: Word, bring: fn(AlphJob*) -> Word)
```

Call it as `p->bring(kind, bring)`, or `p.bring(kind, bring)` on a value.

Says how a kind's data on the GPU is brought to the host. It runs on the
GPU's place and returns 0, or non-zero when it could not, after which it
is not tried again. Without it, a job whose data is on the GPU runs only
there. Call it after kind.

### `AlphPlaces_far_at__ptr`

```mettle
export fn AlphPlaces_far_at__ptr(p: AlphPlaces*, place: Word, kind: Word, worker: Word) -> Word
```

Call it as `p->far_at(place, kind, worker)`, or `p.far_at(place, kind, worker)` on a value.

Says which actor on another machine does a kind's work, for one far
place: the place with pid `place` is that machine. The actor is sent
ALPH_WORK with the job's in as arg, and answers ALPH_WORKED with the
job's out and the same ref, or ALPH_REFUSED with arg ALPH_FULL when it
cannot take the job now and ALPH_GONE when it never can. A worker of 0
takes the kind away from that machine. Call it after kind, with a kind
below 16. For the machine's loss to be noticed, have the far place watch
the worker: it treats ALPH_ENDED from a worker as the end of its work
there. Returns ALPH_GONE when there is no such far place or kind.

### `AlphPlaces_limit__ptr`

```mettle
export fn AlphPlaces_limit__ptr(p: AlphPlaces*, place: Word, jobs: Word) -> Word
```

Call it as `p->limit(place, jobs)`, or `p.limit(place, jobs)` on a value.

Lets a place have no more than `jobs` jobs at once, 0 for any number. It
is for a small machine, such as a board, whose mailbox must not be
overrun and which does its jobs one after another. So a far place with a
limit is sent no job with bytes, and a job out to it is taken for lost
only when the place has gone quiet or has answered twice its limit of
later jobs. A job that finds every place that could run it at its limit
is answered ALPH_FULL. Returns ALPH_GONE when there is no such place.

### `AlphPlaces_wide__ptr`

```mettle
export fn AlphPlaces_wide__ptr(p: AlphPlaces*, place: Word, jobs: Word) -> Word
```

Call it as `p->wide(place, jobs)`, or `p.wide(place, jobs)` on a value.

Says how many jobs a place does at once: 1 for a core or a GPU, which is
what a place starts with, and for another machine the cores it works on.
A far place is then costed as that many workers before any answer has
shown its pace, and an offered job (offer) is not left waiting behind
more than one other at each worker. 0 is for not known. Returns
ALPH_GONE when there is no such place.

### `AlphPlaces_own__ptr`

```mettle
export fn AlphPlaces_own__ptr(p: AlphPlaces*, place: Word, times: AlphTimes*, kinds: Word) -> Word
```

Call it as `p->own(place, times, kinds)`, or `p.own(place, times, kinds)` on a value.

Gives a far place times of its own: `times` is an array with one entry
for each of the first `kinds` kinds. The place then learns how long that
machine takes, apart from every other, so a slow machine and a quick one
that do the same kind are told apart. Returns ALPH_GONE when there is no
such far place.

### `AlphPlaces_look__ptr`

```mettle
export fn AlphPlaces_look__ptr(p: AlphPlaces*, a: AlphActor*, place: Word) -> Word
```

Call it as `p->look(a, place)`, or `p.look(a, place)` on a value.

Has a far place look now for jobs out too long. The place looks by
itself on the places' clock; this is for a program that wants to be sure
of it when timers may have run out.

### `AlphPlaces_far__ptr`

```mettle
export fn AlphPlaces_far__ptr(p: AlphPlaces*, kind: Word, worker: Word)
```

Call it as `p->far(kind, worker)`, or `p.far(kind, worker)` on a value.

The same for a program with one far place: its first.

### `AlphPlaces_clock__ptr`

```mettle
export fn AlphPlaces_clock__ptr(p: AlphPlaces*, time: AlphTime*)
```

Call it as `p->clock(time)`, or `p.clock(time)` on a value.

Gives the places a clock. With it, a job sent to another machine that is
not answered in eight times its usual time (and at least a second) is
given up on and placed again, so a request or an answer that was lost
costs a wait, not the job. Without it such a job waits for ever.

### `AlphPlaces_net__ptr`

```mettle
export fn AlphPlaces_net__ptr(p: AlphPlaces*, link: AlphLink*)
```

Call it as `p->net(link)`, or `p.net(link)` on a value.

Gives the places the link, so a job for another machine can carry bytes
(job->bytes and job->count). Its worker then gets ALPH_WORK_BYTES with a
parcel in arg, which it gives back to its own link when it has read it,
and the job's in is not sent. Give the link its parcels first.

### `AlphPlaces_add__ptr`

```mettle
export fn AlphPlaces_add__ptr(p: AlphPlaces*, way: Word) -> AlphPlace*
```

Call it as `p->add(way)`, or `p.add(way)` on a value.

A new place that runs jobs one way. Spawn alph_place_run with it as the
state, then put the pid in it. Returns 0 when there is no room.

### `AlphPlaces_on_core__ptr`

```mettle
export fn AlphPlaces_on_core__ptr(p: AlphPlaces*, cores: AlphCores*, core: Word, way: Word) -> Word
```

Call it as `p->on_core(cores, core, way)`, or `p.on_core(cores, core, way)` on a value.

A new place on one core. A GPU's place wants a core to itself: a GPU
belongs to the one thread that opened it. Returns its pid, or 0 when the
core or the places are full. Set places up one at a time.

### `AlphPlaces_ask__ptr`

```mettle
export fn AlphPlaces_ask__ptr(p: AlphPlaces*, a: AlphActor*, job: AlphJob*) -> Word
```

Call it as `p->ask(a, job)`, or `p.ask(a, job)` on a value.

Sends a job to the place where it should finish first. The answer is an
ALPH_DONE message with the job in arg and the ref this returns. From here
until that answer the job is alph's: leave it where it is and do not read
or write it. Set its kind, size and home first. Returns ALPH_FULL when that place's
mailbox is full, ALPH_GONE when no place can run the kind or there is no
such kind.

### `AlphPlaces_offer__ptr`

```mettle
export fn AlphPlaces_offer__ptr(p: AlphPlaces*, a: AlphActor*, job: AlphJob*) -> Word
```

Call it as `p->offer(a, job)`, or `p.offer(a, job)` on a value.

Like ask, for a program with more jobs than places, which a batch is: a
job that would only wait behind others at every place that could run it
is not sent, and the answer is ALPH_FULL. Offer it again when an answer
to another job is back. So jobs are placed late, when it is known which
place is free, and none sits in a slow place's queue.

### `alph_place_run`

```mettle
export fn alph_place_run(a: AlphActor*, m: AlphMsg*) -> Word
```

The handler of every place.

## alph/place/words

What a machine that hands out work and a worker on another machine say
to each other. They are apart from the places so that a board, which is
too small for the places, can still be a worker.

```mettle
export const ALPH_WORK: Word = -13;        // to a worker on another machine: arg is the job's in
export const ALPH_WORKED: Word = -14;      // its answer: arg is the job's out, with the same ref
export const ALPH_WORK_BYTES: Word = -17;  // as ALPH_WORK, for a job with bytes: arg is a parcel
export const ALPH_WORKED_BYTES: Word = -20; // as ALPH_WORKED, for a job that gives bytes back: arg is a parcel, its first 8 bytes the job's out
export const ALPH_REFUSED: Word = -18;     // a worker's answer when it cannot take the job: arg is ALPH_FULL for now, ALPH_GONE for never
export const ALPH_WORK_ONCE: Word = -21;   // as ALPH_WORK, for a job that must not be done twice (see alph/place/once)
export const ALPH_HELLO: Word = -22;       // to a worker before the first ALPH_WORK_ONCE: a new run of refs starts at ref. It answers the same back
export const ALPH_WORK_LONG: Word = -23;   // as ALPH_WORK_BYTES, for more bytes than a parcel holds: arg is a long buffer, or 0 when they did not fit there
export const ALPH_WORKED_LONG: Word = -24; // as ALPH_WORKED_BYTES, the same way
export const ALPH_SHARED: Word = 1073741824;  // the name of the worker for a shared kind is this plus the kind
```

## alph/place/once

What a worker remembers so that a job is never done twice. An asker
that wants that sends its jobs as ALPH_WORK_ONCE and says ALPH_HELLO
first. The worker keeps, for each of eight askers, the last four jobs it
did for it and what each gave. A job sent again is answered from that
memory and not done again.

A ref is a run of jobs and a number in it: the run in the high bits, the
number in the low twelve. A hello starts a new run and wipes what was
remembered of that asker. A job of any other run is a stranger's: the
worker says it does not know it, and the asker then counts the job as
lost (done or not, it cannot tell) and says hello again. A ref at or
under the floor is an old copy and is dropped.

Checked by exploring every order of loss, delay, restart and reboot for
small sizes. It holds as long as the way between the two delivers no
message twice, which the link and the tether do not.

```mettle
export const ALPH_ONCE_RUN: Word = 0;       // new: do it, then call done or undo
export const ALPH_ONCE_DONE: Word = 1;      // done before: answer again with what it gave
export const ALPH_ONCE_BUSY: Word = 2;      // being done now: say nothing, the answer is coming
export const ALPH_ONCE_OLD: Word = 3;       // an old copy: say nothing
export const ALPH_ONCE_STRANGER: Word = 4;  // not of this asker's run: refuse with ALPH_LOST
```

### `AlphOnce`

```mettle
export struct AlphOnce {
  asker: Word[8];   // who, 0 for a free row
  floor: Word[8];   // refs at or under it are old
  last: Word[8];    // when the row was last used: the least is given up for a ninth asker
  ref: Word[32];    // four for each asker, 0 for none
  out: Word[32];
  busy: Word[32];
  clock: Word;
}
```

What one worker remembers: eight askers, and four jobs for each.

### `AlphOnce_init__ptr`

```mettle
export fn AlphOnce_init__ptr(o: AlphOnce*)
```

Call it as `o->init()`, or `o.init()` on a value.

Forgets everything: no asker is known.

### `AlphOnce_hello__ptr`

```mettle
export fn AlphOnce_hello__ptr(o: AlphOnce*, from: Word, h: Word) -> bool
```

Call it as `o->hello(from, h)`, or `o.hello(from, h)` on a value.

An asker's hello: a new run of refs starts at h, and what was remembered
of that asker is forgotten. With eight askers known already, the one
heard from longest ago is given up, unless a job of its is being done
right now. Returns false when no row can be had: the hello is then not
answered, and the asker says it again.

### `AlphOnce_seen__ptr`

```mettle
export fn AlphOnce_seen__ptr(o: AlphOnce*, from: Word, ref: Word, out: Word*) -> Word
```

Call it as `o->seen(from, ref, out)`, or `o.seen(from, ref, out)` on a value.

What to do with a job: one of the ALPH_ONCE values. For ALPH_ONCE_DONE
*out is what the job gave when it was done.

### `AlphOnce_begin__ptr`

```mettle
export fn AlphOnce_begin__ptr(o: AlphOnce*, from: Word, ref: Word)
```

Call it as `o->begin(from, ref)`, or `o.begin(from, ref)` on a value.

Remembers a job as being done. If that makes five for its asker, the
oldest is forgotten and the floor moves up to it. Call it only after
seen said ALPH_ONCE_RUN.

### `AlphOnce_done__ptr`

```mettle
export fn AlphOnce_done__ptr(o: AlphOnce*, from: Word, ref: Word, out: Word)
```

Call it as `o->done(from, ref, out)`, or `o.done(from, ref, out)` on a value.

The job is done and gave out.

### `AlphOnce_undo__ptr`

```mettle
export fn AlphOnce_undo__ptr(o: AlphOnce*, from: Word, ref: Word)
```

Call it as `o->undo(from, ref)`, or `o.undo(from, ref)` on a value.

The job was not done after all (no room for it): it is forgotten, so a
copy sent again may be done.

## alph/life/life

Lives: what happens when an actor ends.

A handler that returns non-zero ends its actor, and what it returned is
the reason: ALPH_END for an actor that is finished, anything else for one
that failed.

Watching: an actor that watches another is sent ALPH_ENDED when it ends,
with the reason. Watching one that is already gone says so at once.

Keeping: a kept actor that fails is not ended. Its state is set up again
and it goes on, with the same pid and the mail it had, so nothing that
knows it has to learn a new pid. After its last allowed restart it ends
like any other.

The memory is the caller's, as everywhere: an array of watches and an
array of keeps.

```mettle
export const ALPH_ENDED: Word = -7;  // to a watcher: from is the actor, arg the reason, ref the watch
```

### `AlphWatch`

```mettle
export struct AlphWatch {
  ref: Word;      // 0 while the slot is free
  watcher: Word;
  target: Word;
  owed: Word;     // the target ended and the watcher's mailbox was full
  reason: Word;
  far: Word;      // made for a watcher on another machine, with its ref
}
```

One watch: who is told when which actor ends.

### `AlphKeep`

```mettle
export struct AlphKeep {
  pid: Word;      // 0 while the slot is free
  reset: fn(rawptr) -> void;
  left: Word;     // restarts still allowed
  restarts: Word;
}
```

One kept actor: how its state is set up again and how many restarts it has left.

### `AlphLife`

```mettle
export struct AlphLife {
  gate: AlphGate;
  cores: AlphCores*;
  watches: AlphWatch*;
  watch_room: Word;
  keeps: AlphKeep*;
  keep_room: Word;
  refs: Word;
}
```

The watches and the kept actors of one set of cores.

### `AlphLife_settle__ptr`

```mettle
export fn AlphLife_settle__ptr(l: AlphLife*)
```

Call it as `l->settle()`, or `l.settle()` on a value.

Tells every watcher that is still owed word because its mailbox was full.
alph calls it whenever something ends or is watched. Nothing calls it
when the mailbox empties, so a program that fills its watchers' mailboxes
calls it now and then.

### `AlphLife_init__ptr`

```mettle
export fn AlphLife_init__ptr(l: AlphLife*, cores: AlphCores*, watches: AlphWatch*, watch_room: Word, keeps: AlphKeep*,
                             keep_room: Word)
```

Call it as `l->init(cores, watches, watch_room, keeps, keep_room)`, or `l.init(cores, watches, watch_room, keeps, keep_room)` on a value.

watches holds watch_room watches, keeps holds keep_room keeps. Call it
after the cores are set up and before they run.

### `AlphLife_watch__ptr`

```mettle
export fn AlphLife_watch__ptr(l: AlphLife*, watcher: Word, target: Word) -> Word
```

Call it as `l->watch(watcher, target)`, or `l.watch(watcher, target)` on a value.

Has watcher sent ALPH_ENDED when target ends. Returns the watch's ref
(above 0), ALPH_GONE when the target is already gone, ALPH_FULL when
every watch is in use. A target on another machine cannot be checked: it
is watched, and ends for its watchers when its machine is lost.

### `AlphLife_watch_as__ptr`

```mettle
export fn AlphLife_watch_as__ptr(l: AlphLife*, watcher: Word, target: Word, ref: Word) -> Word
```

Call it as `l->watch_as(watcher, target, ref)`, or `l.watch_as(watcher, target, ref)` on a value.

A watch made for a watcher on another machine, under the ref that
machine chose: its door asks for it. Returns ALPH_OK, ALPH_GONE when the
target is already gone, ALPH_FULL when every watch is in use.

### `AlphLife_ended_far__ptr`

```mettle
export fn AlphLife_ended_far__ptr(l: AlphLife*, target: Word, ref: Word, reason: Word)
```

Call it as `l->ended_far(target, ref, reason)`, or `l.ended_far(target, ref, reason)` on a value.

An actor watched on another machine ended there: its door says so.

### `AlphLife_unwatch__ptr`

```mettle
export fn AlphLife_unwatch__ptr(l: AlphLife*, ref: Word) -> Word
```

Call it as `l->unwatch(ref)`, or `l.unwatch(ref)` on a value.

Stops watching. ALPH_GONE when the watch is over or its message is on
the way.

### `AlphLife_keep__ptr`

```mettle
export fn AlphLife_keep__ptr(l: AlphLife*, pid: Word, reset: fn(rawptr) -> void, times: Word) -> Word
```

Call it as `l->keep(pid, reset, times)`, or `l.keep(pid, reset, times)` on a value.

Keeps an actor: when its handler fails, reset is called on its state and
it goes on, up to times times. Keeping it again sets times anew. Returns
ALPH_FULL when every keep is in use, ALPH_GONE when the actor is not on
these cores or not alive.

### `AlphLife_lost__ptr`

```mettle
export fn AlphLife_lost__ptr(l: AlphLife*, first: Word, count: Word)
```

Call it as `l->lost(first, count)`, or `l.lost(first, count)` on a value.

A machine was lost: every actor watched on its places has ended, with the
reason ALPH_LOST, and the watches kept here for its watchers are over. first and count are the machine's places, as a link's
ALPH_DOWN gives them.

## alph/name/name

Names: a number a program chooses, for a pid it wants found. The names
wait in the caller's array.

### `AlphName`

```mettle
export struct AlphName {
  name: Word;
  pid: Word;  // 0 while the slot is free
}
```

One name and the pid behind it.

### `AlphNames`

```mettle
export struct AlphNames {
  gate: AlphGate;
  slots: AlphName*;
  room: Word;
}
```

The names of one machine.

### `AlphNames_init__ptr`

```mettle
export fn AlphNames_init__ptr(n: AlphNames*, slots: AlphName*, room: Word)
```

Call it as `n->init(slots, room)`, or `n.init(slots, room)` on a value.

slots holds room names.

### `AlphNames_set__ptr`

```mettle
export fn AlphNames_set__ptr(n: AlphNames*, name: Word, pid: Word) -> Word
```

Call it as `n->set(name, pid)`, or `n.set(name, pid)` on a value.

Gives a pid a name, or gives the name to another pid. Returns ALPH_FULL
when every name is in use.

### `AlphNames_get__ptr`

```mettle
export fn AlphNames_get__ptr(n: AlphNames*, name: Word) -> Word
```

Call it as `n->get(name)`, or `n.get(name)` on a value.

The pid with this name, or 0.

### `AlphNames_forget__ptr`

```mettle
export fn AlphNames_forget__ptr(n: AlphNames*, name: Word)
```

Call it as `n->forget(name)`, or `n.forget(name)` on a value.

Takes a name away. A name is not taken away when its actor ends: sends to
it are then refused as for any actor that is gone.

## alph/door/door

The door: the first actor of a machine, at a pid any other machine can
work out. Through it an actor finds another machine's actors by name and
watches them, with nothing but messages.

Finding: find asks a machine's door for the pid behind a name, and the
answer is an ALPH_HERE message.

Watching: watch works for an actor anywhere. For one on another machine
the door there keeps the watch and tells this door when the actor ends,
and if that machine is lost first, the actor has ended with ALPH_LOST.

### `AlphDoor`

```mettle
export struct AlphDoor {
  cores: AlphCores*;
  link: AlphLink*;
  names: AlphNames*;
  life: AlphLife*;
  pid: Word;
  tell: Word;  // the actor that hears of machines coming and going, 0 for none
}
```

A machine's door and the layers it answers from.

### `AlphDoor_init__ptr`

```mettle
export fn AlphDoor_init__ptr(d: AlphDoor*, cores: AlphCores*, link: AlphLink*, names: AlphNames*, life: AlphLife*) -> Word
```

Call it as `d->init(cores, link, names, life)`, or `d.init(cores, link, names, life)` on a value.

Opens this machine's door. It must be the first actor spawned on the
cores, after the link, the names and the lives are set up and before the
link starts. Returns its pid, or ALPH_GONE when it was not the first.

### `AlphDoor_tell__ptr`

```mettle
export fn AlphDoor_tell__ptr(d: AlphDoor*, pid: Word)
```

Call it as `d->tell(pid)`, or `d.tell(pid)` on a value.

The actor sent ALPH_UP and ALPH_DOWN as machines come and go.

### `AlphDoor_find__ptr`

```mettle
export fn AlphDoor_find__ptr(d: AlphDoor*, a: AlphActor*, place: Word, name: Word) -> Word
```

Call it as `d->find(a, place, name)`, or `d.find(a, place, name)` on a value.

Asks the machine that has a place for the pid behind a name. The answer
is ALPH_HERE with the ref this returns: arg is the pid, 0 when that
machine has no such name. Returns ALPH_GONE when no machine has the
place or it cannot be reached.

### `AlphDoor_watch__ptr`

```mettle
export fn AlphDoor_watch__ptr(d: AlphDoor*, watcher: Word, target: Word) -> Word
```

Call it as `d->watch(watcher, target)`, or `d.watch(watcher, target)` on a value.

Has watcher sent ALPH_ENDED when target ends, wherever target is.
Returns the watch's ref, ALPH_FULL when every watch is in use or the way
to the target's machine is full for now, ALPH_GONE when the target is
gone or its machine cannot be reached. A target on
another machine that was already gone there is told as an end, with the
reason ALPH_GONE, and one that machine has no watch left for with the
reason ALPH_FULL.

## alph/door/words

What is said to a door and what it says back. They are apart from the
door so that a board, which is too small for a door, can still answer.

```mettle
export const ALPH_WHERE: Word = -10;  // to a door: arg is a name
export const ALPH_HERE: Word = -11;   // from a door: arg is the pid with that name, or 0. It comes as from that actor
```

### `alph_door_of`

```mettle
export fn alph_door_of(first: Word) -> Word
```

The pid of the door on the machine whose places start at first.

## alph/link/link

Links: other machines as places. Each machine owns a run of place
numbers, so a pid says which machine its actor is on, and an actor sends
to it the way it sends next door.

A message crosses in one datagram. Messages to a machine are numbered,
the machine says how far it has them, and what it has not got in a
twenty-fifth of a second is sent again: so between two machines messages
arrive once and in the order they were sent, for as long as both are up.
A message for an actor whose mailbox is full is not taken: it is sent
again, and what is behind it waits, so a full mailbox slows a sender down
and loses nothing. An actor that has had no room for half a second is
not reading: its message is then dropped, so it cannot hold up the rest.
Every machine tells its peers it is alive 20 times a second.
One that stays quiet for half a second is down: sends to it return
ALPH_GONE and the watcher is told. If it was only out of reach, what was
on its way is sent again when it is back. A machine that was restarted is
a new one, with a new life: what was on its way to the old one is lost,
and mail meant for the old one is not handed to the new.

A message can carry bytes: up to 1,024 of them, in a parcel. They cross
with the same numbering as every other message, so they too arrive once
and in order. The parcels are the caller's memory: a pool the link is
given. A parcel that arrives belongs to the actor it was sent to, which
gives it back with release when it has read it.

More bytes than that go as a long message, if the link is given long
buffers (longs): it is cut into pieces of 1,024 bytes that cross like
any other message, and put together again at the other end in a long
buffer of that machine. The actor gets the whole at once, and gives the
buffer back with free. A long message takes its place among the others
when its last piece goes, so a short message sent after it can arrive
before it. One on its way to or from a machine that goes down is given
up, and its buffers are free again at once.

A message that arrives too early shows that the one before it was lost.
The sender is told at once and sends again from there, so a loss costs
one round trip and not the wait of a clock.

A link is in the clear unless it is sealed: see src/seal.

```mettle
export const ALPH_UP: Word = -4;    // to the watcher: arg is the first place of a machine now reachable
export const ALPH_DOWN: Word = -5;  // to the watcher: arg is the first place of a machine now lost
```

The most bytes one message can carry.

```mettle
export const ALPH_PARCEL_BYTES: Word = 1024;
export const ALPH_DATAGRAM: int64 = 1104;  // the most a datagram holds before it is sealed
export const ALPH_BIG: Word = -25;  // more bytes than a long buffer holds
```

### `AlphParcel`

```mettle
export struct AlphParcel {
  count: Word;  // how many of the bytes are in use
  used: Word;   // taken from the pool
  bytes: uint8[1024];
}
```

Bytes that travel with a message.

### `AlphLong`

```mettle
export struct AlphLong {
  count: Word;   // how many of the bytes are in use
  room: Word;    // how many fit
  used: Word;    // taken from the pool
  bytes: uint8*;
  to: Word;
  from: Word;
  tag: Word;
  ref: Word;
  at: Word;      // how many bytes have gone
  next: AlphLong*;
}
```

The bytes of a long message, and while it is on its way out, the message.

### `AlphPeer`

```mettle
export struct AlphPeer {
  first: Word;   // its places are first, first + 1, ...
  count: Word;
  more_first: Word;  // places reached through it, such as a board on its serial line
  more_count: Word;
  ip: uint32;
  port: int64;
  life: uint32;  // which run of that machine this is, 0 before it is heard
  alive: Word;
  told: Word;    // the watcher was told it is up,
  told_life: uint32;  // and this was its life then
  seen: Word;
  gate: AlphGate;     // what follows is shared by senders and the link's thread
  sent: uint32;       // the number of the last message sent to it
  acked: uint32;      // it has every message up to this one
  heard: Word;        // on a sealed link: the count of the last datagram taken from it,
  newest: Word;       // and when the latest run of it ever heard began, so nothing recorded can be played again
  got: uint32;        // every message from it up to this one was taken
  owed: Word;         // messages taken since it was last told so
  waiting_since: Word;
  wired: uint32;      // the last message put on the wire: later ones are held back for a moment
  missed: uint32;     // the message last said to be missing: said once, then left to the sender's clock
  hurry: Word;        // when, in ns, to send again what found a mailbox full, 0 for not waiting
  hurry_wait: Word;   // how long that wait is now
  stuck: uint32;      // the message being refused because its actor has no room,
  stuck_at: Word;     // and since when
  again_ms: Word;     // how long its word is waited for before sending again
  window: AlphPacket[64];  // the messages it has not yet said it has
  held: AlphParcel*[64];   // and the bytes of those that carry any
  part: uint8*[64];        // or, for a piece of a long message, where its bytes are,
  ends: AlphLong*[64];     // and for the mail that ends one, the long to give back
  longs: AlphLong*;        // long messages waiting to go, the next first
  longs_last: AlphLong*;
  filling: AlphLong*;      // a long message arriving
  skipping: Word;          // one is arriving that cannot be taken: its bytes are dropped
}
```

Another machine: its places, its address, and how far the messages to
it and from it have got.

### `AlphLink`

```mettle
export struct AlphLink {
  wire: AlphWire;
  cores: AlphCores*;
  peers: AlphPeer*;
  room: Word;
  count: Word;
  life: uint32;   // this run: the low half of born, never 0
  born: Word;     // when this run began, in milliseconds
  watcher: Word;
  thread: int64;
  stopping: int32;
  port: int64;    // the port the wire is open on, 0 when it is not
  resent: Word;   // messages sent again
  lose: Word;     // for tests: one in so many messages is not sent the first time
  lost: Word;
  deaf: Word;     // for tests: hears nothing while this is set
  // A sealed link: seal turns a datagram into one only the holders of the
  // key can read or make, open turns it back and says who sent it and which
  // datagram of theirs it is. Set by src/seal. 0 for a link in the clear.
  seal: fn(rawptr, uint8*, uint8*, int64) -> int64;
  open: fn(rawptr, uint8*, uint8*, int64, uint32*, Word*, Word*) -> int64;
  sealer: rawptr;
  refused: Word;  // datagrams not sealed with the key, or already heard
  full: Word;     // messages left to be sent again because their actor had no room,
  shed: Word;     // and messages dropped because it had none for half a second
  // Mail for a place that is neither on these cores nor a peer's goes to
  // beyond, if it is set: a board on this machine's serial line, say.
  beyond: fn(AlphLink*, Word, AlphMsg*) -> Word;
  beyond_ctx: rawptr;
  parcels: AlphParcel*;
  parcel_room: Word;
  parcel_gate: AlphGate;
  longs: AlphLong*;
  long_room: Word;
  skipped: Word;  // long messages that arrived with no long buffer big enough here
  unsent: int32;  // not 0: short messages are held back, to go several to a datagram
  unsent_at: Word;  // since this many ns
  shared: Word;   // messages that went in a datagram with others
}
```

This machine's link to the others.

### `AlphLink_release__ptr`

```mettle
export fn AlphLink_release__ptr(l: AlphLink*, parcel: AlphParcel*)
```

Call it as `l->release(parcel)`, or `l.release(parcel)` on a value.

Gives a parcel back to the pool. The actor a parcel was sent to calls
this when it has read it, on the link of its own machine. A machine whose
actors keep every parcel can take no more bytes, and since messages
arrive in order, nothing else from that sender either until one is given
back.

### `AlphLink_free__ptr`

```mettle
export fn AlphLink_free__ptr(l: AlphLink*, buffer: AlphLong*)
```

Call it as `l->free(buffer)`, or `l.free(buffer)` on a value.

Gives a long buffer back to the pool. The actor a long message was sent
to calls it when it has read the bytes, and so does a program that took
a buffer (long) and did not send it.

### `AlphLink_flush__ptr`

```mettle
export fn AlphLink_flush__ptr(l: AlphLink*)
```

Call it as `l->flush()`, or `l.flush()` on a value.

Sends what is held back for every peer. A node calls it when it next
looks for mail, and the link's own thread within a few milliseconds if
no node did. A handler that runs long and wants what it sent to leave
before it returns calls it itself.

### `AlphLink_init__ptr`

```mettle
export fn AlphLink_init__ptr(l: AlphLink*, cores: AlphCores*, first: Word, peers: AlphPeer*, room: Word)
```

Call it as `l->init(cores, first, peers, room)`, or `l.init(cores, first, peers, room)` on a value.

Makes the cores one machine among several. Its places start at first.
peers holds room peers. Call it before the first spawn.

### `AlphLink_peer__ptr`

```mettle
export fn AlphLink_peer__ptr(l: AlphLink*, first: Word, count: Word, ip: uint32, port: int64) -> Word
```

Call it as `l->peer(first, count, ip, port)`, or `l.peer(first, count, ip, port)` on a value.

Another machine: where its places start, how many it has, and where it
listens. Returns ALPH_FULL when there is no room for it.

### `AlphLink_parcels__ptr`

```mettle
export fn AlphLink_parcels__ptr(l: AlphLink*, parcels: AlphParcel*, room: Word)
```

Call it as `l->parcels(parcels, room)`, or `l.parcels(parcels, room)` on a value.

Gives the link its parcels: room of them. Without any, no message can
carry bytes. Call it before start.

### `AlphLink_send_bytes__ptr`

```mettle
export fn AlphLink_send_bytes__ptr(l: AlphLink*, from: Word, to: Word, tag: Word, ref: Word, bytes: uint8*, count: Word) -> Word
```

Call it as `l->send_bytes(from, to, tag, ref, bytes, count)`, or `l.send_bytes(from, to, tag, ref, bytes, count)` on a value.

Sends a message with bytes, up to ALPH_PARCEL_BYTES of them, to an actor
on this machine or another. The actor gets the message with a parcel in
arg ((AlphParcel*)m->arg): it reads the bytes and gives the parcel back
with release. from and ref are what the message carries. Returns ALPH_OK,
ALPH_FULL when too few parcels are free (half the pool is kept for what
arrives) or too much is waiting for that machine, ALPH_GONE when the
actor or its machine cannot be reached or the bytes are too many.

### `AlphLink_longs__ptr`

```mettle
export fn AlphLink_longs__ptr(l: AlphLink*, longs: AlphLong*, room: Word, memory: uint8*, each: Word)
```

Call it as `l->longs(longs, room, memory, each)`, or `l.longs(longs, room, memory, each)` on a value.

Gives the link its long buffers: room of them, each of `each` bytes, in
`memory`, which must hold room times each. Without any, no message
carries more than ALPH_PARCEL_BYTES, and a longer one from another
machine arrives with no bytes. Call it before start.

### `AlphLink_long__ptr`

```mettle
export fn AlphLink_long__ptr(l: AlphLink*) -> AlphLong*
```

Call it as `l->long()`, or `l.long()` on a value.

A long buffer to fill and send (send_long), or 0 when too few are free:
half the pool is kept for what arrives. Put the bytes in ->bytes, up to
->room of them, and how many in ->count. Give it back with free if it is
not sent after all.

### `AlphLink_send_long__ptr`

```mettle
export fn AlphLink_send_long__ptr(l: AlphLink*, from: Word, to: Word, tag: Word, ref: Word, buffer: AlphLong*) -> Word
```

Call it as `l->send_long(from, to, tag, ref, buffer)`, or `l.send_long(from, to, tag, ref, buffer)` on a value.

Sends a message with the bytes of a long buffer to an actor on another
machine. The actor gets the message with a long buffer of its own
machine in arg ((AlphLong*)m->arg), reads ->count bytes at ->bytes and
gives it back with free. arg is 0 when that machine has no long buffer
big enough. From ALPH_OK on the buffer is the link's, which gives it
back when the whole has arrived. Returns ALPH_GONE, with the buffer
still the caller's, when the actor's machine cannot be reached.

### `AlphLink_send_much__ptr`

```mettle
export fn AlphLink_send_much__ptr(l: AlphLink*, from: Word, to: Word, tag: Word, ref: Word, bytes: uint8*, count: Word) -> Word
```

Call it as `l->send_much(from, to, tag, ref, bytes, count)`, or `l.send_much(from, to, tag, ref, bytes, count)` on a value.

Sends a message with any number of bytes: in a parcel when they fit one
(send_bytes), in a long buffer when not, into which they are copied
here. Returns as send_bytes does, and ALPH_BIG when this machine has no
long buffer that holds them.

### `AlphLink_through__ptr`

```mettle
export fn AlphLink_through__ptr(l: AlphLink*, peer: Word, first: Word, count: Word) -> Word
```

Call it as `l->through(peer, first, count)`, or `l.through(peer, first, count)` on a value.

Says that places first, first + 1, ... are reached through the peer whose
own places start at peer: a board on that machine's serial line, which it
passes mail on to. Returns ALPH_GONE when there is no such peer.

### `AlphLink_watch__ptr`

```mettle
export fn AlphLink_watch__ptr(l: AlphLink*, pid: Word)
```

Call it as `l->watch(pid)`, or `l.watch(pid)` on a value.

The actor told when a machine becomes reachable (ALPH_UP) or is lost
(ALPH_DOWN). Set it before start.

### `AlphLink_start__ptr`

```mettle
export fn AlphLink_start__ptr(l: AlphLink*, port: int64) -> Word
```

Call it as `l->start(port)`, or `l.start(port)` on a value.

Listens on a port and starts telling the peers this machine is alive.
Add the peers first. Returns ALPH_GONE when the port cannot be had.

### `AlphLink_first_of__ptr`

```mettle
export fn AlphLink_first_of__ptr(l: AlphLink*, place: Word) -> Word
```

Call it as `l->first_of(place)`, or `l.first_of(place)` on a value.

The first place of the machine a place is on, this machine included, or
-1 when no machine has it.

### `AlphLink_count_of__ptr`

```mettle
export fn AlphLink_count_of__ptr(l: AlphLink*, first: Word) -> Word
```

Call it as `l->count_of(first)`, or `l.count_of(first)` on a value.

How many places the machine starting at first has, 0 when there is none.

### `AlphLink_reaches__ptr`

```mettle
export fn AlphLink_reaches__ptr(l: AlphLink*, place: Word) -> bool
```

Call it as `l->reaches(place)`, or `l.reaches(place)` on a value.

Whether a place on another machine can be reached now.

### `AlphLink_stop__ptr`

```mettle
export fn AlphLink_stop__ptr(l: AlphLink*)
```

Call it as `l->stop()`, or `l.stop()` on a value.

Goes quiet. To its peers this machine is down half a second later. The
port stays open, because an actor may be in the middle of a send: start
uses it again, close gives it up.

### `AlphLink_close__ptr`

```mettle
export fn AlphLink_close__ptr(l: AlphLink*)
```

Call it as `l->close()`, or `l.close()` on a value.

Gives the port up. Only once nothing can send: after stop, with the
cores stopped too.

## alph/seal/seal

Seals: a link only the holders of one key can read or speak on.

Every machine of the network is given the same 32-byte key. Each datagram
is encrypted and signed with it (XChaCha20-Poly1305), under a number used
once: the sender's first place, when the sender's run began, a count that
goes up with every datagram, and four random bytes drawn when it began.
A datagram made without the key, changed on the way, or played again is
dropped, and so is everything from a run earlier than the latest heard.

What it does not give: one key for all means any holder can speak as any
machine, and someone who gets the key later can read what they recorded
before. A machine whose clock was set back before a restart is taken for
an earlier run and not heard until its clock has passed its last start.
Sizes, timing and who talks to whom are not hidden.

This is its own layer so that a program that does not seal its link does
not need the crypto package.

### `AlphSeal`

```mettle
export struct AlphSeal {
  key: CrKey32;
  salt: uint8[4];
  link: AlphLink*;
  lock: int32;
  count: int64;
}
```

A sealed link's key and its count of datagrams sent.

### `AlphSeal_init__ptr`

```mettle
export fn AlphSeal_init__ptr(s: AlphSeal*, link: AlphLink*, key: uint8*) -> Word
```

Call it as `s->init(link, key)`, or `s.init(link, key)` on a value.

Seals a link with a key of 32 bytes. Call it once, after the link's init
and before its start. Returns ALPH_GONE when the link is sealed already
or the system gave no random bytes.

### `AlphSeal_make__ptr`

```mettle
export fn AlphSeal_make__ptr(s: AlphSeal*, out: uint8*, plain: uint8*, count: int64) -> int64
```

Call it as `s->make(out, plain, count)`, or `s.make(out, plain, count)` on a value.

A datagram sealed as this machine would seal it: for tests.

## alph/poll/poll

Polls: a socket or any other file descriptor sends a message when it is
ready. Handlers never wait: they read and write what can be done now, and
ask to be told when there is more.

One thread sleeps in the kernel until something is ready and sends the
messages. Each asking is for one message: an actor asks again when it
wants the next. So a busy socket cannot flood a mailbox, and an actor
that is not ready for more is not told.

x86-64 Linux (epoll).

```mettle
export const ALPH_READ: Word = 1;    // ready for reading, or the other side closed
export const ALPH_WRITE: Word = 2;   // ready for writing
export const ALPH_ERROR: Word = 4;   // the descriptor failed
```

### `AlphEar`

```mettle
export struct AlphEar {
  fd: int64;     // -1 while the slot is free
  to: Word;
  tag: Word;
  owed: Word;    // what was ready when its actor's mailbox was full
  turn: uint32;  // goes up each time the slot is given to a descriptor or taken back
}
```

One descriptor someone asked about.

### `AlphPoll`

```mettle
export struct AlphPoll {
  gate: AlphGate;
  node: AlphNode*;
  ears: AlphEar*;
  room: Word;
  epoll: int64;
  thread: int64;
  stopping: int32;
}
```

The descriptors one node is waiting on.

### `AlphPoll_init__ptr`

```mettle
export fn AlphPoll_init__ptr(p: AlphPoll*, node: AlphNode*, ears: AlphEar*, room: Word) -> Word
```

Call it as `p->init(node, ears, room)`, or `p.init(node, ears, room)` on a value.

ears holds room ears: one for each descriptor asked about at a time.
Messages go out through node. Returns ALPH_GONE when the kernel gave no
epoll.

### `AlphPoll_want__ptr`

```mettle
export fn AlphPoll_want__ptr(p: AlphPoll*, fd: int64, what: Word, to: Word, tag: Word) -> Word
```

Call it as `p->want(fd, what, to, tag)`, or `p.want(fd, what, to, tag)` on a value.

Asks for one message when a descriptor is ready: for reading (ALPH_READ),
for writing (ALPH_WRITE) or either (both). The message has the tag given,
the descriptor in arg, and in ref what it is ready for, with ALPH_ERROR
if it failed. Ask again for the next. Returns ALPH_FULL when every ear is
in use, ALPH_GONE when the kernel refuses the descriptor.

### `AlphPoll_forget__ptr`

```mettle
export fn AlphPoll_forget__ptr(p: AlphPoll*, fd: int64)
```

Call it as `p->forget(fd)`, or `p.forget(fd)` on a value.

Stops asking about a descriptor. Do this before closing it.

### `AlphPoll_stop__ptr`

```mettle
export fn AlphPoll_stop__ptr(p: AlphPoll*)
```

Call it as `p->stop()`, or `p.stop()` on a value.

No message is sent after this returns, and asking after it is refused.

## port/net (host port)

TCP over IPv4 without waiting: every call returns at once.

```mettle
export const ALPH_LATER: int64 = -1;   // nothing now: ask to be told when the socket is ready
export const ALPH_BROKEN: int64 = -2;  // the connection failed or is not there
```

### `alph_tcp_listen`

```mettle
export fn alph_tcp_listen(port: int64) -> int64
```

A socket that takes connections on a port. Returns it, or ALPH_BROKEN
when the port cannot be had.

### `alph_tcp_accept`

```mettle
export fn alph_tcp_accept(listener: int64) -> int64
```

The next connection waiting on a listening socket. Returns it, ALPH_LATER
when none is waiting, or ALPH_BROKEN.

### `alph_tcp_connect`

```mettle
export fn alph_tcp_connect(ip: uint32, port: int64) -> int64
```

Starts a connection to a.b.c.d (as one number) and a port. Returns the
socket: it is connected once it is ready for writing and alph_tcp_failed
says it did not fail. ALPH_BROKEN when it could not start.

### `alph_tcp_failed`

```mettle
export fn alph_tcp_failed(fd: int64) -> bool
```

Whether a socket's connection has failed.

### `alph_read`

```mettle
export fn alph_read(fd: int64, bytes: uint8*, room: int64) -> int64
```

Reads what is there, up to room bytes. Returns how many, 0 when the other
side has closed, ALPH_LATER when nothing is there yet, or ALPH_BROKEN.

### `alph_write`

```mettle
export fn alph_write(fd: int64, bytes: uint8*, count: int64) -> int64
```

Writes as much as fits now. Returns how many bytes were taken, which may
be fewer than count, ALPH_LATER when none can be taken yet, or ALPH_BROKEN.

### `alph_close`

```mettle
export fn alph_close(fd: int64)
```

Closes a descriptor.

## port/proc (host port)

Other programs: start one, and have a descriptor that is ready for
reading when it has ended. With src/poll that is a message, like any
other descriptor.

```mettle
export const ALPH_RUNNING: int64 = -1;  // the program has not ended yet
export const ALPH_NO_PROGRAM: int64 = -2;  // the program could not be started
```

### `alph_proc_env`

```mettle
export fn alph_proc_env(envp: cstring*)
```

The environment programs are started with: what main was given, as
argv + argc + 1. Without it they get only a PATH.

### `alph_proc_start`

```mettle
export fn alph_proc_start(command: cstring) -> int64
```

Starts a command, run by /bin/sh -c. Returns a descriptor that is ready
for reading once the program has ended, or ALPH_NO_PROGRAM when it could
not be started. Close the descriptor when its result has been read.

### `alph_proc_result`

```mettle
export fn alph_proc_result(fd: int64) -> int64
```

How a program ended: its exit status (0 to 255), or 128 plus the signal
that ended it. ALPH_RUNNING while it has not ended. Call it once per
program: it also lets the system forget the program.

### `alph_proc_wait`

```mettle
export fn alph_proc_wait(fd: int64) -> int64
```

Waits for a program to end and returns how it did, as alph_proc_result
does. For a thread whose work is to run the program, not for a handler
that others wait behind.

## port/wire (host port)

Datagrams between machines: UDP over IPv4.

### `AlphWire`

```mettle
export struct AlphWire {
  fd: int64;
}
```

A UDP socket.

### `alph_ip4`

```mettle
export fn alph_ip4(a: int64, b: int64, c: int64, d: int64) -> uint32
```

The address a.b.c.d as one number.

### `AlphWire_open__ptr`

```mettle
export fn AlphWire_open__ptr(w: AlphWire*, port: int64, wait_ms: int64) -> bool
```

Call it as `w->open(port, wait_ms)`, or `w.open(port, wait_ms)` on a value.

Listens on a port. recv gives up after wait_ms with nothing. False when
the port cannot be had.

### `AlphWire_send__ptr`

```mettle
export fn AlphWire_send__ptr(w: AlphWire*, ip: uint32, port: int64, bytes: uint8*, count: int64) -> bool
```

Call it as `w->send(ip, port, bytes, count)`, or `w.send(ip, port, bytes, count)` on a value.

Any thread may send. False when the datagram could not go out.

### `AlphWire_recv__ptr`

```mettle
export fn AlphWire_recv__ptr(w: AlphWire*, bytes: uint8*, room: int64, ip: uint32*, port: int64*) -> int64
```

Call it as `w->recv(bytes, room, ip, port)`, or `w.recv(bytes, room, ip, port)` on a value.

The next datagram, and who sent it. Returns its length, or 0 when none
came in time.

### `AlphWire_recv_now__ptr`

```mettle
export fn AlphWire_recv_now__ptr(w: AlphWire*, bytes: uint8*, room: int64, ip: uint32*, port: int64*) -> int64
```

Call it as `w->recv_now(bytes, room, ip, port)`, or `w.recv_now(bytes, room, ip, port)` on a value.

The next datagram if one is here already, without waiting. Returns its
length, or 0 for none.

### `AlphWire_wait__ptr`

```mettle
export fn AlphWire_wait__ptr(w: AlphWire*, ns: int64)
```

Call it as `w->wait(ns)`, or `w.wait(ns)` on a value.

Waits until a datagram is here, and no longer than `ns` nanoseconds.

### `AlphWire_close__ptr`

```mettle
export fn AlphWire_close__ptr(w: AlphWire*)
```

Call it as `w->close()`, or `w.close()` on a value.

Closes the socket.

## port/line (host port)

A line of bytes to one other machine: any descriptor that carries bytes
both ways, such as a serial port or a TCP connection. A thread reads it
and hands each byte that arrives to take. A process has up to four
lines. Each is opened, then set up, before the next is opened. A sender
takes a line with alph_line_use for one whole message and gives it back
with alph_line_unlock, so two senders' bytes do not mix. Each line has a
lock of its own, and a write never waits: a line whose other end has
stopped reading loses what does not fit, and holds up no other line.
The calls that name no line work on the line the calling thread holds.

### `alph_line_open`

```mettle
export fn alph_line_open(fd: int64)
```

Adds a line: the descriptor it is. It must wait when read (not be set
non-blocking). The line stays the one being set up (alph_line_which)
until the next is opened. A fifth takes the fourth's place.

### `alph_line_which`

```mettle
export fn alph_line_which() -> Word
```

Which line was opened last: 0 for the first.

### `alph_line_use`

```mettle
export fn alph_line_use(line: Word)
```

Takes a line for one whole message. Give it back with alph_line_unlock.

### `alph_line_lock`

```mettle
export fn alph_line_lock()
```

Takes the line opened last: for a program with one line.

### `alph_line_unlock`

```mettle
export fn alph_line_unlock()
```

Lets the next sender have the line this thread holds.

### `alph_line_start`

```mettle
export fn alph_line_start(take: fn(rawptr, int32) -> void, ctx: rawptr)
```

Says where the bytes that arrive on the line go, and starts reading it.
Called again, it only changes where they go: one thread reads a line.

### `alph_line_put`

```mettle
export fn alph_line_put(byte: uint8)
```

Puts one byte on the line. It goes out at the next flush, or when 128 are waiting.

### `alph_line_flush`

```mettle
export fn alph_line_flush()
```

Sends what was put. It does not wait: if the other end is gone, or has
stopped reading and the way to it is full, the rest is dropped.

## port/serial (host port)

A serial device as a line of bytes: a board's UART on /dev/ttyACM0 or
/dev/ttyUSB0, say. The device is set to carry bytes as they are (eight
bits, no parity, one stop bit, nothing translated, no flow control) at
the speed asked for. Give the descriptor to alph_line_open.

### `alph_serial_open`

```mettle
export fn alph_serial_open(path: cstring, baud: int64) -> int64
```

Opens a serial device at `baud` bits a second. Returns its descriptor, or
a negative number when it cannot be opened or set.

## alph/tether/tether

A tether: a node tied to one other machine by a line of bytes, such as a
board's serial port. It is the small way for a microcontroller to be a
place among bigger machines: no numbering, no beats, nothing sent again.
A message goes over once, and a byte lost on the line loses it, unless
both ends make the line sure (see sure below).

A message is nine numbers on the line, a sum of two bytes, then a byte
that marks its end. The numbers are the three parts of the pid it is
for, the three of the pid it is from, and its tag, arg and ref. Each
goes in as few bytes as it needs, seven bits to a byte, so a message is
most often 11 to 14 bytes and at most 47: a serial line is slow, and
most of these numbers are small. tag, arg and ref cross as 32 bits each,
so a bigger machine's larger numbers are cut short, and a number below 0
is as short as one above it.

The pids go as their parts because a 32-bit board and a 64-bit server
pack them differently. A pid too big for this machine's word cannot be
held here, so its message is dropped: an actor on a bigger machine talks
to a board if its place is below 256, its slot below 1,024 and its
generation below 8,192, which holds for actors spawned at the start.

A board has one line, and so one tether. A Linux process has up to four
lines (see the host port's line file), each with a tether of its own.

### `AlphKept`

```mettle
export struct AlphKept {
  to: Word;
  m: AlphMsg;
}
```

A message on a sure line until the other side has it.

### `AlphTether`

```mettle
export struct AlphTether {
  node: AlphNode*;
  first: Word;    // the other machine's places are first, first + 1, ...
  count: Word;
  have: Word;
  escaped: Word;
  dropped: Word;  // messages that came in damaged, or with a pid too big for here
  relay: Word;    // mail off the line for places other than this node's is passed on
  line: Word;     // which of the port's lines this is: 0 on a board
  full: Word;     // the last message off the line found its actor's mailbox full
  sure: AlphSure*;  // what makes the line sure, 0 when it is not
  frame: uint8[48];
}
```

One end of a line: the node it serves and the message being taken off the line.

### `AlphSure`

```mettle
export struct AlphSure {
  t: AlphTether*;
  kept: AlphKept*;
  room: Word;
  held: Word;     // messages kept
  posted: Word;   // of those, how many are on the line since they were last asked for again
  acked: Word;    // the other side has every message up to this number
  got: Word;      // every message from it up to this number was taken
  life: Word;     // this run, 0 until a sound header is heard
  their: Word;    // the other side's run, 0 while it has none
  owe: Word;      // a header to send alone
  stale: Word;    // ticks since the other side last said it has more
  again: Word;    // ticks to wait for that before sending again
  quiet: Word;    // ticks since a message came in its turn
  ask: Word;      // ticks to wait for one before asking
  gap: Word;      // one came early, and the other side was asked to send again
  helper: Word;   // the actor that writes on the line
  next: Word;     // 128 and its number while a message's header has come
  gate: AlphGate;
  frames: Word;   // the test knobs' random number
  resent: Word;   // messages sent again
  lose: Word;     // for tests: about one frame in so many is not sent
  damage: Word;   // for tests: about one frame in so many has a byte changed
}
```

What a sure line keeps. A tether that is not sure has none of it, and
is not one byte bigger.

### `AlphTether_send__ptr`

```mettle
export fn AlphTether_send__ptr(t: AlphTether*, to: Word, m: AlphMsg*) -> Word
```

Call it as `t->send(to, m)`, or `t.send(to, m)` on a value.

Puts a message on the line, whoever it is for.

### `AlphTether_open__ptr`

```mettle
export fn AlphTether_open__ptr(t: AlphTether*, node: AlphNode*, first: Word, count: Word)
```

Call it as `t->open(node, first, count)`, or `t.open(node, first, count)` on a value.

Starts the line for a node that is already placed: mail off the line is
put through it. The other machine's places are first, first + 1, ...
Whether mail is passed on (relay) is left as it was set.

### `AlphTether_init__ptr`

```mettle
export fn AlphTether_init__ptr(t: AlphTether*, node: AlphNode*, place: Word, first: Word, count: Word)
```

Call it as `t->init(node, place, first, count)`, or `t.init(node, place, first, count)` on a value.

Ties a node to the machine at the other end of the port's line. The node
is place `place`. The other machine's places are first, first + 1, ...
Call it before the first spawn.

### `AlphTether_keep__ptr`

```mettle
export fn AlphTether_keep__ptr(t: AlphTether*, to: Word, m: AlphMsg*) -> Word
```

Call it as `t->keep(to, m)`, or `t.keep(to, m)` on a value.

Sends a message on a sure line: it is kept until the other side says it
has it, and sent again until then. Returns ALPH_FULL when room messages
are kept already, so the sender can try again later. On a line that is
not sure it is send.

### `AlphTether_tick__ptr`

```mettle
export fn AlphTether_tick__ptr(t: AlphTether*)
```

Call it as `t->tick()`, or `t.tick()` on a value.

The line's clock: at least one side of a sure line calls it now and then,
from a timer, about as often as a message goes there and back (20 to 100
ms on a serial line). Kept messages the other side has not said it has
for more than a tick are sent again. When nothing came in its turn from
the other side for more than a tick, it is asked to send again what this
side has not said it has. Each time that brings nothing, the next waits
twice as long, up to 8 ticks, unless messages came early: then one is
surely missing. On a line that is not sure it does nothing.

### `AlphTether_sure__ptr`

```mettle
export fn AlphTether_sure__ptr(t: AlphTether*, s: AlphSure*, kept: AlphKept*, room: Word) -> Word
```

Call it as `t->sure(s, kept, room)`, or `t.sure(s, kept, room)` on a value.

Makes the line sure: each message arrives once and in the order it was
sent while both ends are up, and what is lost or damaged on the line is
sent again. Both ends call it, after init or relay, and at least one
calls tick. s is new (all 0) and holds what the line keeps. kept holds
the messages the other side does not yet have: room of them, 1, 2, 4 and
so on up to 64 (another room is taken as the one below it). A send while
all are kept is refused with ALPH_FULL. A side that starts again is a
new run: what was kept for its last run is dropped, and the two start
numbering again by themselves. It takes one actor of the node. Returns
ALPH_FULL when no actor is left.

## alph/tether/relay

A relay: a machine on the link that has a board on its serial line and
passes mail both ways, so any machine of the network reaches the board's
actors by pid and the board reaches theirs. The other machines are told
the board's places are reached through this one (AlphLink_through).

Mail for the board waits in a short queue that a thread of its own writes
to the line. So a slow line holds up neither the link, which must go on
saying this machine is alive, nor the actors that send. When 64 messages
are waiting, a sender gets ALPH_FULL and mail passed on from another
machine is dropped.

Made sure after relay (AlphTether_sure), the line is ticked by that
thread, so the program has nothing more to do.

The board has no door: its actors are reached by pid, not found by name
or watched from other machines.

Linux only, since the link is. A process has up to four relays, one for
each of its lines: open a line, then relay its board, then the next.

### `AlphTether_relay__ptr`

```mettle
export fn AlphTether_relay__ptr(t: AlphTether*, link: AlphLink*, first: Word, count: Word)
```

Call it as `t->relay(link, first, count)`, or `t.relay(link, first, count)` on a value.

Puts a board on this machine's line behind its link. The board's places
are first, first + 1, ... Call it after the link's init and before its
start, with the line's descriptor just given to the port (alph_line_open):
the board is on the line opened last. A fifth board is not taken.

## port/board (mcu port)

What a board needs before alph runs on it. Call it first in main. Other
boards have their own in their port's folder, so a program is the same
source on each.

### `alph_board_start`

```mettle
export fn alph_board_start()
```

Does what this board needs before anything else. Call it first in main.

### `alph_board_fresh`

```mettle
export fn alph_board_fresh() -> Word
```

A number this board has not given before, for work that must be done at
most once (alph/board/asks). QEMU's virt board has a clock that goes on
while the board is restarted: this is its time in steps of 134 ms. The
first call after a start waits for the next step, at most that long, so
the number is one the board cannot have given before it was restarted.
