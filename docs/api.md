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
export const ALPH_TAG_IO: int64 = 7;       // an armed handle is ready. ref = the handle, arg = ALPH_IO_ bits
export const ALPH_TAG_IO_GIVEN: int64 = 8; // a handle was handed to this actor. ref = the handle, from = the giver
export const ALPH_TAG_PROC_EXIT: int64 = 9; // a child process ended. ref = its handle, arg = exit code, or 128 + signal
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

What a handle is ready for, in alph_io_arm and in m->arg of ALPH_TAG_IO.

```mettle
export const ALPH_IO_IN: int64 = 1;    // readable, or a listener has a connection waiting
export const ALPH_IO_OUT: int64 = 4;   // writable, or a connect finished (check alph_io_error)
export const ALPH_IO_ERR: int64 = 8;   // an error is pending; only reported, never armed
export const ALPH_IO_HUP: int64 = 16;  // the other end hung up; only reported, never armed
```

What alph_io_read, alph_io_write and alph_tcp_accept return when they
would have to wait: arm the handle and try again on ALPH_TAG_IO.

```mettle
export const ALPH_IO_AGAIN: int64 = -11;
```

Flags for alph_tcp_listen.

```mettle
export const ALPH_TCP_REUSEPORT: int64 = 1;  // several listeners share the port; the kernel spreads connections
```

Spawn flags; combine with |.

```mettle
export const ALPH_LINK: int64 = 1;     // link the new actor to the caller
export const ALPH_MONITOR: int64 = 2;  // the caller monitors the new actor
export const ALPH_BOUND: int64 = 4;    // the new actor gets a thread of its own and may block
```

### `AlphConfig`

```mettle
export struct AlphConfig {
  schedulers: int64;
  max_actors: int64;
  mailbox_size: int64;
  stack_size: int64;
  heap_limit: int64;
  max_handles: int64;
  signals: int64;
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
heap_limit    bytes one actor's heap may hold, state included; past it
              alph_alloc returns 0 and spawning fails. 0 (default) is
              no limit
max_handles   IO handles open at once; default 65536
signals       OS signals the node takes over, as bits (1 << ALPH_SIGINT)
              and so on; default 0. See alph_node_signals
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
  heap_limit: int64;
  stack_size: int64;
  bound_list: int64;    // every bound scheduler, for alph_node_wait
  bound_lock: int64;
  ios: int64;           // AlphIoSlot table
  io_capacity: int64;
  io_free_stack: int64;
  io_free_top: int64;
  io_lock: int64;
  names: int64;         // AlphVec of AlphEntry*: registered names
  groups: int64;        // AlphVec of AlphEntry*: process groups
  names_lock: int64;    // guards names, groups and every group's members
  env: int64;           // the environment the process started with, for children
  env_lock: int64;
  roots: int64;         // AlphVec of top-level pids, in spawn order
  roots_lock: int64;
  shutting: int64;      // alph_node_shutdown has begun
  sigfd: int64;         // signalfd for cfg.signals, on scheduler 0, or -1
  sig_pid: int64;       // who gets OS signals, or 0 to shut down
  sig_tag: int64;
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
the requester. alph_demonitor(ctx, ref) gives up on a request: nothing
for that ref arrives after it. The server answers with alph_reply.
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

### `alph_reply_full`

```mettle
export fn alph_reply_full(ctx: AlphCtx*, request: AlphMsg*, tag: int64, arg: int64, data: rawptr,
                          size: int64) -> int64
