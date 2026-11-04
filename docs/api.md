# alph runtime API

Every exported function, type and constant, with its doc comment. Built by `tools/apidoc.sh` from `src/`; do not edit by hand.

Functions are grouped by module. Names that take `ctx` run inside a handler; names starting `alph_node_` take the node and work from any thread.

## alph

The alph runtime in one import.

```text
import "alph/alph";
```

Imports are visible through the whole import graph, so this brings in
everything an application uses: the node and its actors, messages,
supervisors and medics. The x86-64 Linux layer under alph/sys comes along
too; most programs never call it directly.

## alph/core/node

Actors and the node that runs them.

A node is one OS process running a set of schedulers, one thread each. An
actor is a state block, a bounded mailbox, a signal queue and a handler:

```text
fn handler(ctx: AlphCtx*, m: AlphMsg*) -> int64
```

The handler runs one message to completion and returns ALPH_CONTINUE, or
`alph_stop(ctx, reason)` to exit. That return is the only point where a
scheduler switches actors, so a handler must not block or loop without
bound: give it a `where cycles < N` deadline to have the compiler prove
it. The first message every actor gets is ALPH_TAG_INIT.

A crash inside a handler (a failed check, a null or wild pointer, a divide
by zero, a stack overflow) ends only that actor, with ALPH_CRASHED, and its
links and monitors see it as on BEAM. Programs must be built with -s for
failed checks to be caught.

Signals (link, unlink, exit, monitor, demonitor, down, timer) travel on a
separate unbounded queue and are never dropped. Exits and downs keep their
order with messages: each records how far the receiver's mailbox was
filled when it was sent, and waits until those messages are handled. So a
result sent just before an exit is seen before the exit.

Function families: names that take ctx are called from a handler; names
that start alph_node_ take the node and work from any thread. A bare name
sends a tag and one word, _value<T> sends one T, _bytes sends raw bytes.

Exit reasons, carried in m->arg of EXIT and DOWN. Your own reasons start
at ALPH_REASON_USER.

```mettle
export const ALPH_NORMAL: int64 = 0;    // a clean exit; links ignore it
export const ALPH_KILL: int64 = 1;      // send with alph_exit_signal to kill; cannot be trapped
export const ALPH_KILLED: int64 = 2;    // how an actor that was killed exits
export const ALPH_NOPROC: int64 = 3;    // the actor was already gone
export const ALPH_CRASHED: int64 = 4;   // a trap or fault inside the handler
export const ALPH_SHUTDOWN: int64 = 5;  // an orderly stop, from a supervisor
export const ALPH_REASON_USER: int64 = 100;
```

Tags the runtime delivers. Tags below ALPH_TAG_USER belong to the runtime;
your own tags start at ALPH_TAG_USER.

```mettle
export const ALPH_TAG_INIT: int64 = 1;     // the first message; from = parent (0 if none)
export const ALPH_TAG_EXIT: int64 = 2;     // a linked actor exited; only with alph_trap_exits on. from = it, arg = reason
export const ALPH_TAG_DOWN: int64 = 3;     // a monitored actor exited. from = it, ref = the monitor, arg = reason
export const ALPH_TAG_TIMEOUT: int64 = 4;  // a request got no reply in time. ref = the request, arg = the server
export const ALPH_TAG_CRASHED: int64 = 6;  // to a medic: its patient crashed. from = it, arg = reason
export const ALPH_TAG_USER: int64 = 100;
```

What a handler returns.

```mettle
export const ALPH_CONTINUE: int64 = 0;  // keep running
export const ALPH_STOP: int64 = 1;      // exit; return alph_stop(ctx, reason) rather than this
```

What sending returns.

```mettle
export const ALPH_SENT: int64 = 0;   // in the receiver's mailbox
export const ALPH_FULL: int64 = -1;  // the receiver's mailbox is full; nothing was sent
export const ALPH_GONE: int64 = -2;  // the receiver has exited; nothing was sent
export const ALPH_NOMEM: int64 = -3; // no memory for a large payload; nothing was sent
```

Spawn flags; combine with |.

```mettle
export const ALPH_LINK: int64 = 1;     // link the new actor to the caller
export const ALPH_MONITOR: int64 = 2;  // the caller monitors the new actor
```

### `AlphConfig`

```mettle
export struct AlphConfig {
  schedulers: int64;
  max_actors: int64;
  mailbox_size: int64;
  stack_size: int64;
}
```

How to run a node. Fill it with alph_config, then change what you need.

```text
schedulers    scheduler threads; default: one per CPU
max_actors    actors alive at once; default 65536
mailbox_size  messages a mailbox holds before senders get ALPH_FULL;
              rounded up to a power of two; default 64
stack_size    bytes of stack per scheduler, which is how deep a handler
              may call; default 1 MiB
```

### `AlphStats`

```mettle
export struct AlphStats {
  live: int64;
  spawned: int64;
  crashed: int64;
  healed: int64;
}
```

Counters from alph_node_stats.

```text
live     actors alive now
spawned  actors started since the node started
crashed  crashes that ended an actor
healed   crashes a medic repaired, unseen by anyone else
```

### `AlphNode`

```mettle
export struct AlphNode {
  procs: int64;
  capacity: int64;
  mailbox_size: int64;
  free_stack: int64;
  free_top: int64;
  free_lock: int64;
  scheds: int64;
  sched_count: int64;
  next_sched: int64;
  next_ref: int64;
  live: int64;
  spawned: int64;
  crashed: int64;
  healed: int64;
  halted: int64;
  halt_code: int64;
}
```

A node. Declare one, start it with alph_node_start, and keep it in place
until alph_node_wait returns. Its fields are the runtime's own.

### `AlphCtx`

