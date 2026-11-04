# Using the alph runtime

This guide walks through the runtime in the order you need it. Every function it names is in the [API reference](api.md), with its inputs, outputs and which thread may call it. The code comes from [examples/](../examples), which `check.sh` builds and runs, so it stays correct.

## The model

A **node** is one OS process running a set of **schedulers**, one thread per CPU by default. The node runs **actors**. An actor is three things:

- a **state** block, private to it;
- a bounded **mailbox**;
- a **handler**: `fn(ctx: AlphCtx*, m: AlphMsg*) -> int64`.

The handler gets one message, handles it to the end, and returns. That return is the only place a scheduler switches to another actor, which has two consequences:

- **Never block in a handler.** No sleeping, no waiting on a lock, no blocking read. A blocked handler stalls its whole scheduler.
- **Never loop without bound in a handler.** Give it a deadline, `fn handle(...) -> int64 where cycles < 5000`, and the compiler proves it, or tells you why it can't. Work that really is long belongs in its own thread, or should be cut into steps the actor sends to itself.

Actors share nothing. They talk only by messages, and a crash in one handler ends only that actor.

## Starting a node

```mettle
var g_node: AlphNode;

fn main() -> int32 {
  var cfg: AlphConfig;
  alph_config(&cfg);              // defaults: one scheduler per CPU, ...
  if (!alph_node_start(&g_node, &cfg)) {
    return 1;
  }
  alph_node_spawn(&g_node, &root);
  return (int32)alph_node_wait(&g_node);
}
```

`alph_config` fills in defaults. Change the fields you care about before starting: `schedulers`, `max_actors`, `mailbox_size`, `stack_size`. `alph_node_wait` returns when a handler calls `alph_halt(ctx, code)`, and gives back `code`.

Name the functions you call from `main` by these rules:
- **Inside a handler,** functions take `ctx`.
- **Outside a handler,** in `main`, another thread or a test, functions start with `alph_node_` and take the node.

## Actors

```mettle
struct Counter {
  total: int64;
}

fn counter(ctx: AlphCtx*, m: AlphMsg*) -> int64 {
  var c: Counter* = (Counter*)ctx->state;
  if (m->tag == TAG_ADD) {
    c->total = c->total + m->arg;
  }
  return ALPH_CONTINUE;
}
```

Every actor's first message is `ALPH_TAG_INIT`, whose `from` is the actor that spawned it. Set up there.

| To spawn | From a handler | From outside |
|---|---|---|
| With no state | `alph_spawn(ctx, flags, &h)` | `alph_node_spawn(node, &h)` |
| With a copy of one `T` | `alph_spawn_value<T>(ctx, flags, &state, &h)` | `alph_node_spawn_value<T>(node, &state, &h)` |
| With raw bytes | `alph_spawn_bytes(ctx, flags, ptr, size, &h)` | `alph_node_spawn_bytes(node, ptr, size, &h)` |

The state is copied, so the original can be a local. `flags` is 0, `ALPH_LINK` or `ALPH_MONITOR`, or both combined with `|`. These set up a link or monitor before the new actor runs, so even a crash in its `INIT` is seen.

An actor ends when its handler returns `alph_stop(ctx, reason)`, when it crashes, or when an exit signal ends it.

## Messages

A message has a `tag`, the sender's pid in `from`, one word in `arg`, and an optional payload. Pick your tags from `ALPH_TAG_USER` up; the ones below it belong to the runtime.

| To send | Sender writes | Receiver reads |
|---|---|---|
| A tag and one word | `alph_send(ctx, to, TAG, 42)` | `m->arg` |
| A struct | `alph_send_value<Point>(ctx, to, TAG, &p)` | `alph_msg_value<Point>(m, &p)` |
| Bytes of any length | `alph_send_bytes(ctx, to, TAG, ptr, n)` | `alph_msg_bytes(m, &n)` |

`alph_msg_value<T>` returns false when the payload is not exactly one `T`. That usually means a tag was sent with a different type than the receiver expects, and you find out instead of reading garbage. The payload is valid until the handler returns, so copy what you keep.

Sending returns:
- `ALPH_SENT`: delivered.
- `ALPH_FULL`: the receiver's mailbox is full.
- `ALPH_GONE`: the receiver has exited.
- `ALPH_NOMEM`: there was no memory for a large payload.

Nothing is sent unless it returns `ALPH_SENT`. A full mailbox is backpressure: the receiver is behind, and the sender decides whether to retry later, shed the work, or slow down. Messages from one sender arrive in the order they were sent.

## Requests

A request is a message whose answer comes back carrying the same `ref`. From [examples/request.mettle](../examples/request.mettle):

```mettle
fn server(ctx: AlphCtx*, m: AlphMsg*) -> int64 {
  if (m->tag == TAG_SQUARE) {
    alph_reply(ctx, m, TAG_RESULT, m->arg * m->arg);
  }
  return ALPH_CONTINUE;
}

// in the client
c->asking = alph_request(ctx, c->server, TAG_SQUARE, 12, 1000);
...
if (m->tag == TAG_RESULT && m->ref == c->asking) { ... }
if (m->tag == ALPH_TAG_DOWN && m->ref == c->asking) { ... }     // server died
if (m->tag == ALPH_TAG_TIMEOUT && m->ref == c->asking) { ... }  // no answer in time
```

Exactly one of these arrives for each request:
- the reply;
- a `DOWN`, if the server exited or was already gone;
- a `TIMEOUT`, after the given milliseconds.

Anything later for that ref is dropped, so a late reply never surprises you. `alph_request_value<T>` and `alph_reply_value<T>` carry structs, as above.