```

Answers a request with a tag, one word and size bytes, for replies that
carry both a result code and data. Otherwise as alph_reply.
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

### `alph_exit_now`

```mettle
export fn alph_exit_now(reason: int64)
```

Ends the running actor at once, from any call depth inside its handler,
as if the handler had returned alph_stop(reason). Frames between here and
the handler are abandoned: their defers do not run. The actor's heap is
freed as on any exit. Use it for errors found deep in a call chain; a
handler can just return alph_stop. Does nothing, and returns, when called
outside a handler. Thread: a handler, at any depth.

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

Allocates size bytes from this actor's own heap: 16-byte aligned, not
zeroed, and only this actor's to use. No other actor shares the heap, so
no lock is taken. Free it with alph_free, or leave it: everything is freed
when the actor exits, even by a crash. Returns 0 when the heap limit
(AlphConfig.heap_limit) would be passed or memory ran out.
Thread: a handler.

### `alph_free`

```mettle
export fn alph_free(ctx: AlphCtx*, ptr: rawptr)
```

Frees memory from alph_alloc or alph_realloc on this actor's heap.
Freeing 0 does nothing. Thread: a handler.

### `alph_realloc`

```mettle
export fn alph_realloc(ctx: AlphCtx*, ptr: rawptr, size: int64) -> rawptr
```

Resizes memory from alph_alloc, keeping its contents up to the smaller of
the two sizes. ptr 0 allocates. Returns the new address, which may differ,
or 0 when there is no room, in which case ptr is left as it was.
Thread: a handler.

### `alph_scratch`

```mettle
export fn alph_scratch(ctx: AlphCtx*, size: int64) -> rawptr
```

Allocates size bytes that are valid until this handler call returns, then
freed all at once at no cost. Use it for temporaries: parsing a request,
building a reply. Do not keep the address. Returns 0 when memory ran out.
Thread: a handler.

### `alph_heap_used`

```mettle
export fn alph_heap_used(ctx: AlphCtx*) -> int64
```

Bytes this actor's heap holds now, its state included.
Thread: a handler.

### `alph_spawn`

```mettle
export fn alph_spawn(ctx: AlphCtx*, flags: int64,
                     handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor with no state.

```text
flags    0, or any of ALPH_LINK, ALPH_MONITOR and ALPH_BOUND. A link
         and a monitor are set up before the new actor runs, so even a
         crash in its INIT reaches the caller; with ALPH_MONITOR its
         DOWN arrives with from = the new pid. ALPH_BOUND gives the new
         actor a thread of its own, so its handler may block (file IO,
         fsync, a long computation) without holding up other actors.
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
export fn alph_node_spawn(node: AlphNode*, flags: int64,
                          handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor with no state from outside the node. It has no parent: its
INIT comes from 0 and nothing is linked to it.

```text
flags  0, or ALPH_BOUND for an actor with a thread of its own
```

Returns the new pid, or 0. Thread: any.

### `alph_node_spawn_value`

```mettle
export fn alph_node_spawn_value<T>(node: AlphNode*, flags: int64, state: T*,
                                   handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor whose state starts as a copy of *state, from outside the
node. Otherwise as alph_node_spawn. Thread: any.

### `alph_node_spawn_bytes`

```mettle
export fn alph_node_spawn_bytes(node: AlphNode*, flags: int64, state: rawptr, size: int64,
                                handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm) -> int64
```

Spawns an actor whose state starts as a copy of size bytes at state, from
outside the node. Otherwise as alph_node_spawn. Thread: any.

### `alph_register`

```mettle
export fn alph_register(ctx: AlphCtx*, name: string) -> bool
```

Registers name for the calling actor, so others can find it with
alph_whereis. An actor may hold several names. The name is copied; it is
dropped when the actor exits, crash included, or by alph_unregister.

Returns true when the name is now the caller's (also when it already
was), false when another live actor holds it, name is empty, or memory
runs out. Thread: a handler.

### `alph_unregister`

```mettle
export fn alph_unregister(ctx: AlphCtx*, name: string)
```

Drops name if the calling actor holds it; otherwise does nothing.
Thread: a handler.

### `alph_node_whereis`

```mettle
export fn alph_node_whereis(node: AlphNode*, name: string) -> int64
```

The pid registered as name, or 0 when there is none. The actor may exit
at any time after, so a send to the pid can still return ALPH_GONE.
Thread: any.

### `alph_whereis`

```mettle
export fn alph_whereis(ctx: AlphCtx*, name: string) -> int64
```

The pid registered as name, or 0; as alph_node_whereis.
Thread: a handler.

### `alph_group_join`

```mettle
export fn alph_group_join(ctx: AlphCtx*, group: string) -> bool
```

Adds the calling actor to the process group called group, creating the
group if needed. The name is copied. The actor leaves when it exits,
crash included, or by alph_group_leave; a group with no members is gone.

Returns true when the caller is a member (also when it already was),
false when group is empty or memory runs out. Thread: a handler.

### `alph_group_leave`

```mettle
export fn alph_group_leave(ctx: AlphCtx*, group: string)
```

Takes the calling actor out of group; does nothing if it is not a
member. Thread: a handler.

### `alph_node_group_size`

```mettle
export fn alph_node_group_size(node: AlphNode*, group: string) -> int64
```

How many actors are in group now; 0 when there is no such group.
Thread: any.

### `alph_group_send`

```mettle
export fn alph_group_send(ctx: AlphCtx*, group: string, tag: int64, arg: int64) -> int64
```

Sends a tag and one word to every member of group, the caller too if it
is one, each as alph_send. Returns how many members got it; a full
mailbox or an exited member is skipped. Thread: a handler.

### `alph_group_send_value`

```mettle
export fn alph_group_send_value<T>(ctx: AlphCtx*, group: string, tag: int64, value: T*) -> int64
```

Sends one T, copied for each member, to every member of group, as
alph_send_value. Returns as alph_group_send. Thread: a handler.

### `alph_group_send_bytes`

```mettle
export fn alph_group_send_bytes(ctx: AlphCtx*, group: string, tag: int64, data: rawptr,
                                size: int64) -> int64
```

Sends size bytes at data, copied for each member, to every member of
group, as alph_send_bytes. Returns as alph_group_send. Thread: a handler.

### `alph_io_open`

```mettle
export fn alph_io_open(ctx: AlphCtx*, fd: int64) -> int64
```

Makes the calling actor the owner of fd: it is made non-blocking, put on
this scheduler's epoll set, and closed when the actor exits, crash
included, unless it is closed or given away first. Any descriptor works;
one epoll cannot watch (a regular file) is still owned and closed, but
alph_io_arm refuses it.

```text
fd  an open file descriptor; the handle owns it from now on
```

Returns the handle (above 0), or a negative errno when fd is invalid, or
ALPH_NOMEM when max_handles are open. Thread: a handler.

### `alph_io_arm`

```mettle
export fn alph_io_arm(ctx: AlphCtx*, h: int64, events: int64) -> int64
```

Asks for one ALPH_TAG_IO message the next time handle h is ready for
events (ALPH_IO_IN, ALPH_IO_OUT, or both). The message's ref is h and its
arg says what is ready, which may include ALPH_IO_ERR or ALPH_IO_HUP. Arm
again after each message to hear about the next time.

Returns 0, or a negative errno: -9 when this actor does not own h, -1
when h cannot be watched (a regular file). Thread: a handler.

### `alph_io_read`

```mettle
export fn alph_io_read(ctx: AlphCtx*, h: int64, buf: rawptr, size: int64) -> int64
```

Reads up to size bytes from handle h into buf, without blocking.
Returns the count, 0 at end of stream (the peer closed), ALPH_IO_AGAIN
when nothing is there yet (arm ALPH_IO_IN and try again), or a negative
errno (-9 when this actor does not own h). Thread: a handler.

### `alph_io_write`

```mettle
export fn alph_io_write(ctx: AlphCtx*, h: int64, buf: rawptr, size: int64) -> int64
```

Writes up to size bytes from buf to handle h, without blocking. Returns
the count written, which may be less than size, ALPH_IO_AGAIN when none
fit (arm ALPH_IO_OUT and try again), or a negative errno. For whole
messages, an AlphOutq does the bookkeeping. Thread: a handler.

### `alph_io_close`

```mettle
export fn alph_io_close(ctx: AlphCtx*, h: int64)
```

Closes handle h and its descriptor now. Does nothing when this actor does
not own h. Thread: a handler.

### `alph_io_fd`

```mettle
export fn alph_io_fd(ctx: AlphCtx*, h: int64) -> int64
```

The descriptor behind handle h, for calls alph has no wrapper for, or -9
when this actor does not own h. Do not close it yourself; use
alph_io_close. Thread: a handler.

### `alph_io_give`

```mettle
export fn alph_io_give(ctx: AlphCtx*, h: int64, to: int64) -> int64
```

Hands handle h to the actor `to`, which becomes its owner and gets an
ALPH_TAG_IO_GIVEN message (ref = h, from = this actor). Any arming is
dropped; the new owner arms it. If `to` exits before taking it, it is
closed. Use it to pass an accepted connection to the actor that serves it.

Returns ALPH_SENT, ALPH_GONE when `to` has exited (h stays with this
actor), or -9 when this actor does not own h. Thread: a handler.

### `alph_io_error`

```mettle
export fn alph_io_error(ctx: AlphCtx*, h: int64) -> int64
```

The pending error on a socket handle, 0 when there is none: after a
connect reports ALPH_IO_OUT, 0 means it is connected. Returns a positive
errno, or -9 when this actor does not own h. Thread: a handler.

### `alph_ip4`

```mettle
export fn alph_ip4(a: int64, b: int64, c: int64, d: int64) -> int64
```

An IPv4 address in host order, for the alph_tcp_ functions:
alph_ip4(127, 0, 0, 1). Thread: any.

### `alph_tcp_listen`

```mettle
export fn alph_tcp_listen(ctx: AlphCtx*, ip4: int64, port: int64, backlog: int64, flags: int64) -> int64
```

Opens a TCP listener owned by the calling actor.

```text
ip4      the address to listen on: alph_ip4(0, 0, 0, 0) for all
port     the port, or 0 to let the system pick (see alph_tcp_port)
backlog  connections the kernel queues before accept
flags    0, or ALPH_TCP_REUSEPORT so several actors (one per
         scheduler) can each listen on the same port
```

Arm it with ALPH_IO_IN; on ALPH_TAG_IO, call alph_tcp_accept until it
returns ALPH_IO_AGAIN, then arm again. Returns the handle, or a negative
errno (-98 when the address is in use). Thread: a handler.

### `alph_tcp_accept`

```mettle
export fn alph_tcp_accept(ctx: AlphCtx*, listener: int64) -> int64
```

Accepts one waiting connection on a listener handle. The new connection
is a handle owned by the calling actor; give it to another actor with
alph_io_give. Returns the handle, ALPH_IO_AGAIN when none is waiting, or
a negative errno. Thread: a handler.

### `alph_tcp_connect`

```mettle
export fn alph_tcp_connect(ctx: AlphCtx*, ip4: int64, port: int64) -> int64
```

Starts connecting to ip4:port. Returns the handle at once, still
connecting: arm it with ALPH_IO_OUT, and on ALPH_TAG_IO check
alph_io_error, which is 0 once connected. Returns a negative errno when
it fails at once. Thread: a handler.

### `alph_tcp_port`

```mettle
export fn alph_tcp_port(ctx: AlphCtx*, h: int64) -> int64
```

The local port of a socket handle: the port a listener opened with port
0 got. Returns a negative errno on failure. Thread: a handler.

### `alph_tcp_nodelay`

```mettle
export fn alph_tcp_nodelay(ctx: AlphCtx*, h: int64, on: bool) -> int64
```

Turns Nagle's algorithm off (on true) for a TCP handle, so small writes
go out at once. Returns 0 or a negative errno. Thread: a handler.

### `AlphOutq`

```mettle
export struct AlphOutq {
  data: rawptr;
  len: int64;    // bytes in data
  sent: int64;   // bytes of data already written
  cap: int64;
  limit: int64;
}
```

An output queue: bytes waiting to be written to a handle, kept in the
actor's heap. It takes whole messages and writes what the socket accepts,
so a handler never has to track partial writes. Put it in the actor's
state and start it with alph_outq_init.

```text
limit  bytes it may hold; past it alph_outq_push returns ALPH_FULL,
       which is the signal that the peer reads too slowly
```

### `alph_outq_init`

```mettle
export fn alph_outq_init(q: AlphOutq*, limit: int64)
```

Starts q empty, holding at most limit bytes. Thread: any.

### `alph_outq_pending`

```mettle
export fn alph_outq_pending(q: AlphOutq*) -> int64
```

Bytes waiting in q. Thread: any.

### `alph_outq_push`

```mettle
export fn alph_outq_push(ctx: AlphCtx*, q: AlphOutq*, data: rawptr, size: int64) -> int64
```

Copies size bytes at data to the end of q. Returns ALPH_SENT, ALPH_FULL
when that would pass the limit (nothing is queued), or ALPH_NOMEM.
Thread: the handler of the actor whose state holds q.

### `alph_outq_flush`

```mettle
export fn alph_outq_flush(ctx: AlphCtx*, q: AlphOutq*, h: int64) -> int64
```

Writes as much of q to handle h as the socket accepts now. When bytes are
left it arms h for ALPH_IO_OUT, so the next ALPH_TAG_IO with ALPH_IO_OUT
is the time to flush again. Returns the bytes still waiting (0 when all
went out), or a negative errno when the write failed (the connection is
broken). Thread: the handler of the actor whose state holds q.

### `alph_outq_free`

```mettle
export fn alph_outq_free(ctx: AlphCtx*, q: AlphOutq*)
```

Frees q's buffer; q is empty afterwards. Thread: the handler of the actor
whose state holds q.

Flags for AlphProcSpec.flags. A stream that is not piped goes to
AlphProcSpec.log when set, else to /dev/null with ALPH_PROC_QUIET, else it
is inherited from the node. stdin is never sent to the log.

```mettle
export const ALPH_PROC_IN: int64 = 1;     // pipe the child's stdin; write to spec.stdin_h
export const ALPH_PROC_OUT: int64 = 2;    // pipe the child's stdout; read from spec.stdout_h
export const ALPH_PROC_ERR: int64 = 4;    // pipe the child's stderr; read from spec.stderr_h
export const ALPH_PROC_MERGE: int64 = 8;  // send stderr into the stdout pipe; needs ALPH_PROC_OUT
export const ALPH_PROC_QUIET: int64 = 16; // streams that are not piped go to /dev/null
export const ALPH_PROC_KEEP_GROUP: int64 = 32; // stay in the node's process group; see alph_proc_spawn
```

### `AlphProcSpec`

```mettle
export struct AlphProcSpec {
  argv: cstring*;
  envp: cstring*;
  cwd: cstring;
  log: cstring;
  flags: int64;
  stdin_h: int64;
  stdout_h: int64;
  stderr_h: int64;
}
```

What to run, for alph_proc_spawn. Set the inputs; alph_proc_spawn fills
the three handles.

```text
argv      the program and its arguments, ending with 0. A program
          name without a slash is looked up in PATH
envp      the environment, ending with 0; 0 means the environment
          this process started with
cwd       the working directory; 0 means the node's
log       a file for stdout and stderr when they are not piped,
          created or emptied (mode 0644); 0 means none
flags     ALPH_PROC_ bits
stdin_h   out: a handle to write the child's stdin, or 0
stdout_h  out: a handle to read the child's stdout, or 0
stderr_h  out: a handle to read the child's stderr, or 0
```

### `alph_proc_spawn`

```mettle
export fn alph_proc_spawn(ctx: AlphCtx*, spec: AlphProcSpec*) -> int64
```

Starts a child process owned by the calling actor, in a process group of
its own; with ALPH_PROC_KEEP_GROUP it stays in the node's group instead,
so a terminal's Ctrl-C and foreground reads reach it (for an app run in
the foreground), and only the child itself, not its own children, is
signalled and killed. The child's end is reported once as ALPH_TAG_PROC_EXIT, ref =
the returned handle, arg = its exit code or 128 + the signal that ended
it (127 when the program could not be run); the handle is closed then.
Piped streams are ordinary IO handles owned by the caller: arm and read
them like sockets, and close them when done.