```mettle
export struct AlphCtx {
  self: int64;
  state: rawptr;
  state_size: int64;
  node: AlphNode*;
  proc: int64;
  sched: int64;
  stop_reason: int64;
}
```

What a handler gets besides the message. Read these fields:

```text
self        this actor's pid
state       this actor's state block; cast it to your state type
state_size  its size in bytes
node        the node, for the alph_node_ functions
```

The other fields are the runtime's own. ctx is valid until the handler
returns; do not keep it.

### `alph_send`

```mettle
export fn alph_send(ctx: AlphCtx*, to: int64, tag: int64, arg: int64) -> int64
```

Sends a tag and one word to another actor.

```text
to   the receiver's pid
tag  what the message means; your tags start at ALPH_TAG_USER
arg  one word of data, read as m->arg
```

Returns ALPH_SENT, ALPH_FULL when the receiver's mailbox is full, or
ALPH_GONE when it has exited. Nothing is sent unless it returns ALPH_SENT.
Messages from one sender arrive in the order they were sent.
Thread: a handler. Outside the node, use alph_node_send.

### `alph_send_value`

```mettle
export fn alph_send_value<T>(ctx: AlphCtx*, to: int64, tag: int64, value: T*) -> int64
```

Sends one T, copied, as the payload. The receiver reads it with
alph_msg_value<T>. Returns as alph_send, plus ALPH_NOMEM when a payload
over ALPH_INLINE bytes could not be allocated.
Thread: a handler. Outside the node, use alph_node_send_value.

### `alph_send_bytes`

```mettle
export fn alph_send_bytes(ctx: AlphCtx*, to: int64, tag: int64, data: rawptr, size: int64) -> int64
```

Sends size bytes at data, copied, as the payload: for data whose length is
only known at run time. The receiver reads it with alph_msg_bytes.
Returns as alph_send_value.
Thread: a handler. Outside the node, use alph_node_send_bytes.

### `alph_node_send`

```mettle
export fn alph_node_send(node: AlphNode*, to: int64, tag: int64, arg: int64) -> int64
```

Sends a tag and one word from outside the node; m->from is 0.
Returns as alph_send. Thread: any.

### `alph_node_send_value`

```mettle
export fn alph_node_send_value<T>(node: AlphNode*, to: int64, tag: int64, value: T*) -> int64
```

Sends one T from outside the node. Returns as alph_send_value.
Thread: any.

### `alph_node_send_bytes`

```mettle
export fn alph_node_send_bytes(node: AlphNode*, to: int64, tag: int64, data: rawptr,
                               size: int64) -> int64
```

Sends size bytes from outside the node. Returns as alph_send_value.
Thread: any.

### `alph_request`

```mettle
export fn alph_request(ctx: AlphCtx*, to: int64, tag: int64, arg: int64, timeout_ms: int64) -> int64
```

Sends a request: a message whose answer comes back with the same ref.

```text
to          the server's pid
tag, arg    as alph_send
timeout_ms  how long to wait for the reply, or 0 to wait for ever
```

Returns the request's ref (above 0), or ALPH_FULL or ALPH_NOMEM when the
request was not sent. Exactly one of these then arrives, carrying the ref:

```text
the reply           tag and payload as the server sent them
ALPH_TAG_DOWN       the server exited first, or was already gone;
                    arg = its exit reason
ALPH_TAG_TIMEOUT    no reply within timeout_ms; arg = the server
```

Anything later for that ref is dropped, so a late reply never surprises
the requester. The server answers with alph_reply.
Thread: a handler.

### `alph_request_value`

```mettle
export fn alph_request_value<T>(ctx: AlphCtx*, to: int64, tag: int64, value: T*,
                                timeout_ms: int64) -> int64
```

Sends a request carrying one T. Otherwise as alph_request.
Thread: a handler.

### `alph_request_bytes`

```mettle
export fn alph_request_bytes(ctx: AlphCtx*, to: int64, tag: int64, data: rawptr, size: int64,
                             timeout_ms: int64) -> int64
```

Sends a request carrying size bytes. Otherwise as alph_request.
Thread: a handler.

### `alph_reply`

```mettle
export fn alph_reply(ctx: AlphCtx*, request: AlphMsg*, tag: int64, arg: int64) -> int64
```

Answers a request with a tag and one word.

```text
request  the request message as the handler received it
```

The reply goes to the requester with the request's ref. Returns as
alph_send. A requester that already timed out or exited drops it.
Thread: a handler.

### `alph_reply_value`

```mettle
export fn alph_reply_value<T>(ctx: AlphCtx*, request: AlphMsg*, tag: int64, value: T*) -> int64
```

Answers a request with one T. Otherwise as alph_reply.
Thread: a handler.

### `alph_reply_bytes`

```mettle
export fn alph_reply_bytes(ctx: AlphCtx*, request: AlphMsg*, tag: int64, data: rawptr,
                           size: int64) -> int64
```

Answers a request with size bytes. Otherwise as alph_reply.
Thread: a handler.

### `alph_link`

```mettle
export fn alph_link(ctx: AlphCtx*, pid: int64)
```

Links this actor with pid, both ways: when either exits with a reason
other than ALPH_NORMAL, the other exits with the same reason, or gets an
ALPH_TAG_EXIT message if it traps exits. Linking to a gone actor acts as
if it had just exited with ALPH_NOPROC. Linking twice is one link.
Thread: a handler.

### `alph_unlink`

```mettle
export fn alph_unlink(ctx: AlphCtx*, pid: int64)
```

Removes the link with pid, both ways. Does nothing if there is none.
Thread: a handler.

### `alph_monitor`

```mettle
export fn alph_monitor(ctx: AlphCtx*, pid: int64) -> int64
```

Watches pid, one way. When it exits, an ALPH_TAG_DOWN message arrives with
the returned ref and its exit reason in arg; if it is already gone, DOWN
arrives with ALPH_NOPROC. Each call is a separate monitor.
Returns the monitor's ref. Thread: a handler.