## Links, monitors and exits

- **Links are two-way.** `alph_link(ctx, pid)`: when either actor exits with a reason other than `ALPH_NORMAL`, the other exits with the same reason. If the other calls `alph_trap_exits(ctx, true)`, it gets an `ALPH_TAG_EXIT` message instead, with `from` the exited actor and `arg` its reason.
- **Monitors are one-way.** `alph_monitor(ctx, pid)` returns a ref. When pid exits, an `ALPH_TAG_DOWN` message arrives with that ref and the reason in `arg`. Monitoring an actor that is already gone gives `DOWN` with `ALPH_NOPROC`.
- **Exit signals.** `alph_exit_signal(ctx, pid, reason)` sends one. `ALPH_KILL` cannot be trapped, so it always ends the target.

Exits and downs arrive after the messages their sender sent before exiting. A worker that sends its result and then stops is seen sending the result first.

Exit reasons:

| Reason | Meaning |
|---|---|
| `ALPH_NORMAL` | A clean exit; links ignore it |
| `ALPH_CRASHED` | A trap or fault in the handler |
| `ALPH_KILLED` | Killed with `ALPH_KILL` |
| `ALPH_SHUTDOWN` | Stopped by a supervisor |
| `ALPH_NOPROC` | The actor was already gone |
| `ALPH_REASON_USER` and up | Your own |

## Timers

- `alph_send_after(ctx, ms, to, tag, arg)` sends a message later.
- `alph_start_timer(ctx, ms, tag, arg)` sends this actor a message later, and returns a ref for `alph_cancel_timer`. A cancelled timer never arrives, even if it was already due.

Timer messages are never dropped for a full mailbox.

## Memory

- The state is the actor's own block, copied in at spawn and freed when it exits.
- `alph_alloc(ctx, size)` gives memory that lives as long as the actor. Use it for anything the state points to. It is freed when the actor exits, so an actor never leaks, even when it crashes.
- Message payloads are copied on send.
- Globals are shared by every scheduler. Avoid them, or guard them with the atomics in `alph/sys/atomic`.

## Passive healing: supervisors

A supervisor restarts actors that exit. From [examples/supervised.mettle](../examples/supervised.mettle):

```mettle
var spec: AlphSupSpec;
alph_sup_init(&spec, ALPH_ONE_FOR_ONE);
alph_sup_add_value<Worker>(&spec, &w, &worker);
alph_spawn_sup(ctx, &spec);
```

`alph_sup_add` returns the child's spec, so you can change it by name:

```mettle
var child: AlphChildSpec* = alph_sup_add_value<Db>(&spec, &db, &db_handler);
child->restart = ALPH_TRANSIENT;   // restart only after a crash, not a clean exit
child->shutdown_ms = 10000;        // time it gets to stop before it is killed
child->sync_start = true;          // the next child waits for its alph_sup_ack
```

Strategies:

| Strategy | When a child exits |
|---|---|
| `ALPH_ONE_FOR_ONE` | Only it restarts |
| `ALPH_ONE_FOR_ALL` | Every child restarts |
| `ALPH_REST_FOR_ONE` | It and the children started after it restart |

- **Restart limit.** More than `spec.max_restarts` restarts within `spec.period_ms` and the supervisor gives up. It exits with `ALPH_SHUTDOWN`, so its own supervisor handles the failure. Nest supervisors to build a tree.
- **Backoff.** Set `spec.backoff_ms` to space out repeated restarts.

A restarted child is a new actor: a new pid, its initial state, and anything it was handling is lost.

## Proactive healing: medics

A medic repairs an actor in place instead. The actor keeps its pid, links, monitors, mailbox and state, and nobody else sees the crash. Based on [examples/medic.mettle](../examples/medic.mettle):

```mettle
fn repair(ctx: AlphCtx*, r: AlphRepair*) -> int64 {
  if (r->message->tag == TAG_SHARE && r->message->arg == 0) {
    return ALPH_HEAL_RESUME;        // drop the bad message, keep going
  }
  return ALPH_HEAL_FAIL;            // let the supervisor deal with it
}

// in the worker's INIT
var spec: AlphMedicSpec;
alph_medic_init(&spec, &repair);
alph_attach_medic(ctx, &spec);
```

The repair function sees:
- the crashed actor's state, which it may fix;
- the message it was handling;
- how many repairs it made recently.

It answers one of:

| Answer | What happens |
|---|---|
| `ALPH_HEAL_RESUME` | Keep the state, drop the message |
| `ALPH_HEAL_RETRY` | Keep the state, handle the message again |
| `ALPH_HEAL_RESET` | Back to the state at attach time; `INIT` runs again |
| `ALPH_HEAL_FAIL` | The actor exits, and passive healing takes over |

Too many repairs within `spec.period_ms` count as a fail. Use both kinds together: a medic for crashes you know how to repair, and a supervisor around the actor for everything else.

## Building

```bash
../Mettle/bin/mettle --build -s --release app.mettle
```

- **Use the dev compiler** from the Mettle repo.
- **Always build with `-s`.** Without it, a failed check (bounds, divide) exits the program before alph can catch it. Faults such as a null pointer are caught either way.
- **`--safe` is not supported yet.**
- **Test in debug and in release.** Release builds have had miscompiles.

## Rules to keep

1. **Handlers return quickly.** No blocking calls, no unbounded loops.
2. **Don't keep `ctx` or a message** past the handler call. Copy what you need.
3. **Use tags from `ALPH_TAG_USER` up.**
4. **Check what `alph_send` returns** where losing a message matters.
5. **Put a supervisor above everything that should come back,** and a medic on actors whose crashes you know how to repair.