When the owner exits before the child ends (crash included) or closes the
handle with alph_io_close, the child's whole process group is killed and
the child reaped. The handle can be moved with alph_io_give.

Returns the process handle, or a negative errno with nothing started:
-2 when the program is not found, -22 when argv is empty, -12 when
memory or handles run out, or the errno of opening the log.
Thread: a handler.

### `alph_proc_kill`

```mettle
export fn alph_proc_kill(ctx: AlphCtx*, h: int64, sig: int64) -> int64
```

Sends OS signal sig (15 for SIGTERM, 9 for SIGKILL, ...) to the process
group of the child behind process handle h, or to the child alone when it
was started with ALPH_PROC_KEEP_GROUP. The end still arrives as
ALPH_TAG_PROC_EXIT. A graceful stop is SIGTERM, then a timer, then
SIGKILL.

Returns 0, -9 when the caller does not own h, -3 when the child has
already ended, or another negative errno. Thread: a handler.

### `alph_proc_os_pid`

```mettle
export fn alph_proc_os_pid(ctx: AlphCtx*, h: int64) -> int64
```

The OS process id of the child behind process handle h, or 0 when the
caller does not own h or the child has been reaped. Thread: a handler.

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
Its heap is emptied, exits are no longer trapped, and it gets INIT again.
Its pid, links, monitors and mailbox stay. If even the fresh state does
not fit its heap limit, it exits with ALPH_CRASHED instead. Returns false
when pid is not this medic's crashed patient. Thread: the medic's handler.