### `alph_demonitor`

```mettle
export fn alph_demonitor(ctx: AlphCtx*, ref: int64)
```

Stops a monitor. A DOWN for it that is already on its way is dropped.

```text
ref  from alph_monitor
```

Thread: a handler.

### `alph_trap_exits`

```mettle
export fn alph_trap_exits(ctx: AlphCtx*, on: bool)
```

With on, exits of linked actors arrive as ALPH_TAG_EXIT messages (from =
the linked actor, arg = its reason) instead of ending this actor. Kills
still end it. Off by default. Thread: a handler.

### `alph_exit_signal`

```mettle
export fn alph_exit_signal(ctx: AlphCtx*, pid: int64, reason: int64)
```

Sends an exit signal to pid, as erlang:exit/2. The target exits with
reason unless it traps exits, in which case it gets an ALPH_TAG_EXIT
message. ALPH_KILL cannot be trapped: the target exits with ALPH_KILLED.
ALPH_NORMAL is ignored by an actor that does not trap exits.
Thread: a handler. Outside the node, use alph_node_exit_signal.

### `alph_node_exit_signal`

```mettle
export fn alph_node_exit_signal(node: AlphNode*, pid: int64, reason: int64)
```

Sends an exit signal from outside the node, as alph_exit_signal; the
message's from is 0. Thread: any.

### `alph_stop`

```mettle
export fn alph_stop(ctx: AlphCtx*, reason: int64) -> int64
```

Ends this actor once the handler returns: `return alph_stop(ctx, reason);`
Its links and monitors see reason. Returns ALPH_STOP. Thread: a handler.

### `alph_parent`

```mettle
export fn alph_parent(ctx: AlphCtx*) -> int64
```

The pid of the actor that spawned this one, or 0 when the node did.
Thread: a handler.

### `alph_send_after`

```mettle
export fn alph_send_after(ctx: AlphCtx*, ms: int64, to: int64, tag: int64, arg: int64)
```

Sends a tag and one word to `to` after ms milliseconds. It cannot be
cancelled; use alph_start_timer for that. Like every signal it is never
dropped for a full mailbox. Thread: a handler.

### `alph_start_timer`

```mettle
export fn alph_start_timer(ctx: AlphCtx*, ms: int64, tag: int64, arg: int64) -> int64
```

Starts a timer for this actor: after ms milliseconds a message with tag
and arg arrives, its ref set to the returned value, unless
alph_cancel_timer is called first. Returns the timer's ref.
Thread: a handler.

### `alph_cancel_timer`

```mettle
export fn alph_cancel_timer(ctx: AlphCtx*, ref: int64)
```

Cancels a timer from alph_start_timer. Its message never arrives, even if
it is already due. Cancelling twice, or after it arrived, does nothing.
Thread: a handler.

### `alph_alloc`

```mettle
export fn alph_alloc(ctx: AlphCtx*, size: int64) -> rawptr
```

Allocates size bytes that live until this actor exits, then are freed for
it. Use it for anything the state points to. Returns 0 when out of memory.
The memory is not zeroed. Thread: a handler.

### `alph_spawn`

```mettle
export fn alph_spawn(ctx: AlphCtx*, flags: int64,
                     handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor with no state.

```text
flags    0, or ALPH_LINK and/or ALPH_MONITOR. Both are set up before the
         new actor runs, so even a crash in its INIT reaches the caller.
         With ALPH_MONITOR, its DOWN arrives with from = the new pid.
