# Using alph

alph is an actor runtime written in Mettle. This guide shows how to write a program with each of its layers. It assumes you know Mettle. [design.md](design.md) says why alph is built this way and what was measured. Every program here is a cut-down copy of a file in `examples/` or `tests/`, so read those next.

## The model in five sentences

An actor is a state and a handler, and the handler runs once for each message the actor is sent. A message is four words: `tag` (what it is), `from` (the sender's pid), `arg` (one word of data) and `ref` (a number that ties a reply to its request). A node holds the actors and runs one message at a time, and a pid names an actor and is never 0. A handler returns 0 to go on, `ALPH_END` when its actor is finished, and anything else as the reason it failed, and any non-zero return ends the actor. The program owns all memory: you hand alph arrays for the actor slots and the mailboxes, and alph allocates nothing.

## Building

Each layer is one import: `alph/actor/actor` (the core), `alph/cores/cores`, `alph/time/time`, `alph/place/place`, `alph/poll/poll`, `alph/life/life`, `alph/link/link`, `alph/name/name`, `alph/door/door` and `alph/seal/seal`. Map alph in your program's `mettle.deps`:

```text
alph=<path to alph>/src
```

Then pick a port with `-I` when you build. `ports/host` is for x86-64 Linux and `ports/mcu` is for a board with no OS:

```bash
mettle --build -s --release examples/count.mettle -I ports/host -o count
```

Build with `-s`. Without it the compiler turns a failed check (a bad index, a division by zero) into an exit that alph cannot catch.

## A node

A node runs actors on one thread. You can start it, spawn actors, send them messages, and ask for a reply. This is [examples/count.mettle](../examples/count.mettle) without its comments:

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

- `init(actors, slots, mail, room)` gives the node `slots` actor slots and a mailbox of `room` messages for each. `mail` must hold `slots * room` messages.
- `spawn(handler, state)` returns the new pid, or 0 when every slot is taken. The handler finds `state` in `a->state`.
- `g_node.send(pid, tag, arg)` is for code outside an actor: `main`, another thread, an interrupt. Inside a handler use `a->send(pid, tag, arg)`, which also fills in `from`. alph's own tags are negative, and the examples use positive ones for theirs.
- `run()` runs messages until `stop()`. With nothing to do the node sleeps until a message arrives. `stop()` makes `run` return once the handler in progress is done.
- `turn()` runs the messages that are waiting and returns how many that was, for a program with a loop of its own, such as one that draws a frame each time round: `var ran: Word = g_node.turn();`
- `alive(pid)` says whether a pid names an actor here that is alive now. A pid kept after its actor ended stays dead for a long time, not for ever.

`ask` sends a request and returns its ref, and `reply` answers it with the same ref. This is from `tests/t_actor.mettle`:

```mettle
fn ponger(a: AlphActor*, m: AlphMsg*) -> Word {
  a->reply(m, PONG, m->arg + 1);
  return 0;
}

fn pinger(a: AlphActor*, m: AlphMsg*) -> Word {
  var p: Pinger* = (Pinger*)a->state;
  if (m->tag == GO) {
    p->ponger = m->arg;
    p->ref = a->ask(p->ponger, PING, 0);
    return 0;
  }
  // the reply: m->ref == p->ref
  return 0;
}
```

When the reply arrives, `m->ref` equals the ref `ask` returned, so an actor with several requests out can tell them apart. A send returns `ALPH_OK` (0) or a refusal, and `ask` returns a ref above 0 or a refusal:

- `ALPH_FULL`: the mailbox of the actor you sent to is full. The message was not delivered.
- `ALPH_GONE`: there is no such actor. It ended, or the pid never lived.

Mailboxes are bounded, so a send can be refused and the program decides what happens next. alph does not queue the message for you. The usual answer inside an actor is to keep the work, send yourself a message and try again on the next turn. This is from `tests/t_cores.mettle`:

```mettle
fn source(a: AlphActor*, m: AlphMsg*) -> Word {
  var s: Source* = (Source*)a->state;
  while (s->sent < NOTES) {
    if (a->send(s->sink, NOTE, s->sent) != ALPH_OK) {
      a->send(a->pid, MORE, 0);
      return 0;
    }
    s->sent = s->sent + 1;
  }
  return 1;
}
```

Code outside an actor, such as another thread, loops and sends again on `ALPH_FULL`, and gives up on `ALPH_GONE`, as `tests/t_actor.mettle` does.

A handler that crashes (a null pointer, a division by zero, an index past the end, a fault signal) ends its actor with the reason `ALPH_CRASHED`, and the node goes on. This works on Linux, in a program built with `-s`. On a microcontroller a crash is still the board's trap.

## Several cores

`AlphCores` runs one node per thread. An actor sends to a pid on another core the way it sends next door. You can use it to spread work over the cores of one machine. This is cut down from [examples/spread.mettle](../examples/spread.mettle), which counts primes on four cores:

```mettle
import "alph/cores/cores";

var g_cores: AlphCores;
var g_core: AlphCore[4];
var g_actors: AlphActor[8];
var g_mail: AlphMsg[64];

// worker and boss are handlers like the ones above
fn main() -> int32 {
  g_cores.init(&g_core[0], CORES, &g_actors[0], 2, &g_mail[0], 8);
  var b: Boss;
  for i in 0..CORES {
    b.workers[i] = g_cores.spawn_on((Word)i, &worker, 0);
  }
  g_cores.send(g_cores.spawn(&boss, (rawptr)&b), GO, 0);
  g_cores.run();
  return 0;
}
```

- `init(cores, count, actors, slots, mail, room)` is the node's `init` for `count` cores. `actors` holds `count * slots` actors and `mail` holds `count * slots * room` messages.
- `spawn_on(core, handler, state)` spawns on a core counted from 0. `spawn(handler, state)` picks the core with the fewest actors. Both return 0 when the core, or every core, is full.
- `send(pid, tag, arg)` is for code outside an actor. `alive(pid)` works as on a node.
- `run()` runs the first core on this thread and the rest on threads of their own, until `stop()`. Every `run` starts new threads, so what belongs to a thread (a GPU a handler opened) does not last from one run to the next.
- Inside a handler, `a->cores()` gives the `AlphCores` the actor runs among, and `a->cores()->stop()` stops them all.

An actor stays on the core it was spawned on. Work moves between cores when your program hands it out in pieces, as the boss in `spread.mettle` does: a worker that answers gets the next chunk. A send from one core to another can be refused with `ALPH_FULL`, as on one node. If you want alph to choose a place for each piece of work, use places below.

## Timers

`AlphTime` sends a message later. You can use it to wake an actor after some milliseconds, or to do something every so often. This is from [examples/mcu/blink.mettle](../examples/mcu/blink.mettle), where the clock actor sets its own next timer:

```mettle
var g_time: AlphTime;
var g_timers: AlphTimer[2];

fn clock(a: AlphActor*, m: AlphMsg*) -> Word {
  var count: Word* = (Word*)a->state;
  *count = *count + 1;
  g_time.after(1, a->pid, TICK, 0);
  return 0;
}

fn main() -> int32 {
  g_node.init(&g_actors[0], 2, &g_mail[0], 4);
  g_time.init(&g_node, &g_timers[0], 2);
  var clock_pid: Word = g_node.spawn(&clock, (rawptr)&g_count);
  g_time.after(1, clock_pid, TICK, 0);
  g_node.run();
  g_time.stop();
  return 0;
}
```

- `init(node, timers, room)` gives the timers `room` slots, kept in your array. The messages go out through `node`. With cores, pass a core's node, as `tests/t_cores.mettle` does with `&g_core[0].node`, and a timer can reach an actor on any core.
- `after(ms, to, tag, arg)` sends `tag` and `arg` to `to` in `ms` milliseconds. It never sends early, and it may send up to a tick late. It returns the timer's ref (above 0), or `ALPH_FULL` when every timer is in use.
- The message arrives from pid 0 and carries that same ref in `m->ref`.
- `cancel(ref)` takes a timer back and returns `ALPH_OK`, or `ALPH_GONE` when the message was already sent.
- `stop()` makes sure no timer's message is sent after it returns. Waiting timers are dropped.

If the mailbox of the actor a timer is for is full when it falls due, the timer tries again a tick later. Every timer operation looks at every slot, which is right for tens of timers, not for thousands.

## Sockets

`AlphPoll` has a socket, or any file descriptor, send a message when it is ready. A handler never waits: it reads and writes what can be done now, and asks to be told when there is more. The host port's `port/net` has TCP calls to go with it, and none of them waits. This is the connection actor of the echo server in [examples/talk.mettle](../examples/talk.mettle):

```mettle
import "port/net";
import "alph/poll/poll";

var g_poll: AlphPoll;
var g_ears: AlphEar[4];

fn echo(a: AlphActor*, m: AlphMsg*) -> Word {
  var c: Conn* = (Conn*)a->state;
  while (true) {
    if (c->sent < c->have) {
      var put: int64 = alph_write(c->fd, &c->bytes[c->sent], c->have - c->sent);
      if (put == ALPH_LATER) {
        g_poll.want(c->fd, ALPH_WRITE, a->pid, READY);
        return 0;
      }
      if (put < 0) {
        break;
      }
      c->sent = c->sent + put;
      continue;
    }
    var got: int64 = alph_read(c->fd, &c->bytes[0], 64);
    if (got == ALPH_LATER) {
      g_poll.want(c->fd, ALPH_READ, a->pid, READY);
      return 0;
    }
    if (got <= 0) {
      break;  // the client closed
    }
    c->have = got;
    c->sent = 0;
  }
  g_poll.forget(c->fd);
  alph_close(c->fd);
  return ALPH_END;
}
```

- `init(node, ears, room)` starts the poll with `room` ears in your array, one for each descriptor asked about at a time. Messages go out through `node`. `stop()` ends it.
- `want(fd, what, to, tag)` asks for one message when `fd` is ready for `ALPH_READ`, `ALPH_WRITE` or both. The message has your `tag`, the descriptor in `arg`, and in `ref` what it is ready for, with `ALPH_ERROR` if it failed. Ask again for the next one. It returns `ALPH_FULL` when every ear is in use and `ALPH_GONE` when the kernel refuses the descriptor.
- `forget(fd)` stops asking. Do this before closing the descriptor.
- `alph_tcp_listen(port)`, `alph_tcp_accept(listener)` and `alph_tcp_connect(ip, port)` give sockets. `alph_read` and `alph_write` return how many bytes moved, `ALPH_LATER` when nothing can be done yet, or `ALPH_BROKEN`. `alph_read` returns 0 when the other side has closed. A connection made with `alph_tcp_connect` is ready once it is ready for writing and `alph_tcp_failed(fd)` is false.

## Lives

`AlphLife` lets an actor be told when another ends and why, and lets a failed actor go on with the same pid. It works with `AlphCores`, so it is for the host port. Set it up after the cores and before they run:

```mettle
var g_life: AlphLife;
var g_watches: AlphWatch[4];
var g_keeps: AlphKeep[2];

fn main() -> int32 {
  g_cores.init(&g_core[0], 2, &g_actors[0], 8, &g_mail[0], 4);
  g_life.init(&g_cores, &g_watches[0], 4, &g_keeps[0], 2);
  ...
}
```

**Watching.** `watch(watcher, target)` has alph send the watcher `ALPH_ENDED` when the target ends. `from` is the actor that ended, `arg` is the reason and `ref` is the ref `watch` returned. This is from `tests/t_life.mettle`:

```mettle
fn probe(a: AlphActor*, m: AlphMsg*) -> Word {
  var p: Probe* = (Probe*)a->state;
  if (m->tag != ALPH_ENDED) {
    return 0;
  }
  p->from = m->from;
  p->reason = m->arg;
  p->ref = m->ref;
  return 0;
}

var ref: Word = g_life.watch(watcher, far);
```

The reason is what the handler returned: `ALPH_END` for an actor that finished and any other value for one that failed. Two reasons come from alph itself: `ALPH_CRASHED` when the handler crashed, and `ALPH_LOST` when the actor's machine was lost (see Other machines). `watch` returns the watch's ref (above 0), `ALPH_GONE` when the target is already gone, or `ALPH_FULL` when every watch is in use. `unwatch(ref)` stops a watch and returns `ALPH_OK`, or `ALPH_GONE` when the watch is over or its message is on the way. An actor is gone before anyone is told, so a watcher that hears of an end can no longer reach it.

**Settle.** If the watcher's mailbox is full when its news is due, alph keeps the news and tells it later. alph tries again whenever something ends or is watched. Nothing tries when the mailbox empties, so a program that fills its watchers' mailboxes calls `g_life.settle()` now and then.

**Keeping.** `keep(pid, reset, times)` keeps an actor. When its handler fails or crashes it is not ended: alph calls `reset` on its state and the actor goes on with the same pid and the mail it had. Nothing that knows its pid has to learn a new one. After `times` restarts it ends like any other actor, and its watchers are told. An actor that returns `ALPH_END` ends and is not restarted. Keeping an actor again sets `times` anew. In `tests/t_life.mettle`, `reset` is `fn mortal_reset(state: rawptr)` and the call is `g_life.keep(kept, &mortal_reset, 2);`. `keep` returns `ALPH_OK`, `ALPH_FULL` when every keep is in use, or `ALPH_GONE` when the actor is not on these cores or is not alive.

Crash recovery is for Linux, in a program built with `-s`. A crash ends only its actor, or restarts it if it is kept, and the other actors on its core never notice.

## Places and jobs

`AlphPlaces` sends a job to the place where it will finish first: a core, the GPU or another machine. You describe a kind of work once, with a function for each way it can run. alph times each way and chooses. It is for x86-64 Linux, like the cores.

A place is an actor that runs jobs one way, on a core you give it. A GPU place wants a core to itself, because a GPU belongs to the thread that opened it. `kind(kind, cpu, gpu)` says how a kind is run, with 0 for a way the kind does not have. Both functions should call the same Mettle code, so the answer is the same either way. A way returns 0, or non-zero when it cannot run here (no GPU, say): the job then goes another way and that way is not tried again. This is from [examples/render.mettle](../examples/render.mettle), which has `tile_on_core` and `tile_on_gpu`. A way is a function of this shape, here `primes_here` from `examples/far.mettle`:

```mettle
var g_places: AlphPlaces;
var g_seats: AlphPlace[4];
var g_kinds: AlphKind[4];
var g_jobs: AlphJob[8];

fn primes_here(job: AlphJob*) -> Word {
  job->out = count_primes(job->in);
  return 0;
}

fn main() -> int32 {
  g_cores.init(&g_core[0], 5, &g_actors[0], 1, &g_mail[0], 16);
  g_places.init(&g_seats[0], 4, &g_kinds[0], 4);
  g_places.kind(EITHER, &tile_on_core, &tile_on_gpu);
  g_places.kind(CORES_ONLY, &tile_on_core, 0);
  g_places.on_core(&g_cores, 1, ALPH_CPU);
  g_places.on_core(&g_cores, 4, ALPH_GPU);
  ...
}
```

`init(seats, room, kinds, count)` takes your arrays of places and kinds. `on_core(cores, core, way)` makes a place on one core and returns its pid, or 0 when the core or the places are full. Set places up one at a time. `way` is `ALPH_CPU` or `ALPH_GPU`. Without a GPU the same program runs on the cores.

**Jobs.** You fill in a job and ask for it to be run. These are the fields you use:

| Field | You set it | You read it |
|---|---|---|
| `kind` | which kind of work | |
| `size` | how much work, in your own unit | |
| `home` | where its data is: `ALPH_CPU`, `ALPH_GPU` or `ALPH_NOWHERE` | where the job ran |
| `data` | a pointer for your functions to use | |
| `in` | the one word a job that can go to another machine is given | |
| `out` | | the one word it gives back |
| `status` | | `ALPH_OK`, `ALPH_GONE` when no place can run it, `ALPH_FULL` to ask again |
| `way` | | how it was run: `ALPH_CPU`, `ALPH_GPU` or `ALPH_FAR` |
| `ns` | | how long it took, bringing its data included |

The boss in `render.mettle` keeps a free list of jobs, takes one off, fills it in and asks:

```mettle
var job: AlphJob* = b->free;
b->free = job->next;
job->kind = s->kind;
job->size = (Word)s->tile;
job->home = ALPH_NOWHERE;
var out: Word = g_places.ask(a, job);
if (out < 0) {
  job->next = b->free;
  b->free = job;
}
```

`ask(a, job)` returns the ref of the request, `ALPH_FULL` when the mailbox of the place it picked is full, or `ALPH_GONE` when no place can run the kind or there is no such kind. When it returns a refusal the job is still yours, as above.

The answer comes back to the asking actor as a message with the tag `ALPH_DONE`. Its `arg` is the job (`(AlphJob*)m->arg`) and its `ref` is the ref `ask` returned. Read `status`, `way`, `ns` and `out` from it, then put the job back on your free list.

From the moment `ask` succeeds until `ALPH_DONE` arrives, the job belongs to alph. Do not read or write it. Take it off your own lists first, because alph uses its `next` field. When the answer comes it is yours again.

**Homes and bring.** Work travels, data stays. A job says where its data is in `home`, and alph keeps separate times for a job run where its data is and one run away from it, so a job tends to stay with its data. After a job runs, alph sets its `home` to where it ran. `ALPH_NOWHERE` means it has no data yet, as for a tile that is made and not moved.

When a core is to run a job whose data is on the GPU, the data has to come to the host first. `bring(kind, function)` says how. alph runs the function on the GPU's place, the only thread allowed to touch the GPU. It returns 0 when it brought the data, or non-zero when it could not, after which it is not tried again. Call `bring` after `kind`. Without it, a job whose data is on the GPU runs only there. A program asks for its data on the host the same way, with a job only a core can run, on data that is on the GPU. This is how `render.mettle` fetches its whole picture in one crossing:

```mettle
g_places.kind(FETCH, &picture_here, 0);
g_places.bring(FETCH, &bring_picture);

var fetch: AlphJob* = b->free;
b->free = fetch->next;
fetch->kind = FETCH;
fetch->size = (Word)PIXELS;
fetch->home = ALPH_GPU;
g_places.ask(a, fetch);
```

## Other machines

`AlphLink` lets actors on several machines send each other messages over UDP. Each machine owns a run of place numbers, and a pid says which machine its actor is on, so an actor sends to a pid on another machine the way it sends next door. On top of it you can find an actor by name, watch it, and share jobs.

**The link.** A machine's cores are places `first`, `first + 1` and so on. In `examples/far.mettle` the boss machine's three cores are places 0 to 2 and the helper's are 3 to 5, as `machine` below sets up.

- `init(cores, first, peers, room)` makes the cores one machine among several. Call it before the first spawn. `peers` holds `room` peers.
- `peer(first, count, ip, port)` adds another machine: where its places start, how many it has, and where it listens. You list peers by hand. Make the address with `alph_ip4(127, 0, 0, 1)`. It returns `ALPH_FULL` when there is no room.
- `watch(pid)` names the actor sent `ALPH_UP` when a machine becomes reachable and `ALPH_DOWN` when it is lost. `arg` is the first place of that machine. Set it before `start`. The door below can do this for you.
- `start(port)` listens on a port and starts telling the peers this machine is alive. Add the peers first. It returns `ALPH_GONE` when the port cannot be had.
- `reaches(place)` says whether a place on another machine can be reached now.
- `stop()` goes quiet. To its peers this machine is down half a second later. `close()` gives the port up, once nothing can send: after `stop`, with the cores stopped too.

Between two machines that are both up, messages arrive once and in order. What a machine has not got in 40 ms is sent again. Every machine tells its peers it is alive 20 times a second, and one that stays quiet for half a second is down. A send to a machine that is down, or not heard yet, returns `ALPH_GONE`. A send returns `ALPH_FULL` when too many messages to that machine are still waiting for its word. A machine that was only out of reach carries on where it was. A machine that was restarted counts as a new one, so mail meant for the old one is not handed to the new. A full mailbox at the far end drops the message and the sender is not told, so for a message that must arrive, ask and wait for the reply.

**Sealing the link.** A link is in the clear unless you seal it. `AlphSeal` encrypts and signs every datagram with one 32-byte key that every machine of the network is given. A datagram made without the key, changed on the way or played a second time is dropped, and so is everything from a run of a machine earlier than the latest one heard. Call `init(link, key)` once, after the link's `init` and before its `start`. It returns `ALPH_GONE` when the link is sealed already or the system gave no random bytes. This is from `tests/t_seal.mettle`:

```mettle
import "alph/seal/seal";

var g_a_seal: AlphSeal;

g_a_link.init(&g_a, 0, &g_a_peers[0], 1);
g_a_link.peer(2, 2, here, port_b);
g_a_seal.init(&g_a_link, &key[0]);
g_a_link.start(port_a);
```

The seal is its own layer, and it needs the cryptex package mapped in `mettle.deps` (`cryptex=<path to cryptex>/src`). A program that does not seal its link does not need it.

**Names and the door.** `AlphNames` gives a pid a name, which is a number you choose: `init(slots, room)`, `set(name, pid)`, `get(name)` (the pid, or 0) and `forget(name)`. A name is not taken away when its actor ends. `AlphDoor` is how machines find and watch each other's actors, with nothing but messages.

- `door.init(cores, link, names, life)` opens the machine's door and returns its pid. The door must be the first actor spawned on the cores, after the link, the names and the lives are set up and before the link starts. It returns `ALPH_GONE` when it was not first. Any machine can work out another's door pid with `alph_door_of(first)`.
- `door.tell(pid)` names the actor sent `ALPH_UP` and `ALPH_DOWN` as machines come and go.

This is how `examples/far.mettle` sets up one machine as far as its door:

```mettle
fn machine(m: Machine*, first: Word, other: Word, ip: uint32, port: int64) {
  m->cores.init(&m->core[0], 3, &m->actors[0], 4, &m->mail[0], 16);
  m->link.init(&m->cores, first, &m->peers[0], 1);
  m->link.peer(other, 3, ip, port);
  m->names.init(&m->name_slots[0], 2);
  m->life.init(&m->cores, &m->watches[0], 2, &m->keeps[0], 1);
  m->door.init(&m->cores, &m->link, &m->names, &m->life);
}
```

`Machine` is a struct that holds the arrays: `cores`, `core`, `actors`, `mail`, `link`, `peers`, `names`, `name_slots`, `life`, `watches`, `keeps` and `door`. After this you spawn your actors and then call `link.start(port)`.

The helper machine names its worker. The boss machine finds it by name when the door tells it that the helper is up:

```mettle
g_helper_machine.names.set(HELPER, pid);

fn boss(a: AlphActor*, m: AlphMsg*) -> Word {
  if (m->tag == ALPH_UP) {
    g_boss_machine.door.find(a, m->arg, HELPER);
  } else if (m->tag == ALPH_HERE && m->arg != 0) {
    b->helper = m->arg;
  }
  ...
}
```

`find(a, place, name)` asks the door of the machine that has `place` for the pid behind `name`. The answer is a message with the tag `ALPH_HERE`. Its `arg` is the pid, or 0 when that machine has no such name, and its `ref` is the ref `find` returned. `find` returns `ALPH_GONE` when no machine has the place or it cannot be reached. With the pid you send to the actor as to any other.

**Watching across machines.** `door.watch(watcher, target)` works for an actor anywhere. The watcher is sent `ALPH_ENDED` as for a local actor. For a target on another machine, the door there keeps the watch. If that machine is lost first, the actor has ended with the reason `ALPH_LOST`. A target that was already gone there is told as an end with the reason `ALPH_GONE`, and one that machine has no watch left for with the reason `ALPH_FULL`. `watch` returns the watch's ref, `ALPH_FULL` when every watch is in use or the way to the target's machine is full for now, or `ALPH_GONE` when the target is gone or its machine cannot be reached.

**Jobs on other machines.** A job that is one word in and one word out can be done by a worker actor on another machine. To alph that is one more place, with a time of its own, the network included. A job goes there when that is where it will finish first and stays here when it is not. Make a place for the far way next to the cores:

```mettle
g_places.kind(PRIMES, &primes_here, 0);
g_places.on_core(&g_boss_machine.cores, 1, ALPH_CPU);
g_boss.far_place = g_places.on_core(&g_boss_machine.cores, 0, ALPH_FAR);
```

Once the worker is found, give it to the kind with `far(kind, worker)` (call it after `kind`) and have the far place watch it, so that if the worker ends or its machine is lost the far place hears:

```mettle
g_places.far(PRIMES, b->helper);
g_boss_machine.door.watch(b->far_place, b->helper);
```

Fill in a job with `job->in` and `job->home = ALPH_NOWHERE`, and ask as before. In the `ALPH_DONE` answer, `way` is `ALPH_FAR` when the other machine did it, and `out` is what the worker answered. A job with data of its own cannot leave the machine. On the other machine the worker is sent `ALPH_WORK` with the job's `in` as `arg`. It answers `ALPH_WORKED` with the job's `out`:

```mettle
fn worker(a: AlphActor*, m: AlphMsg*) -> Word {
  if (m->tag == ALPH_WORK) {
    a->reply(m, ALPH_WORKED, count_primes(m->arg));
  }
  return 0;
}
```

If the worker ends or its machine is lost, the jobs it had not answered are done here and nothing more is sent to it. A request or an answer lost on the way leaves a job waiting for ever, unless you give the places a clock. With `clock(time)`, a job not answered in eight times its usual time, and at least a second, is given up on and placed again. This is from `tests/t_far.mettle`:

```mettle
g_time.init(&g_a.core[0].node, &g_timers[0], 4);
g_places.clock(&g_time);
```

`examples/far.mettle` counts primes on two machines. With no arguments both machines run in one process. On two computers, start `./far helper <the boss's address>` on one and `./far boss <the helper's address>` on the other. If the other machine is not there, or is lost on the way, the work is done here.

## A microcontroller

The `mcu` port runs the core and timers on one hart with no OS. The port gives you:

- A 32-bit `Word`, up to 1,024 actors in a node and 256 places.
- A gate that keeps senders from each other by turning interrupts off, and a wait that sleeps on `wfi` until an interrupt.
- A timer alarm from the board's timer interrupt, so `AlphTime` works as on the host.

The program does what any interrupt program does: it provides `mettle_trap`, installs the traps and enables interrupts. There is no guard on a microcontroller. A crash is the board's trap, and your `mettle_trap` decides what happens. This is [examples/mcu/blink.mettle](../examples/mcu/blink.mettle):

```mettle
@interrupt fn mettle_trap() {
  mettle_board_exit(99);
}

fn main() -> int32 {
  g_node.init(&g_actors[0], 2, &g_mail[0], 4);
  g_time.init(&g_node, &g_timers[0], 2);
  ...
  mettle_board_trap_install();
  mettle_irq_enable();
  g_time.after(1, clock_pid, TICK, 0);
  g_node.run();
  g_time.stop();
  return (int32)g_count;
}
```

Build it for 32-bit RISC-V and run it in QEMU:

```bash
mettle --release examples/mcu/blink.mettle --target riscv32-none --board qemu-virt --emit-flat blink.bin -I ports/mcu
qemu-system-riscv32 -M virt -bios none -nographic -device loader,file=blink.bin,addr=0x80000000,force-raw=on
```

The whole image of this program, board startup included, is 3,256 bytes: about 1.3 KB of core, 1.1 KB of timers and alarm, and the rest the board and the program. `check.sh` fails the build above 5 KB.

**A board among bigger machines.** `AlphTether` ties a node to one other machine by a line of bytes: on a board, its serial port. Each side's actors then reach the other's by pid, as with any other place. This is the board's side, [examples/mcu/tether.mettle](../examples/mcu/tether.mettle): the board is place 1 and the machine on the line is place 0.

```mettle
import "alph/tether/tether";

var g_tether: AlphTether;

fn answerer(a: AlphActor*, m: AlphMsg*) -> Word {
  if (m->tag == QUIT) {
    a->node->stop();
    return 0;
  }
  a->reply(m, PONG, m->arg + 1);
  return 0;
}

fn main() -> int32 {
  g_node.init(&g_actors[0], 2, &g_mail[0], 4);
  mettle_board_trap_install();
  g_tether.init(&g_node, 1, 0, 1);
  g_node.spawn(&answerer, 0);
  mettle_irq_enable();
  g_node.run();
  return 0;
}
```

`init(node, place, first, count)` makes the node place `place` and sends mail for places `first` to `first + count - 1` down the line. Call it before the first spawn. The other end is the same layer on the host port, given the line's descriptor with `alph_line_open(fd)` first, as [examples/mcu/tether_host.mettle](../examples/mcu/tether_host.mettle) does with a TCP connection from QEMU. A message goes over once: a byte lost on the line loses it. A pid from the bigger machine has to fit the board's word (place below 256, slot below 1,024, generation below 8,192), which holds for actors spawned at the start; a message whose pids do not fit is dropped.

## Limits

These are not built yet.

- A sealed link has one key for the whole network: any holder can speak as any machine, and someone who gets the key later can read what they recorded before.
- A job with data of its own cannot go to another machine, only a job of one word in and one word out.
- Timers look at every timer slot: right for tens of timers, not thousands. A timer wheel behind the same four functions is not built.
- Sockets are Linux only, and there is no file IO.
- A message between two cores costs 150 to 300 ns against about 20 ns inside a node. Removing that needs a queue per pair of cores that the sender writes without touching anything the receiver owns, which changes what a full mailbox can tell a sender. Not built.
- A microcontroller reaches other machines only over a serial line to one of them, and nothing lost on that line is sent again.
- A full mailbox at the far end of a link drops its message and the sender is not told.
- Peers are listed by hand.
- A watch cannot be dropped across machines.
- Restart limits are counted in all, not over time, and there are no groups that restart together.
- A crash in a handler ends only its actor on Linux, in a program built with `-s`. On a microcontroller a crash is still the board's trap.
- A crossing does not yet carry everything that is waiting: one lock, one launch or one datagram for a batch is not built into the cores or the link, where every message still crosses alone.
- alph predicts a job's time from its size, so work whose time depends on something else, such as where in a picture a Mandelbrot tile is, is placed less well.