### `alph_patient_fail`

```mettle
export fn alph_patient_fail(ctx: AlphCtx*, pid: int64, reason: int64) -> bool
```

For a medic: gives up. The patient exits with reason, which its links,
monitors and supervisor see; passive healing takes over. Returns false
when pid is not this medic's crashed patient. Thread: the medic's handler.

### `alph_node_shutdown`

```mettle
export fn alph_node_shutdown(node: AlphNode*, deadline_ms: int64, code: int64) -> bool
```

Stops the node in order. Top-level actors (those from alph_node_spawn and
friends) get ALPH_SHUTDOWN one at a time, newest first, each after the
one before has exited, so a supervisor stops its children before an older
root goes. At deadline_ms, or once the roots are gone, every actor still
alive is killed; then the node halts and alph_node_wait returns code.
Killed actors that own child processes kill and reap them as they exit.
A bound actor blocked for ever in a system call cannot be killed and
keeps alph_node_wait waiting; give blocking calls timeouts.

```text
deadline_ms  time for the orderly part; 0 means no limit
code         what alph_node_wait returns
```

Returns false when a shutdown has already begun. Thread: any.

### `alph_shutdown`

```mettle
export fn alph_shutdown(ctx: AlphCtx*, deadline_ms: int64, code: int64) -> bool
```

Stops the node in order, as alph_node_shutdown. Thread: a handler.

### `alph_node_signals`

```mettle
export fn alph_node_signals(node: AlphNode*, pid: int64, tag: int64)
```

Sends the OS signals the node took over (AlphConfig.signals) to actor
pid as messages: tag, arg = the signal number (ALPH_SIGINT, ALPH_SIGTERM,
ALPH_SIGHUP, ...). They are never dropped. pid 0, the default, or a pid
that has exited, means the node handles them: the first starts
alph_node_shutdown(node, 5000, 128 + signal), a second halts at once.

A node that takes over signals blocks them in the thread that calls
alph_node_start, so call that from main before starting other threads.
Child processes start with every signal unblocked. Thread: any.

### `alph_config`

```mettle
export fn alph_config(cfg: AlphConfig*)
```

Fills cfg with the defaults: one scheduler per CPU, 65536 actors, 64
messages per mailbox, 1 MiB of stack per scheduler, no heap limit, 65536
IO handles.
Thread: any.

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

## alph/heal/dynamic

Supervisors whose children are added at run time.

A dynamic supervisor starts with no children. Every child runs the same
handler and is started on request with its own initial state, as OTP's
DynamicSupervisor: one connection or session per child. There is no
fixed limit on children; max_children sets one.

Each child is restarted alone (one for one) by the spec's restart type:

```text
ALPH_PERMANENT  always restarted, from the initial state it was started with
ALPH_TRANSIENT  restarted unless it exited with ALPH_NORMAL or ALPH_SHUTDOWN
ALPH_TEMPORARY  never restarted; the usual choice for connections
```