handler  the new actor's handler; its first message is ALPH_TAG_INIT
```

Returns the new pid, or 0 when the node is full (max_actors) or out of
memory. Thread: a handler. Outside the node, use alph_node_spawn.

### `alph_spawn_value`

```mettle
export fn alph_spawn_value<T>(ctx: AlphCtx*, flags: int64, state: T*,
                              handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor whose state starts as a copy of *state. The handler reads
it as (T*)ctx->state. Otherwise as alph_spawn. Thread: a handler.

### `alph_spawn_bytes`

```mettle
export fn alph_spawn_bytes(ctx: AlphCtx*, flags: int64, state: rawptr, size: int64,
                           handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor whose state starts as a copy of size bytes at state.
Otherwise as alph_spawn. Thread: a handler.

### `alph_node_spawn`

```mettle
export fn alph_node_spawn(node: AlphNode*,
                          handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor with no state from outside the node. It has no parent: its
INIT comes from 0 and nothing is linked to it. Returns the new pid, or 0.
Thread: any.

### `alph_node_spawn_value`

```mettle
export fn alph_node_spawn_value<T>(node: AlphNode*, state: T*,
                                   handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor whose state starts as a copy of *state, from outside the
node. Otherwise as alph_node_spawn. Thread: any.

### `alph_node_spawn_bytes`

```mettle
export fn alph_node_spawn_bytes(node: AlphNode*, state: rawptr, size: int64,
                                handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor whose state starts as a copy of size bytes at state, from
outside the node. Otherwise as alph_node_spawn. Thread: any.

### `alph_spawn_medic`

```mettle
export fn alph_spawn_medic(ctx: AlphCtx*, state: rawptr, size: int64,
                           handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns a medic for the calling actor, which becomes its patient. When the
patient crashes, the medic gets ALPH_TAG_CRASHED (from = the patient,
arg = the reason) and must answer with one of alph_patient_resume, _reset
or _fail. If a live medic is attached already it is kept, since a reset
patient runs INIT again.

```text
state, size  the medic's initial state, copied
handler      the medic's handler
```

Returns the medic's pid, or 0. Thread: the patient's handler.

### `alph_patient_state`

```mettle
export fn alph_patient_state(ctx: AlphCtx*, pid: int64, size: int64*) -> rawptr
```

For a medic: the crashed patient's state as the crash left it, which the
medic may change. *size receives its size. Valid until the patient is
resumed, reset or failed. Returns 0 when pid is not this medic's crashed
patient. Thread: the medic's handler.

### `alph_patient_message`

```mettle
export fn alph_patient_message(ctx: AlphCtx*, pid: int64) -> AlphMsg*
```

For a medic: the message the patient was handling when it crashed. Valid
until the patient is resumed, reset or failed. Returns 0 when pid is not
this medic's crashed patient. Thread: the medic's handler.

### `alph_patient_resume`

```mettle
export fn alph_patient_resume(ctx: AlphCtx*, pid: int64, retry: bool) -> bool
```

For a medic: lets the patient go on with its state as it is now. With
retry, the message it crashed on is handled again first; without, that
message is dropped. Returns false when pid is not this medic's crashed
patient. Thread: the medic's handler.

### `alph_patient_reset`

```mettle
export fn alph_patient_reset(ctx: AlphCtx*, pid: int64, state: rawptr, size: int64) -> bool
```

For a medic: starts the patient over from a copy of size bytes at state.
What it allocated is freed, exits are no longer trapped, and it gets INIT
again. Its pid, links, monitors and mailbox stay. Returns false when pid
is not this medic's crashed patient. Thread: the medic's handler.

### `alph_patient_fail`

```mettle
export fn alph_patient_fail(ctx: AlphCtx*, pid: int64, reason: int64) -> bool
```

For a medic: gives up. The patient exits with reason, which its links,
monitors and supervisor see; passive healing takes over. Returns false
when pid is not this medic's crashed patient. Thread: the medic's handler.

### `alph_config`

```mettle
export fn alph_config(cfg: AlphConfig*)
```

Fills cfg with the defaults: one scheduler per CPU, 65536 actors, 64
messages per mailbox, 1 MiB of stack per scheduler. Thread: any.

### `alph_node_start`

```mettle
export fn alph_node_start(node: AlphNode*, cfg: AlphConfig*) -> bool
```

Starts a node: its schedulers begin running and actors can be spawned.

```text
node  storage for the node; keep it in place until alph_node_wait returns
cfg   from alph_config, changed as needed; read here and not kept
```

Returns false when cfg is out of range (no schedulers, no actors) or
memory or threads run out.
Thread: any, once per node.

### `alph_node_halt`

```mettle
export fn alph_node_halt(node: AlphNode*, code: int64)
```

Stops the node: each scheduler finishes the actor it is running and
exits, and alph_node_wait returns code. Actors still alive are not told.
Thread: any. From a handler, alph_halt is the same.

### `alph_halt`

```mettle
export fn alph_halt(ctx: AlphCtx*, code: int64)
```

Stops the node, as alph_node_halt. The calling handler still returns
normally. Thread: a handler.

### `alph_node_wait`

```mettle
export fn alph_node_wait(node: AlphNode*) -> int64
```

Waits until the node is halted and its schedulers have stopped. Returns
the code given to alph_halt or alph_node_halt.
Thread: any thread that is not one of the node's schedulers, typically
main, once.

### `alph_node_stats`

```mettle
export fn alph_node_stats(node: AlphNode*, stats: AlphStats*)
```

Copies the node's counters into *stats. Counters from different threads
are read one by one, so they may be a moment apart. Thread: any.

## alph/core/mailbox

Messages, and the bounded mailbox that holds them.

The mailbox is Vyukov's bounded queue: each cell carries a sequence number,
producers claim a position with one CAS, and the single consumer reads in
order. Messages from one sender arrive in the order they were sent. A full
mailbox refuses the message instead of growing, so overload shows up at
the sender as ALPH_FULL rather than as memory growth.

Payloads up to this many bytes travel inside the message. Larger ones cost
one allocation and are freed after the handler returns.

```mettle
export const ALPH_INLINE: int64 = 40;
```

### `AlphMsg`

```mettle
export struct AlphMsg {
  tag: int64;
  from: int64;
  to: int64;
  ref: int64;
  arg: int64;
  flags: int64;
  size: int64;
  heap: int64;      // payload address when size > ALPH_INLINE, else 0
  data: uint8[40];  // payload when size <= ALPH_INLINE
}
```

A message, as a handler receives it. Read the fields directly:

```text
tag    what the message means. Tags below ALPH_TAG_USER (100) belong to
       the runtime; pick your own from ALPH_TAG_USER up
from   the sender's pid, or 0 when sent from outside the node
to     the receiver's pid
ref    the request this message answers (replies, DOWN, TIMEOUT), else 0
arg    one word of data; the exit reason on EXIT and DOWN
size   payload bytes, 0 when there is none
```

The payload is read with alph_msg_value or alph_msg_bytes. It is valid
until the handler returns; copy what you keep.

### `alph_msg_value`

```mettle
export fn alph_msg_value<T>(m: AlphMsg*, out: T*) -> bool
```

Copies the payload into *out when it holds exactly one T.

```text
m    the message
out  where the T goes
```

Returns false, leaving *out alone, when the payload is not sizeof(T)
bytes: usually a tag sent with a different type than the receiver expects.
Thread: the handler that received m.

### `alph_msg_bytes`

```mettle
export fn alph_msg_bytes(m: AlphMsg*, size: int64*) -> rawptr
```

The payload's address. If size is not 0, *size receives its length in
bytes. Returns the address even for an empty payload; check the size.
Thread: the handler that received m.

### `AlphMailbox`

```mettle
export struct AlphMailbox {
  cells: int64;  // AlphCell array, allocated once and kept for reuse
  mask: int64;
  enq: int64;    // next position to claim; producers
  deq: int64;    // next position to read; the consumer
}
```

A bounded multi-producer, single-consumer queue of messages. Internal to
the runtime; actors never touch it.

### `alph_mailbox_init`

```mettle
export fn alph_mailbox_init(mb: AlphMailbox*, capacity: int64) -> bool
```

Allocates room for capacity messages, which must be a power of two.
Returns false when out of memory. Thread: any, before the mailbox is used.

### `alph_mailbox_push`

```mettle
export fn alph_mailbox_push(mb: AlphMailbox*, m: AlphMsg*) -> bool
```

Copies *m into the mailbox. Returns false when it is full.
Thread: any.

### `alph_mailbox_pop`

```mettle
export fn alph_mailbox_pop(mb: AlphMailbox*, out: AlphMsg*) -> bool
```

Moves the oldest message into *out. Returns false when there is none, or
when the oldest is still being written by its sender.
Thread: the mailbox's one consumer.

## alph/heal/supervisor

Passive healing, the OTP way.

A supervisor is an actor that starts its children in order and restarts
them when they exit, by strategy:

```text
ALPH_ONE_FOR_ONE   restart only the child that exited
ALPH_ONE_FOR_ALL   stop every other child, then restart all of them
ALPH_REST_FOR_ONE  stop the children started after it, then restart it
                   and them
```

and by each child's restart type:

```text
ALPH_PERMANENT  always restarted
ALPH_TRANSIENT  restarted unless it exited with ALPH_NORMAL or ALPH_SHUTDOWN
ALPH_TEMPORARY  never restarted
```

A restarted child is a new actor with a new pid and its initial state.
More than max_restarts restarts within period_ms and the supervisor gives
up: it stops every child and exits with ALPH_SHUTDOWN, so its own
supervisor sees the failure. Children stop in reverse start order: an
ALPH_SHUTDOWN exit signal, then ALPH_KILL after the child's shutdown_ms.

Unlike OTP, restarts can back off: consecutive restarts wait backoff_ms,
doubling up to backoff_max_ms, and a quiet period_ms resets the streak.

```text
var spec: AlphSupSpec;
alph_sup_init(&spec, ALPH_ONE_FOR_ONE);
alph_sup_add_value<Cache>(&spec, &cache, &cache_handler);
var db: AlphChildSpec* = alph_sup_add(&spec, &db_handler);
db->restart = ALPH_TRANSIENT;
alph_spawn_sup(ctx, &spec);
```

Restart strategies, for AlphSupSpec.strategy; described at the top of
this module.

```mettle
export const ALPH_ONE_FOR_ONE: int64 = 0;
export const ALPH_ONE_FOR_ALL: int64 = 1;
export const ALPH_REST_FOR_ONE: int64 = 2;
```

Restart types, for AlphChildSpec.restart; described at the top of this
module.

```mettle
export const ALPH_PERMANENT: int64 = 0;
export const ALPH_TRANSIENT: int64 = 1;
export const ALPH_TEMPORARY: int64 = 2;
```

Children one supervisor can hold. Nest supervisors for more.

```mettle
export const ALPH_SUP_MAX_CHILDREN: int64 = 16;
```

The tag a sync_start child acknowledges with, through alph_sup_ack.

```mettle
export const ALPH_TAG_ACK: int64 = 10;
```

### `AlphChildSpec`

```mettle
export struct AlphChildSpec {
  restart: int64;
  shutdown_ms: int64;
  sync_start: bool;
  state: rawptr;
  state_size: int64;
  state_at: int64;
  handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm;
}
```

One child of a supervisor, as alph_sup_add returns it. Change these:

```text
restart      ALPH_PERMANENT (default), ALPH_TRANSIENT or ALPH_TEMPORARY
shutdown_ms  how long it gets to stop before it is killed; 0 kills it at
             once. Default 5000
sync_start   when true, the next child starts only after this one calls
             alph_sup_ack from its INIT handler. Default false
```

The other fields are set by alph_sup_add.

### `AlphSupSpec`

```mettle
export struct AlphSupSpec {
  strategy: int64;
  max_restarts: int64;
  period_ms: int64;
  backoff_ms: int64;
  backoff_max_ms: int64;
  start_timeout_ms: int64;
  count: int64;
  children: AlphChildSpec[16];
}
```

A supervisor's definition. Start it with alph_sup_init, add children with
alph_sup_add, change these if needed, then spawn it:

```text
strategy          ALPH_ONE_FOR_ONE, ALPH_ONE_FOR_ALL or ALPH_REST_FOR_ONE
max_restarts      restarts allowed within period_ms before giving up;
                  default 1, as OTP (at most 63)
period_ms         default 5000
backoff_ms        wait before the first of consecutive restarts; 0
                  (default) restarts at once
backoff_max_ms    cap on the doubling backoff; 0 means no cap
start_timeout_ms  how long a sync_start child has to ack; default 5000
```

count and children are filled by alph_sup_add.

### `alph_sup_init`

```mettle
export fn alph_sup_init(spec: AlphSupSpec*, strategy: int64)
```

Starts a supervisor definition with no children and OTP's defaults: at
most 1 restart in 5000 ms, no backoff, 5000 ms for a child to ack.
Thread: any.

### `alph_sup_add_bytes`

```mettle
export fn alph_sup_add_bytes(spec: AlphSupSpec*, state: rawptr, size: int64,
                             handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> AlphChildSpec*
```

Adds a child whose state starts as a copy of size bytes at state on every
start. The bytes are copied when the supervisor is spawned, so they need
not outlive that call. Returns the child spec, with the defaults
described at AlphChildSpec, or 0 when the supervisor already has
ALPH_SUP_MAX_CHILDREN children. Children start in the order added.
Thread: any.

### `alph_sup_add_value`

```mettle
export fn alph_sup_add_value<T>(spec: AlphSupSpec*, state: T*,
                                handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> AlphChildSpec*
```

Adds a child whose state starts as a copy of *state. Otherwise as
alph_sup_add_bytes. Thread: any.

### `alph_sup_add`

```mettle
export fn alph_sup_add(spec: AlphSupSpec*,
                       handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> AlphChildSpec*
```

Adds a child with no state. Otherwise as alph_sup_add_bytes. Thread: any.

### `alph_sup_ack`

```mettle
export fn alph_sup_ack(ctx: AlphCtx*, init: AlphMsg*)
```

Tells the supervisor this child finished starting. Only for children with
sync_start; call it from the INIT handler, passing the INIT message.
Thread: the child's handler.

### `alph_spawn_sup`

```mettle
export fn alph_spawn_sup(ctx: AlphCtx*, spec: AlphSupSpec*) -> int64
```

Spawns a supervisor linked to the calling actor, which becomes its parent:
if the parent exits, the supervisor stops its children and exits too.

```text
spec  the definition; copied, along with every child's initial state
```

Returns the supervisor's pid, or 0 when the node is full or out of
memory. Thread: a handler. Outside the node, use alph_node_spawn_sup.

### `alph_node_spawn_sup`

```mettle
export fn alph_node_spawn_sup(node: AlphNode*, spec: AlphSupSpec*) -> int64
```

Spawns a top-level supervisor with no parent. Stop it with
alph_node_exit_signal(node, pid, ALPH_SHUTDOWN). Otherwise as
alph_spawn_sup. Thread: any.

## alph/heal/medic

Proactive healing.

Passive healing is a supervisor: the actor crashes, exits, and is started
again with a new pid. Proactive healing is a medic: a small actor attached
to a bigger one. When the bigger one crashes, the runtime holds it in place
(same pid, links, monitors and mailbox; new messages still queue) and the
medic's repair function sees the crash reason, the state as the crash left
it, and the message being handled. It answers with one of:

```text
ALPH_HEAL_RESUME  go on with the state as repaired; drop that message
ALPH_HEAL_RETRY   go on, and handle that message again
ALPH_HEAL_RESET   start over from the state the actor had when the medic
                  was attached; INIT runs again
ALPH_HEAL_FAIL    give up: the actor exits and its supervisor takes over
```

Nobody else sees a repaired crash. More than max_repairs within period_ms
counts as ALPH_HEAL_FAIL. If the medic itself dies, the actor runs on
without one, and its next crash is handled passively.

Attach from the actor's INIT handler, so a restarted actor gets a medic
too:

```text
fn repair(ctx: AlphCtx*, r: AlphRepair*) -> int64 {
  var a: Account* = (Account*)r->state;
  if (a->balance < 0) { a->balance = a->last_good; return ALPH_HEAL_RESUME; }
  return ALPH_HEAL_FAIL;
}
```

```text
var spec: AlphMedicSpec;
alph_medic_init(&spec, &repair);
alph_attach_medic(ctx, &spec);
```

What a repair function returns.

```mettle
export const ALPH_HEAL_RESUME: int64 = 0;
export const ALPH_HEAL_RETRY: int64 = 1;
export const ALPH_HEAL_RESET: int64 = 2;
export const ALPH_HEAL_FAIL: int64 = 3;
```

### `AlphRepair`

```mettle
export struct AlphRepair {
  patient: int64;
  reason: int64;
  state: rawptr;
  state_size: int64;
  message: AlphMsg*;
  repairs: int64;
}
```

What a repair function is given about one crash.

```text
patient     the crashed actor's pid
reason      why it crashed; ALPH_CRASHED
state       its state block as the crash left it; repair may change it
state_size  the block's size
message     the message it was handling (tag, from, arg, payload);
            read the payload with alph_msg_value or alph_msg_bytes
repairs     repairs within the current period, this one included
```

Everything here is valid only during the repair call.

### `AlphMedicSpec`

```mettle
export struct AlphMedicSpec {
  max_repairs: int64;
  period_ms: int64;
  repair: fn(AlphCtx*, AlphRepair*) -> int64 with alloc, syscall, asm;
}
```

A medic's definition. Fill it with alph_medic_init, then change:

```text
max_repairs  repairs allowed within period_ms; one more counts as
             ALPH_HEAL_FAIL. Default 3 (at most 63)
period_ms    default 10000
```

repair is the function the medic calls on each crash. It runs in the
medic, so it may use ctx to send messages; it must return one of the
ALPH_HEAL_ values, and anything else counts as ALPH_HEAL_FAIL.

### `alph_medic_init`

```mettle
export fn alph_medic_init(spec: AlphMedicSpec*,
                          repair: fn(AlphCtx*, AlphRepair*) -> int64 with alloc, syscall, asm)
```

Fills spec with the defaults (3 repairs per 10000 ms) and the repair
function. Thread: any.

### `alph_attach_medic`

```mettle
export fn alph_attach_medic(ctx: AlphCtx*, spec: AlphMedicSpec*) -> int64
```

Attaches a medic to the calling actor. The actor's state right now becomes
the state ALPH_HEAL_RESET returns to, so attach at the end of INIT. While
a medic is alive, attaching again keeps it: a reset actor runs INIT again
without gaining a second medic.

```text
spec  from alph_medic_init; copied
```

Returns the medic's pid, or 0 when the node is full or out of memory.
Thread: the actor's own handler.

## alph/sys/atomic

64-bit atomics on x86-64.

Each operation is a @naked export function, so it runs exactly the
instructions written here, and the optimizer sees an opaque call that it
cannot move memory accesses across. x86-64 is TSO: a plain load already has
acquire order and a plain store has release order. Sequential consistency
needs a locked instruction or mfence, which store_sc, swap, cas and add use.
Pointers are passed as int64.

### `alph_atomic_load`

```mettle
export fn alph_atomic_load(p: int64*) -> int64
```

Reads *p. Acquire order: later reads and writes stay after it.
Thread: any.

### `alph_atomic_store`

```mettle
export fn alph_atomic_store(p: int64*, v: int64)
```

Writes v to *p. Release order: earlier reads and writes stay before it.
A later load may still pass it; use alph_atomic_store_sc when that matters.
Thread: any.

### `alph_atomic_store_sc`

```mettle
export fn alph_atomic_store_sc(p: int64*, v: int64)
```

Writes v to *p, sequentially consistent: no later load can be reordered
before it. Thread: any.

### `alph_atomic_swap`

```mettle
export fn alph_atomic_swap(p: int64*, v: int64) -> int64
```

Stores v in *p and returns the value it replaced. Sequentially consistent.
Thread: any.

### `alph_atomic_cas`

```mettle
export fn alph_atomic_cas(p: int64*, expected: int64, desired: int64) -> int64
```

Compare and swap: stores desired in *p if *p equals expected. Returns the
value *p held before, so the swap happened exactly when the result equals
expected. Sequentially consistent. Thread: any.

### `alph_atomic_add`

```mettle
export fn alph_atomic_add(p: int64*, delta: int64) -> int64
```

Adds delta to *p and returns the value from before the add. Sequentially
consistent. Thread: any.

### `alph_atomic_fence`

```mettle
export fn alph_atomic_fence()
```

A full barrier: no load or store moves across it in either direction.
Thread: any.

### `alph_cpu_relax`

```mettle
export fn alph_cpu_relax()
```

A hint inside spin loops: lets the sibling hyperthread run and saves
power. It has no effect on memory. Thread: any.

## alph/sys/clock

Monotonic time and futex parking.

### `alph_now_ns`

```mettle
export fn alph_now_ns() -> int64
```

Monotonic time in nanoseconds. Only differences between two readings mean
anything; it never goes backwards.
Thread: any.

### `alph_now_ms`

```mettle
export fn alph_now_ms() -> int64
```

Monotonic time in milliseconds, as alph_now_ns.
Thread: any.

### `alph_futex_wait`

```mettle
export fn alph_futex_wait(word: int64*, expected: int64, timeout_ns: int64)
```

Sleeps while the low 32 bits of *word equal expected.

```text
word        the futex word; only its low 32 bits are compared
expected    the value that means "keep sleeping"
timeout_ns  longest sleep in nanoseconds, or a negative number for none
```

Returns on a wake, a timeout, a signal, or because *word already differs,
so callers re-check their condition in a loop.
Thread: any. Used by the schedulers to park.

### `alph_futex_wake`

```mettle
export fn alph_futex_wake(word: int64*, count: int64)
```

Wakes up to count threads sleeping in alph_futex_wait on word.
Thread: any.

## alph/sys/thread

Threads that survive their own crashes.

Each thread gets a guard page at the bottom of its stack, its own alternate
signal stack, and a recovery registration covering its stack. A stack
overflow then faults on the guard page, the fault handler runs on the
alternate stack, and alph/sys/recover can resume the thread. The node runs
one of these per scheduler.

### `AlphThread`

```mettle
export struct AlphThread {
  body: fn(int64) -> int64;
  arg: int64;
  stack_size: int64;
  guard: int64;
  altstack: int64;
  result: int64;
  recover: AlphRecover;
}
```

A thread started by alph_thread_start. Keep it alive and in place until
alph_thread_join returns; the thread reads and writes it.

```text
result   what body returned, valid after alph_thread_join
recover  the thread's recovery registration, for alph_recover_save
```

### `alph_thread_start`

```mettle
export fn alph_thread_start(t: AlphThread*, body: fn(int64) -> int64, arg: int64,
                            stack_size: int64) -> int64
```

Starts body(arg) on a new thread.

```text
t           storage for the thread; it belongs to the thread until joined
body        the thread's work; its return value lands in t->result
arg         passed to body
stack_size  bytes of stack, at least 64 KiB (smaller values are raised)
```

Returns the thread's handle, or 0 when it could not start. Keep the handle:
the thread owns t, so the handle is what the caller holds on to.
Thread: any.

### `alph_thread_join`

```mettle
export fn alph_thread_join(handle: int64, t: AlphThread*) -> int64
```

Waits for a thread to finish and returns what its body returned.

```text
handle  from alph_thread_start
t       the same storage given to alph_thread_start
```

Thread: any thread except the one being joined.

### `alph_cpu_count`

```mettle
export fn alph_cpu_count() -> int64
```

The number of CPUs this process may run on, at least 1. The node uses it
as the default scheduler count.
Thread: any.

## alph/sys/recover

Recovery points that survive traps and faults (x86-64 Linux).

Mettle's runtime asks a hook where to resume before it ends the process on
a trap (bounds, divide, null) or a fault signal (SIGSEGV, SIGFPE, ...). The
hook is mettle_crash_set_live_recovery, built for `mettle live`. alph
registers its own callbacks there, so a crash inside an actor resumes the
scheduler instead of killing the node.

Use, in the frame that must survive (the scheduler loop):

```text
alph_recover_arm(r);
if (alph_recover_save(&r->regs[0]) != 0) {
  // a crash below resumed here; locals kept in registers may be stale,
  // so read state back from memory
} else {
  run_the_handler();
}
alph_recover_disarm(r);
```

Programs must be built with -s: without it the compiler emits inserted
traps as an inline exit that never reaches the hook. --safe is not
supported: the jump does not unwind its shadow call stack.

### `AlphRecover`

```mettle
export struct AlphRecover {
  // rbx, rbp, (unused), (unused), r12, r13, r14, r15, rsp, rip: the layout
  // the runtime's signal path restores (crash_handler.c).
  regs: int64[10];
  stack_lo: int64;
  stack_hi: int64;
  armed: int64;
  crashes: int64;
}
```

One thread's recovery point. Register it with alph_recover_register,
then save into regs with alph_recover_save.

```text
crashes  how many crashes resumed this point so far
```

### `alph_recover_save`

```mettle
export fn alph_recover_save(regs: int64*) -> int64
```

Saves the callee-saved registers, the stack pointer and the return address
into regs (an AlphRecover's regs). Returns 0 now, and returns 1 a second
time when a crash resumes here. Arm the AlphRecover first, and keep the
calling frame alive while the protected code runs.
Thread: the thread that owns regs.

### `alph_recover_resume`

```mettle
export fn alph_recover_resume(regs: int64)
```

Jumps back to the point saved in regs, where alph_recover_save returns 1.
Called by alph_recover_hook_jump; do not call it with a frame that has
returned. Thread: the thread that saved regs.

### `alph_recover_hook_point`

```mettle
export fn alph_recover_hook_point(stack: int64) -> int64
```

Called by the Mettle runtime on a crash, not by programs. Returns the armed
recovery point of the thread whose stack holds `stack`, or 0 to let the
crash end the process. It runs inside a signal handler, so it only reads.

### `alph_recover_hook_wait`

```mettle
export fn alph_recover_hook_wait(slot: int64) -> int64
```

Called by the Mettle runtime, not by programs: decides to resume. alph
always resumes at once, disarming the point and counting the crash. regs
is the first field, so the slot is the AlphRecover itself.

### `alph_recover_hook_jump`

```mettle
export fn alph_recover_hook_jump(slot: int64)
```

Called by the Mettle runtime on the trap path, not by programs: jumps to
the recovery point. The signal path restores the registers itself.

### `alph_recover_register`

```mettle
export fn alph_recover_register(r: AlphRecover*, lo: int64, hi: int64) -> bool
```

Registers r as the recovery point for the thread whose stack is [lo, hi),
and installs alph's crash hook on first use.

```text
r       stays registered until alph_recover_unregister; keep it in place
lo, hi  the stack range, lowest and one past highest address
```

Returns false when the table of 256 registrations is full. Slots are not
reused. Thread: any.

### `alph_recover_register_here`

```mettle
export fn alph_recover_register_here(r: AlphRecover*, below: int64, above: int64) -> bool
```

Registers the calling thread when alph did not create it, such as the
main thread. The stack range is taken around the caller's frame:

```text
below  bytes of stack below the caller's frame (how deep it may grow)
above  bytes above it (the frames that called it)
```

Returns false when the table is full. Thread: the thread being registered.

### `alph_recover_unregister`

```mettle
export fn alph_recover_unregister(r: AlphRecover*)
```

Stops the crash hook from matching r. Its table slot is not reused.
Thread: any.

### `alph_recover_arm`

```mettle
export fn alph_recover_arm(r: AlphRecover*)
```

Arms r: a crash on its thread now resumes at the last alph_recover_save.
Arm before saving. Thread: the thread that owns r.

### `alph_recover_disarm`

```mettle
export fn alph_recover_disarm(r: AlphRecover*)
```

Disarms r: a crash on its thread ends the process again. A resumed crash
disarms it already. Thread: the thread that owns r.

## alph/sys/linux

The Linux x86-64 system call numbers and flags alph uses.

Every raw syscall in the runtime goes through these names, so a port to
another platform starts here.

System call numbers.

```mettle
export const ALPH_SYS_MMAP: int64 = 9;
export const ALPH_SYS_MPROTECT: int64 = 10;
export const ALPH_SYS_MUNMAP: int64 = 11;
export const ALPH_SYS_SIGALTSTACK: int64 = 131;
export const ALPH_SYS_FUTEX: int64 = 202;
export const ALPH_SYS_SCHED_GETAFFINITY: int64 = 204;
export const ALPH_SYS_CLOCK_GETTIME: int64 = 228;
```

Flags for those calls.

```mettle
export const ALPH_PROT_NONE: int64 = 0;
export const ALPH_PROT_READ_WRITE: int64 = 3;
export const ALPH_MAP_PRIVATE_ANONYMOUS: int64 = 0x22;
export const ALPH_SS_DISABLE: int64 = 2;
export const ALPH_CLOCK_MONOTONIC: int64 = 1;
export const ALPH_FUTEX_WAIT_PRIVATE: int64 = 128;
export const ALPH_FUTEX_WAKE_PRIVATE: int64 = 129;
```

The memory page size, for guard pages.

```mettle
export const ALPH_PAGE_SIZE: int64 = 4096;
```

## alph/core/queue

Intrusive multi-producer, single-consumer queue (Vyukov).

A node is any struct whose first field is `next: int64`. Push is wait-free
and may run on any thread. Pop runs only on the queue's one consumer. The
node uses it for run queues and signal queues; actors never touch it.

### `AlphQueue`

```mettle
export struct AlphQueue {
  head: int64;  // last pushed node; producers swap it
  tail: int64;  // next node to pop; consumer only
  stub: int64;  // a node made of just a next field
}
```

A queue holds the address of its own stub, so it must not move after
alph_queue_init.

### `alph_queue_init`

```mettle
export fn alph_queue_init(q: AlphQueue*)
```

Makes q empty. Thread: any, before q is used.

### `alph_queue_push`

```mettle
export fn alph_queue_push(q: AlphQueue*, node: rawptr)
```

Appends node, whose first field must be `next: int64`. The queue keeps the
node until it is popped; do not push it again before then. Thread: any.

### `alph_queue_pop`

```mettle
export fn alph_queue_pop(q: AlphQueue*) -> int64
```

Removes and returns the oldest node, or 0 when the queue is empty. It also
returns 0 while a push is between its two steps; every pusher wakes the
consumer after it finishes, so treating that 0 as empty loses nothing.
Thread: the queue's one consumer.