More than max_restarts restarts within period_ms and the supervisor gives
up: it stops every child and exits with ALPH_SHUTDOWN. When it stops,
for that reason or because its parent exited or sent it an exit signal,
every child gets an ALPH_SHUTDOWN exit signal at once, and ALPH_KILL
after shutdown_ms.

```text
var spec: AlphDynSpec;
alph_dyn_init(&spec, &conn_handler);
spec.restart = ALPH_TEMPORARY;
var sup: int64 = alph_spawn_dyn(ctx, &spec);
...
var ref: int64 = alph_dyn_start_value<Conn>(ctx, sup, &conn, 1000);
// later: ALPH_TAG_STARTED with m->ref == ref and m->arg = the child's pid
```

The reply to a start request: m->ref is the request, m->arg the new
child's pid, or 0 when it was not started (the supervisor is full,
stopping, or out of memory, or the node is full).

```mettle
export const ALPH_TAG_STARTED: int64 = 12;
```

### `AlphDynSpec`

```mettle
export struct AlphDynSpec {
  restart: int64;
  shutdown_ms: int64;
  max_restarts: int64;
  period_ms: int64;
  max_children: int64;
  handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm;
}
```

A dynamic supervisor's definition. Start it with alph_dyn_init, change
these if needed, then spawn it with alph_spawn_dyn:

```text
restart       restart type of every child; default ALPH_PERMANENT, as OTP
shutdown_ms   how long children get to stop before they are killed; 0
              kills them at once. Default 5000
max_restarts  restarts allowed within period_ms before giving up;
              default 3 (at most 63)
period_ms     default 5000
max_children  children at once; 0 (default) is no limit
handler       the children's handler, set by alph_dyn_init
```

### `alph_dyn_init`

```mettle
export fn alph_dyn_init(spec: AlphDynSpec*, handler: fn(AlphCtx*, AlphMsg*) -> int64 with alloc, syscall, asm)
```

Starts a dynamic supervisor definition for children that run handler,
with the defaults listed at AlphDynSpec. Thread: any.

### `alph_spawn_dyn`

```mettle
export fn alph_spawn_dyn(ctx: AlphCtx*, spec: AlphDynSpec*) -> int64
```

Spawns a dynamic supervisor linked to the calling actor, which becomes
its parent: if the parent exits, the supervisor stops its children and
exits too.

```text
spec  the definition; copied
```

Returns the supervisor's pid, or 0 when the node is full or out of
memory. Thread: a handler. Outside the node, use alph_node_spawn_dyn.

### `alph_node_spawn_dyn`

```mettle
export fn alph_node_spawn_dyn(node: AlphNode*, spec: AlphDynSpec*) -> int64
```

Spawns a top-level dynamic supervisor with no parent. Stop it with
alph_node_exit_signal(node, pid, ALPH_SHUTDOWN). Otherwise as
alph_spawn_dyn. Thread: any.

### `alph_dyn_start_bytes`

```mettle
export fn alph_dyn_start_bytes(ctx: AlphCtx*, sup: int64, data: rawptr, size: int64,
                               timeout_ms: int64) -> int64
```

Asks dynamic supervisor sup to start a child whose state is size bytes
at data, copied. The answer is ALPH_TAG_STARTED (arg = the new pid, or 0)
or, as for any request, ALPH_TAG_DOWN or ALPH_TAG_TIMEOUT; each carries
the returned ref. Returns as alph_request. Thread: a handler.

### `alph_dyn_start_value`

```mettle
export fn alph_dyn_start_value<T>(ctx: AlphCtx*, sup: int64, state: T*, timeout_ms: int64) -> int64
```

Asks sup to start a child whose state is one T, copied. Otherwise as
alph_dyn_start_bytes. Thread: a handler.

### `alph_dyn_start`

```mettle
export fn alph_dyn_start(ctx: AlphCtx*, sup: int64, arg: int64, timeout_ms: int64) -> int64
```

Asks sup to start a child whose state is one int64 holding arg (a
handle, an index). Otherwise as alph_dyn_start_bytes. Thread: a handler.

## alph/work/pool

A pool of threads for blocking work.

A handler must not block, so blocking work (file IO, a blocking client,
a long hash) goes to a pool: a dispatcher actor and N ALPH_BOUND worker
actors, each on a thread of its own. alph_offload sends one job, a
function and its input; the answer comes back as a message, like the
reply to a request:

```text
ALPH_TAG_DONE    arg = the work function's return, payload = the bytes
                 it put in its AlphOut
ALPH_TAG_FAILED  arg = the reason the job ended without a result:
                 ALPH_CRASHED for a trap, the reason given to
                 alph_exit_now, or ALPH_FULL when the pool's queue was
                 full
```

or, as for any request, ALPH_TAG_DOWN (the pool is gone) or
ALPH_TAG_TIMEOUT. A job that times out still runs to the end; its result
is dropped. A worker that crashes or exits is replaced.

```text
fn hash_file(input: rawptr, size: int64, out: AlphOut*) -> int64 { ... }
var pool: int64 = alph_spawn_pool(ctx, 4, 1024);
var ref: int64 = alph_offload(ctx, pool, path, path_len, 5000, &hash_file);
```

The answers to alph_offload, described at the top of this module.

```mettle
export const ALPH_TAG_DONE: int64 = 15;
export const ALPH_TAG_FAILED: int64 = 16;
```

### `AlphOut`

```mettle
export struct AlphOut {
  ctx: AlphCtx*;
  data: int64;
  len: int64;
  cap: int64;
}
```

Where a work function puts its result bytes. Fill it with alph_out_bytes;
its fields are the runtime's own.

### `alph_out_bytes`

```mettle
export fn alph_out_bytes(out: AlphOut*, data: rawptr, size: int64) -> bool
```

Appends size bytes at data to out. Returns false when the worker's heap
is full (heap_limit); out keeps what it had. Thread: the work function
that got out.

### `alph_spawn_pool`

```mettle
export fn alph_spawn_pool(ctx: AlphCtx*, workers: int64, queue: int64) -> int64
```

Spawns a pool linked to the calling actor, which becomes its parent: if
the parent exits, the pool and its workers exit too.

```text
workers  threads, each running one job at a time (at least 1)
queue    jobs that may wait for a free worker; past it a job fails
         with ALPH_FULL (at least 1)
```

Returns the pool's pid, or 0 when the arguments are out of range or the
node is full. Thread: a handler. Outside the node, use
alph_node_spawn_pool.

### `alph_node_spawn_pool`

```mettle
export fn alph_node_spawn_pool(node: AlphNode*, workers: int64, queue: int64) -> int64
```

Spawns a top-level pool with no parent. Stop it with
alph_node_exit_signal(node, pid, ALPH_SHUTDOWN). Otherwise as
alph_spawn_pool. Thread: any.

### `alph_offload`

```mettle
export fn alph_offload(ctx: AlphCtx*, pool: int64, input: rawptr, size: int64, timeout_ms: int64,
                       work: fn(rawptr, int64, AlphOut*) -> int64 with alloc, syscall, asm) -> int64
```

Sends a job to pool: work(copy of input, size, out) runs on a worker
thread, where it may block. The input is size bytes, copied. The answer
carries the returned ref; it is described at the top of this module.
work must not keep pointers into its input or out after it returns.

Returns the ref, or ALPH_FULL or ALPH_NOMEM when the job was not sent
(the pool's mailbox is full, or no memory). Thread: a handler.

## alph/work/limiter

A counting semaphore as an actor.

A limiter holds a number of permits, such as the -j of a build or the
connections a database allows. alph_acquire asks for one; the answer
ALPH_TAG_GRANTED comes when one is free, first come first served. The
holder gives it back with alph_release, and a holder that exits gives it
back by its exit. alph_release on a request still waiting withdraws it.

```text
var cpu: int64 = alph_spawn_limiter(ctx, 8);
var ref: int64 = alph_acquire(ctx, cpu);
... ALPH_TAG_GRANTED with m->ref == ref: start the job
alph_release(ctx, cpu, ref);
```

The answer to alph_acquire: a permit is now the caller's. m->ref is the
ref alph_acquire returned.

```mettle
export const ALPH_TAG_GRANTED: int64 = 19;
```

### `alph_spawn_limiter`

```mettle
export fn alph_spawn_limiter(ctx: AlphCtx*, permits: int64) -> int64
```

Spawns a limiter with permits permits (at least 1), linked to the calling
actor. Returns its pid, or 0. Thread: a handler. Outside the node, use
alph_node_spawn_limiter.

### `alph_node_spawn_limiter`

```mettle
export fn alph_node_spawn_limiter(node: AlphNode*, permits: int64) -> int64
```

Spawns a top-level limiter with no parent. Otherwise as
alph_spawn_limiter. Thread: any.

### `alph_acquire`

```mettle
export fn alph_acquire(ctx: AlphCtx*, limiter: int64) -> int64
```

Asks limiter for one permit. ALPH_TAG_GRANTED with the returned ref comes
when it is the caller's; ALPH_TAG_DOWN with that ref if the limiter is
gone. There is no timeout: to give up waiting, use alph_release.

Returns the ref, or ALPH_FULL or ALPH_NOMEM when the request was not
sent. Thread: a handler.

### `alph_release`

```mettle
export fn alph_release(ctx: AlphCtx*, limiter: int64, ref: int64) -> int64
```

Gives back the permit named by ref, or withdraws the request if it is
still waiting; a GRANTED for ref already on its way is dropped. Returns
as alph_send; on ALPH_FULL try again later, or exit, which also gives it
back. Thread: a handler.

## alph/net/port

Wait until a TCP port accepts connections.

After starting a server as a child process, a caller often has to wait
until it listens. alph_spawn_port_wait starts an actor that tries to
connect every interval_ms and tells its parent once:

```text
ALPH_TAG_PORT_READY  from = the waiter, arg = 1 when a connection was
                     accepted, 0 after tries failed attempts
```

The waiter closes its test connection and exits after telling. To stop it
early, send it an exit signal.

The waiter's answer, described at the top of this module.

```mettle
export const ALPH_TAG_PORT_READY: int64 = 24;
```

### `alph_spawn_port_wait`

```mettle
export fn alph_spawn_port_wait(ctx: AlphCtx*, ip4: int64, port: int64, interval_ms: int64,
                               tries: int64) -> int64
```

Spawns an actor that waits for ip4:port (alph_ip4) to accept TCP
connections, trying every interval_ms at most tries times (each at least
1), and answers the caller with ALPH_TAG_PORT_READY. It is linked to the
caller, so it stops if the caller exits; its own normal exit does not
reach the caller.

Returns its pid, or 0 when an argument is out of range or the node is
full. Thread: a handler.

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
  owner: int64;
}
```

One thread's recovery point. Register it with alph_recover_register,
then save into regs with alph_recover_save.

```text
crashes  how many crashes resumed this point so far
owner    free for the registrant: the node keeps its scheduler here
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

### `alph_recover_current`

```mettle
export fn alph_recover_current() -> AlphRecover*
```

The armed recovery point of the calling thread, or 0 when the thread has
none armed. Thread: any.

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

## alph/sys/fd

Thin wrappers over the file descriptor, epoll and socket
system calls the IO layer uses. Each returns what the kernel returns: a
result, or a negative errno. They never block on their own; whether a
read blocks depends on the descriptor, and alph opens every descriptor it
manages non-blocking. Programs use alph_io_* and alph_tcp_* from
alph/core/node instead.

### `alph_sys_read`

```mettle
export fn alph_sys_read(fd: int64, buf: rawptr, size: int64) -> int64
```

Reads up to size bytes into buf. Returns the count, 0 at end of file, or
a negative errno (-ALPH_EAGAIN when a non-blocking descriptor is empty).
Thread: any.

### `alph_sys_write`

```mettle
export fn alph_sys_write(fd: int64, buf: rawptr, size: int64) -> int64
```

Writes up to size bytes from buf. Returns the count written, which may
be less than size, or a negative errno. Thread: any.

### `alph_sys_close`

```mettle
export fn alph_sys_close(fd: int64) -> int64
```

Closes fd. Returns 0 or a negative errno. Thread: any.

### `alph_sys_nonblock`

```mettle
export fn alph_sys_nonblock(fd: int64) -> int64
```

Makes fd non-blocking. Returns 0 or a negative errno. Thread: any.

### `alph_sys_epoll`

```mettle
export fn alph_sys_epoll() -> int64
```

A new epoll instance, closed on exec, or a negative errno. Thread: any.

### `alph_sys_epoll_ctl`

```mettle
export fn alph_sys_epoll_ctl(ep: int64, op: int64, fd: int64, events: int64, data: int64) -> int64
```

Adds, changes or removes fd in the epoll set ep.

```text
op      ALPH_EPOLL_CTL_ADD, _MOD or _DEL
events  ALPH_EPOLLIN and friends
data    the word epoll hands back with each event for fd
```

Returns 0 or a negative errno. Thread: any.

### `alph_sys_epoll_wait`

```mettle
export fn alph_sys_epoll_wait(ep: int64, events: rawptr, max: int64, timeout_ms: int64) -> int64
```

Waits up to timeout_ms (negative: without limit) for events on ep and
stores up to max of them in events, which must hold 12 bytes per event.
Returns how many, or a negative errno (-4 when a signal interrupted it).
Thread: any.

### `alph_sys_event_mask`

```mettle
export fn alph_sys_event_mask(events: rawptr, i: int64) -> int64
```

The events mask of event i in an array filled by alph_sys_epoll_wait.

### `alph_sys_event_data`

```mettle
export fn alph_sys_event_data(events: rawptr, i: int64) -> int64
```

The data word of event i in an array filled by alph_sys_epoll_wait.

### `alph_sys_eventfd`

```mettle
export fn alph_sys_eventfd() -> int64
```

A new eventfd, non-blocking and closed on exec, or a negative errno.
Writing 8 bytes to it makes it readable until it is read. Thread: any.

### `alph_sys_sockaddr`

```mettle
export fn alph_sys_sockaddr(addr: uint8*, ip4: int64, port: int64)
```

Fills a 16-byte struct sockaddr_in for ip4 (host order, as from alph_ip4)
and port.

### `alph_sys_tcp_socket`

```mettle
export fn alph_sys_tcp_socket() -> int64
```

A new non-blocking TCP socket, closed on exec, or a negative errno.
Thread: any.

### `alph_sys_setsockopt`

```mettle
export fn alph_sys_setsockopt(fd: int64, level: int64, name: int64, value: int64) -> int64
```

Sets an integer socket option. Returns 0 or a negative errno.
Thread: any.

## alph/sys/linux

The Linux x86-64 system call numbers and flags alph uses.

Every raw syscall in the runtime goes through these names, so a port to
another platform starts here.

System call numbers.

```mettle
export const ALPH_SYS_READ: int64 = 0;
export const ALPH_SYS_WRITE: int64 = 1;
export const ALPH_SYS_CLOSE: int64 = 3;
export const ALPH_SYS_MMAP: int64 = 9;
export const ALPH_SYS_MPROTECT: int64 = 10;
export const ALPH_SYS_MUNMAP: int64 = 11;
export const ALPH_SYS_SOCKET: int64 = 41;
export const ALPH_SYS_CONNECT: int64 = 42;
export const ALPH_SYS_SHUTDOWN: int64 = 48;
export const ALPH_SYS_BIND: int64 = 49;
export const ALPH_SYS_LISTEN: int64 = 50;
export const ALPH_SYS_GETSOCKNAME: int64 = 51;
export const ALPH_SYS_SETSOCKOPT: int64 = 54;
export const ALPH_SYS_GETSOCKOPT: int64 = 55;
export const ALPH_SYS_FCNTL: int64 = 72;
export const ALPH_SYS_SIGALTSTACK: int64 = 131;
export const ALPH_SYS_FUTEX: int64 = 202;
export const ALPH_SYS_SCHED_GETAFFINITY: int64 = 204;
export const ALPH_SYS_CLOCK_GETTIME: int64 = 228;
export const ALPH_SYS_EPOLL_WAIT: int64 = 232;
export const ALPH_SYS_EPOLL_CTL: int64 = 233;
export const ALPH_SYS_ACCEPT4: int64 = 288;
export const ALPH_SYS_EVENTFD2: int64 = 290;
export const ALPH_SYS_EPOLL_CREATE1: int64 = 291;
export const ALPH_SYS_OPEN: int64 = 2;
export const ALPH_SYS_RT_SIGPROCMASK: int64 = 14;
export const ALPH_SYS_ACCESS: int64 = 21;
export const ALPH_SYS_DUP2: int64 = 33;
export const ALPH_SYS_CLONE: int64 = 56;
export const ALPH_SYS_EXECVE: int64 = 59;
export const ALPH_SYS_KILL: int64 = 62;
export const ALPH_SYS_CHDIR: int64 = 80;
export const ALPH_SYS_SETPGID: int64 = 109;
export const ALPH_SYS_EXIT_GROUP: int64 = 231;
export const ALPH_SYS_WAITID: int64 = 247;
export const ALPH_SYS_PIPE2: int64 = 293;
export const ALPH_SYS_PIDFD_OPEN: int64 = 434;
export const ALPH_SYS_SIGNALFD4: int64 = 289;
export const ALPH_SYS_GETPID: int64 = 39;
export const ALPH_SYS_GETPGID: int64 = 121;
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
export const ALPH_O_NONBLOCK: int64 = 2048;
export const ALPH_O_CLOEXEC: int64 = 524288;
export const ALPH_F_GETFL: int64 = 3;
export const ALPH_F_SETFL: int64 = 4;
export const ALPH_EPOLL_CTL_ADD: int64 = 1;
export const ALPH_EPOLL_CTL_DEL: int64 = 2;
export const ALPH_EPOLL_CTL_MOD: int64 = 3;
export const ALPH_EPOLLIN: int64 = 1;
export const ALPH_EPOLLOUT: int64 = 4;
export const ALPH_EPOLLERR: int64 = 8;
export const ALPH_EPOLLHUP: int64 = 16;
export const ALPH_EPOLLRDHUP: int64 = 8192;
export const ALPH_EPOLLONESHOT: int64 = 1073741824;
export const ALPH_AF_INET: int64 = 2;
export const ALPH_SOCK_STREAM: int64 = 1;
export const ALPH_SOCK_NONBLOCK: int64 = 2048;
export const ALPH_SOCK_CLOEXEC: int64 = 524288;
export const ALPH_SOL_SOCKET: int64 = 1;
export const ALPH_SO_REUSEADDR: int64 = 2;
export const ALPH_SO_ERROR: int64 = 4;
export const ALPH_SO_REUSEPORT: int64 = 15;
export const ALPH_IPPROTO_TCP: int64 = 6;
export const ALPH_TCP_NODELAY: int64 = 1;
export const ALPH_EAGAIN: int64 = 11;
export const ALPH_EINPROGRESS: int64 = 115;
export const ALPH_ENOENT: int64 = 2;
export const ALPH_O_RDONLY: int64 = 0;
export const ALPH_O_RDWR: int64 = 2;
export const ALPH_O_WRONLY: int64 = 1;
export const ALPH_O_CREAT: int64 = 64;
export const ALPH_O_TRUNC: int64 = 512;
export const ALPH_X_OK: int64 = 1;
export const ALPH_SIGCHLD: int64 = 17;
export const ALPH_SIGKILL: int64 = 9;
export const ALPH_SIGHUP: int64 = 1;
export const ALPH_SIGINT: int64 = 2;
export const ALPH_SIGTERM: int64 = 15;
export const ALPH_SIG_BLOCK: int64 = 0;
export const ALPH_SIG_SETMASK: int64 = 2;
export const ALPH_IDTYPE_PID: int64 = 1;
export const ALPH_WNOHANG: int64 = 1;
export const ALPH_WEXITED: int64 = 4;
export const ALPH_CLD_EXITED: int64 = 1;
```

The memory page size, for guard pages.

```mettle
export const ALPH_PAGE_SIZE: int64 = 4096;
```

## alph/core/heap

Per-actor heaps, per-scheduler chunk pools and scratch.

Every actor owns an AlphHeap. Only that actor allocates from it, so
allocation takes no lock: blocks come from size-class free lists or are
carved from the heap's current chunk. When the actor exits, its chunks go
back to a pool as a whole. Nothing is collected and nothing ever pauses
other actors.

Chunks come from an AlphPool, one per scheduler, which carves them from
large mmap'd slabs and keeps freed ones for reuse. A pool has a spin lock,
but only its scheduler uses it in the normal course, so it is uncontended.
Blocks over 32 KiB bypass chunks and are mapped on their own.

Internal to the runtime: actors use alph_alloc, alph_free, alph_realloc
and alph_scratch from alph/core/node.

### `AlphPool`

```mettle
export struct AlphPool {
  lock: int64;
  free: int64[3];  // a list per chunk size
  slab: int64;     // the slab being carved
  slab_end: int64;
}
```

Free chunks of each size, ready for reuse. One per scheduler.

### `AlphHeap`

```mettle
export struct AlphHeap {
  free: int64[11];  // a free list per size class
  cur: int64;       // bump pointer in the current chunk
  end: int64;
  chunks: int64;    // every chunk the heap owns, linked through their headers
  next_size: int64; // index of the next chunk size to take
  large: int64;     // blocks mapped on their own, a doubly linked list
  used: int64;      // bytes in blocks handed out, headers included
  limit: int64;     // 0 for none
}
```

One actor's memory.

### `AlphScratch`

```mettle
export struct AlphScratch {
  first: int64;     // the chunk kept across resets
  cur: int64;
  end: int64;
  extra: int64;     // further chunks, returned on reset
}
```

Memory valid until the scratch is reset: after every handler call.

### `alph_pool_take`

```mettle
export fn alph_pool_take(pool: AlphPool*, index: int64) -> int64
```

Hands out a chunk of the given size index, or 0 when memory ran out.
Thread: any; the pool's lock is taken.

### `alph_pool_give`

```mettle
export fn alph_pool_give(pool: AlphPool*, chunks: int64)
```

Gives back a list of chunks linked through their first word.
Thread: any; the pool's lock is taken.

### `alph_heap_init`

```mettle
export fn alph_heap_init(heap: AlphHeap*, limit: int64)
```

Makes heap empty with the given byte limit (0 for none). It owns nothing.

### `alph_heap_alloc`

```mettle
export fn alph_heap_alloc(heap: AlphHeap*, pool: AlphPool*, size: int64) -> rawptr
```

Allocates size bytes, 16-byte aligned and not zeroed. Returns 0 when the
heap's limit would be passed or memory ran out.
Thread: the heap's owner.

### `alph_heap_size`

```mettle
export fn alph_heap_size(ptr: rawptr) -> int64
```

The usable size of a block from alph_heap_alloc.

### `alph_heap_free`

```mettle
export fn alph_heap_free(heap: AlphHeap*, ptr: rawptr)
```

Returns a block to the heap. ptr must come from this heap; 0 is ignored.
Thread: the heap's owner.

### `alph_heap_release`

```mettle
export fn alph_heap_release(heap: AlphHeap*, pool: AlphPool*)
```

Releases everything the heap owns: chunks go back to pool, mapped blocks
to the system. The heap is empty afterwards, with the same limit.
Thread: any thread that is the only one touching heap.

### `alph_scratch_alloc`

```mettle
export fn alph_scratch_alloc(s: AlphScratch*, pool: AlphPool*, size: int64) -> rawptr
```

Allocates size bytes valid until the next alph_scratch_reset, 16-byte
aligned and not zeroed. Returns 0 when memory ran out.
Thread: the scratch's owner.

### `alph_scratch_reset`

```mettle
export fn alph_scratch_reset(s: AlphScratch*, pool: AlphPool*)
```

Frees everything allocated since the last reset, keeping the first chunk.
Thread: the scratch's owner.

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
