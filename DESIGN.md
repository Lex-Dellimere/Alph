# alph runtime design

The goal is BEAM's fault tolerance, self-healing and distribution in Mettle without giving up what Mettle is: compiled, native, no GC, no hidden runtime. This file says what to take from BEAM and OTP, what to change, what to leave, and in what order to build it. How to use the runtime is in [docs/guide.md](docs/guide.md).

The alph runtime is a separate library, as BEAM is separate from the Erlang compiler. It is written in Mettle. C is used only where Mettle cannot do the job, and so far that is nowhere. The Mettle compiler and its runtime are not modified.

The research behind it was read from the Mettle source and from the OTP 30 source (ERTS for the runtime mechanisms; stdlib, kernel and sasl for supervisors, applications, releases and distribution). The notes are kept locally in `reference_model/` and are not part of the repository.

## The deciding constraint

BEAM stays responsive because the VM counts reductions and preempts a process after about 4000 of them. Mettle cannot copy that. Its charter refuses any control flow the programmer did not write: "No unauthored control flow, ever. No collection point, no implicit refcount, no injected yield, no scheduler tick" (`Mettle/docs/ideology.md` VII.7). The async runtime Mettle used to ship was deleted for this reason in May 2026 (`93810d97`). V.6 says the execution model, "an actor mailbox" included, is something a program builds in Mettle while the compiler checks its properties.

So Mettle replaces runtime preemption with compile-time proof. A message handler runs to completion and returns to the scheduler. The return is the yield point, and the programmer wrote it. The compiler proves the handler is bounded and never blocks. This works with today's compiler:

```mettle
effect Blocking;
effect CpuPool;

extern fn read_blocking(fd: int32) -> int32 with Blocking = "read";

// Runs on a normal scheduler: proven bounded, proven non-blocking.
fn counter_handle(s: Counter*, m: Msg*) -> int32 forbids Blocking where cycles < 200 {
  if (m->kind == 1) { s->total = s->total + m->amount; }
  return 0;
}

// Long work: only reachable from a thread that provides CpuPool.
fn crunch(n: int64) -> int64 requires CpuPool { ... }
```

Each violation fails the build, checked with `Mettle/bin/mettle`:

| Mistake | Result |
|---|---|
| The handler calls `read_blocking` | `F0001: 'counter_handle' forbids 'Blocking' and performs it` |
| The handler loops over a count from the message | `D0002: ... its longest path cannot be bounded` |
| `main` calls `crunch` directly | `F0002: 'main' reaches a function that requires 'CpuPool' ... main -> crunch` |

This is stronger than BEAM. On BEAM a NIF marked as the wrong kind stalls a scheduler at run time, and nothing catches it. In Mettle the same mistake is a compile error.

## What Mettle has and lacks

| Has | Lacks |
|---|---|
| OS threads (clone + futex), int32 atomics, spin locks, `parallel_range` | Host atomics wider than 32 bits, with acquire/release ordering |
| Effects with `requires`/`provides` checked through function types (F0003) | Blocking annotations: `Sleep` and `Wait*` are declared `with none`; `recv`/`accept` have no clause |
| `where cycles < N` proven across calls | A stack-depth bound (only needed for stackful processes) |
| `std/arena`: free a whole region in one call | A proof that a value is uniquely owned after a send (M0122 catches only writes through the handed local) |
| `@swappable` slots that swap at `quiesce;`, in release, with no compiler present | Swaps at module granularity with versions |
| `mettle live` with layout conversion and undo (x86-64) | Recovery that restarts work: live recovery waits for a patch |
| A crash handler with backtraces | Guard pages on thread stacks, a per-thread `sigaltstack`, a per-thread fault flag (a worker stack overflow exits 139 with no report) |
| epoll through `syscall`; `raize_web` already runs an epoll hub with an MPSC ring | Nonblocking sockets on Linux in `std/net`, io_uring bindings |
| `@generate` that writes encoders from struct reflection | A version-stable type digest for the wire |
| GPU `dispatch` on streams | Completion polling (`cuEventQuery` is not bound); foreign libraries work only on the main thread on Linux |

## What to take

| From BEAM/OTP | Decision | In Mettle |
|---|---|---|
| Process with its own heap | Change | An actor is a header, its state, two mailboxes and an arena. It has no stack of its own, so death frees the arena in one call |
| Reduction preemption | Replace | Proven bounded handlers (above). Unbounded work moves to the CPU class or splits itself by sending itself a continue message |
| Dirty CPU / IO schedulers, NIFs | Change | Work classes checked by effects: Normal, Io, Cpu, Gpu (below). There is no NIF boundary, because all code is native already |
| Per-core run queues, stealing, balancing | Take | Stealing moves a whole actor between messages, never in the middle of a handler |
| Signal queue, per-sender ordering | Take | Ordering is FIFO per sender and receiver, as on BEAM |
| Copy-on-send | Change | Copy into the receiver's arena with generated encoders. Large data goes as a refcounted immutable buffer. Zero-copy moves wait for the ownership proof |
| Unbounded mailboxes, selective receive | Leave | Mailboxes are bounded and `send` reports `Full`. A reply is matched by request id in O(1), not by scanning the mailbox |
| Links, monitors, exit signals, `trap_exit`, aliases | Take | The semantics are kept as they are, with exits and downs delivered as typed messages |
| Timer wheels per scheduler | Take | A timeout arrives as a message |
| Ports, drivers, readiness-only IO | Change | Completion IO per scheduler: io_uring on Linux, IOCP on Windows, kqueue on macOS, with epoll as the fallback |
| Two code versions plus purge | Change | Swap an actor's handler table at the `quiesce;` between messages. Because no actor has a frame parked in old code between messages, there is nothing to purge |
| ETS | Later | A shared table type with lock-free reads, once the core works |
| proc_lib sync start, `sys` control messages | Take | Start returns only after init acks. Control messages (suspend, code change, state, stop) get their own high-priority mailbox |
| gen_server call: monitor + id + timeout | Take | Typed reply token. A late reply is dropped. Errors distinguish no process, node down, timeout and exited |
| Supervisor: strategies, intensity, ordered start, reverse shutdown | Take | Add restart backoff, which OTP lacks |
| Escalation to node exit, then `heart` | Take | A small watchdog process, or systemd, restarts the node |
| Releases, appup, relup | Change | Rolling node replacement first, A/B with rollback second, in-place swap where the state migration is checked |
| `pg` process groups | Take | Each node is the only writer of its own entries, so merges never conflict |
| `erpc` | Take | Tri-state errors: did not run, may have run, ran and failed |
| Full mesh, `net_ticktime`, `global`, `dist_ac`, MD5 cookie, epmd, mnesia | Leave | Use on-demand connections, SWIM membership, a Raft registry with leases and fencing, and authenticated encrypted links |
| Crash reports, system monitor, tracing | Take | Each actor records its parent, ancestors, entry point and last message. Causal trace ids cross nodes |

## Design

### Node, actors, schedulers

A node is one OS process. The program starts it explicitly by calling something like `alph_node_start(config)`. Nothing runs before that call, and a program that never imports the library links none of it (charter V.3: consented, excisable).

An actor is a state struct plus a typed message enum plus one handler function. The library's dispatch loop is ordinary Mettle code:

```text
loop:
  pick actor from this scheduler's run queue (steal if empty)
  record recovery point
  run up to K messages through its handler
  quiesce;          // staged code swaps land here and only here
```

Scheduler threads are one per core, and each owns its run queue, timer wheel and IO ring. Every handler receives a `Ctx*` for the current scheduler, so the design needs no thread-local storage.

Pids are 64 bits locally: a table index plus a serial. Remote pids add the node id and its creation number, as on BEAM, so a pid from an old incarnation of a node is rejected.

### Work classes

| Class | Runs on | Effect contract | Use |
|---|---|---|---|
| Normal | Scheduler threads | `forbids Blocking`, `where cycles < N` | State machines, protocol handling, routing |
| Io | IO pool threads | `requires IoPool` | Blocking calls that have no completion form: DNS, foreign libraries, files where io_uring is missing |
| Cpu | CPU pool threads | `requires CpuPool` | Long computation, `parallel_range`. The OS schedules these threads |
| Gpu | The GPU owner thread (the main thread on Linux) | `requires GpuOwner` | Kernel launches. Completion comes back as a message |

Most IO never touches the Io pool. A Normal handler submits a read or write to its scheduler's ring and returns. The completion arrives as a message to that actor.

A library `@rule` closes the gap that effects leave open: an extern with no `with` clause reachable from a Normal handler is refused. It must declare `with none`, `with Blocking`, or a class.

### Memory and messages

Each actor allocates from its own arena. A message is copied into the receiver's arena by an encoder that `@generate` writes from the message struct. The same encoder writes the network format, so local and remote sends share one code path. Buffers over a size threshold are sent as a refcounted immutable `Bin`: the receiver gets a reference, not a copy.

Each actor has a memory quota. Going over it kills the actor, not the node.

### Failure

An actor fails when its handler returns `Stop(reason)` or hits a trap: bounds, divide, an assertion, stack overflow, or a fault. Before each handler runs, the scheduler saves a recovery point with a `@naked` register save. The library registers itself through the runtime's existing export `mettle_crash_set_live_recovery(point, wait, jump)`, which every trap and fault already consults. The charter asks for exactly this ("a chosen panic boundary", V.4) and lists the trap handler as replaceable (V.3.4).

A spike confirmed recovery from a bounds trap, a null dereference and a divide by zero in `-s`, `-s -O` and `-s --release`, with the normal crash report printed for each. Two limits come from the compiler as it is:
- Programs must be built with `-s`. Without it, inserted traps compile to an inline `puts` + `exit` that no hook can catch. Signal faults recover either way.
- `--safe` is not supported for now. Its shadow call stack is not unwound by the jump, and `--safe` already rejects `std/alloc` memory on Linux.

On a trap, the hook resumes at that point and the scheduler:

1. marks the actor dead with the trap kind, address and backtrace;
2. frees the actor's arena;
3. sends exit signals to linked actors and down messages to monitors.

Restoring the recovery point is sound only if the handler held nothing outside its arena:
- Handlers take no locks, which a rule enforces.
- A trap inside code with `asm` or an unannotated extern on the stack escalates to a node restart. This matches BEAM, where a NIF crash takes down the VM.

Healing comes in two kinds, and the difference is only where it is defined.

**Passive healing** is defined in a supervisor spec. The actor crashes and exits, its links and monitors see it, and the supervisor starts it again under a new pid. Supervisors are library actors with OTP's semantics: one_for_one, one_for_all and rest_for_one; permanent, transient and temporary children; restart intensity over a period, plus backoff; start in order, waiting for each child's init ack; shutdown in reverse with a deadline, then a kill. A supervisor that gives up exits with `ALPH_SHUTDOWN`, so its own supervisor sees it. When a top supervisor gives up, the node exits and the watchdog restarts it.

**Proactive healing** is defined on the actor: it attaches a medic, a small sibling actor, from its INIT handler. When the actor crashes, the runtime does not free it. It holds it in place:
- same pid, links and monitors;
- its mailbox kept, and new messages still queue;
- its state as the crash left it.

The medic's repair function gets the reason, that state and the message being handled. It answers resume, retry the message, reset to the state at attach time, or fail. Only fail is visible to anyone else: the actor exits and passive healing takes over. BEAM cannot offer this, because a dead process's heap is gone. Repairs past the medic's limit per period count as fail. If the medic dies, the actor runs on and its next crash is passive.

### IO

Each scheduler owns one ring and batches submissions once per turn:
- Linux: io_uring with registered buffers.
- Windows: IOCP.
- macOS: kqueue.
- epoll is the portable fallback.

Actors stay on the scheduler that owns their sockets, and stealing only takes actors with no pending IO. This is the thread-per-core shape behind the fastest servers, and Mettle can do it without a GC pause or a VM between the code and the ring. `raize_web`'s epoll hub is the first thing to port onto it.

### Hot upgrade

| Level | Mechanism | When |
|---|---|---|
| One actor type | Stage a new handler table and swap it at the next `quiesce;`. The actor is suspended, its state and queued messages are migrated, and it resumes. The migration is generated by matching layouts by field name, as `mettle_live_convert` already does, or written by hand when the layout changed in other ways. `mettle swap-check` gates it | Fixes, behaviour changes |
| Whole node | `mettle live` (exists, x86-64) | Development, emergency patches |
| Release | Drain a node, hand its actors and registrations off, start the new version, rejoin. Keep A/B with rollback | Normal production deploys |

Rolling replacement is the default for zero downtime because it handles any change. In-place swap is the fast path for changes whose migration the compiler checked.

### Distribution

| Concern | Choice |
|---|---|
| Transport | TCP with Noise_XX (mutual authentication, encryption). Node identity is a static key. TLS for outside clients later |
| Format | The generated encoders. The handshake exchanges a schema digest per message type, taken from the textual layout descriptors `mettle live` already produces, so a mismatched type is refused or converted, never misread |
| Topology | Connect on demand, with no transitive auto-connect |
| Membership and failure detection | SWIM gossip with suspicion, instead of pairwise ticks |
| Ordering | FIFO per sender and receiver pair. Signals (exit, down, control) travel on their own lane so bulk data cannot block them |
| Backpressure | Credit-based flow control per connection |
| Remote links and monitors | BEAM semantics: losing the node fires every link and monitor with `noconnection` |
| Names | Local registry per node; `pg`-style groups across the cluster |
| Unique names, leaders, failover | A Raft-replicated registry with leases and fencing tokens. An application fails over when its lease expires, and every side effect carries its fencing token |
| Remote calls | `erpc` semantics with tri-state errors |

## What the library does instead of changing Mettle

| Need | In the library |
|---|---|
| 64-bit and pointer atomics with ordering | `@naked export` functions: `lock cmpxchg`, `lock xadd`, plain `mov` loads and stores under x86 TSO; `ldar`, `stlr`, `ldaxr`, `stlxr` on ARM64. Each operation is a call, not an inlined instruction |
| Trap recovery | `mettle_crash_set_live_recovery` callbacks plus a `@naked` register save (proven by the spike above) |
| Guard pages and `sigaltstack` | Each scheduler thread protects the lowest page of its stack and installs its own alternate signal stack through `syscall`. The runtime already sets `SA_ONSTACK` on its handlers |
| `Blocking` effect | The library declares `effect Blocking`, its own annotated syscall wrappers, and a `@rule` refusing unannotated or known-blocking externs reachable from a Normal handler |
| Nonblocking sockets, epoll, io_uring | Through the `syscall` builtin |
| GPU completion polling | The library declares `cuEventQuery` itself |

Upstream fixes that would help later but block nothing:
- a per-thread "already in handler" flag, since today two simultaneous crashes on different threads end the node;
- host atomic intrinsics, so atomics inline;
- `--safe` support for `std/alloc`, and a way to unwind its call stack;
- recognizing a Mettle-bodied spawn as a task boundary, then extending M0122 to any use or free after a send. This is the ownership proof zero-copy moves need;
- a wire digest with a written spec, stable across compiler versions;
- the `__acrt_iob_func` link failure in `std/gpu` on Linux.

## Build order

| Phase | Builds | Done when |
|---|---|---|
| 0 | Library foundations: atomics, scheduler threads with guard page and `sigaltstack`, trap recovery, the `Blocking` effect and rule, nonblocking sockets and epoll | A worker thread's stack overflow and traps are recovered; an int64 CAS loop is correct under stress in debug and release |
| 1 | Single node: actors, bounded mailboxes, schedulers with stealing, timers, `call`, links, monitors, trap containment, arenas | 1M idle actors fit in memory; a ping-pong benchmark beats BEAM on the same machine; a trap in one actor leaves the node running; debug and release agree |
| 2 | Work classes and IO rings; port the `raize_web` hub | No Normal handler can block (build-time check); HTTP and WebSocket benchmarks against the current `raize_web` |
| 3 | Supervisors, server and state-machine behaviours, crash reports, watchdog | A chaos test that kills random actors converges back to the same tree |
| 4 | Hot upgrade per actor type; rolling release with mbuild | Upgrade under load with zero failed requests; state migration checked |
| 5 | Distribution: Noise transport, wire format, remote pids, links and monitors, SWIM, `pg`, `erpc`, flow control | A three-node cluster survives killing any node; partitions heal |
| 6 | Raft registry, leases, application failover and takeover | A failover test under partition never runs two leaders' side effects |

Phases 0 and 1 are where the risk is. If proven-bounded handlers are too restrictive in real code, it will show in phase 1, before any distribution work is spent.

### Status

Each test below passes under `./check.sh` in debug and release, and passed 40 more runs of each binary in both modes.

| Built | Tested by |
|---|---|
| Atomics | `t_atomic`: contended add and CAS, spin-wait visibility |
| Trap and fault recovery, guarded scheduler threads | `t_recover`: bounds, null, divide and stack overflow on a worker and on main |
| Bounded mailbox, intrusive queue | `t_mailbox`: four producers, per-sender order, full refusal |
| Node: spawn, send, links, monitors, exit signals, requests with timeout, timers, crash to exit | `t_node`: 100k ping-pong round trips, 20k spawns with slot reuse |
| Exits and downs ordered after earlier messages | `t_order`: 2,000 rounds of result-then-exit |
| Supervisors | `t_supervisor`: every strategy, restart types, intensity, ordered start with ack, reverse shutdown with kill, backoff |
| Medics | `t_heal`: resume, retry and reset on the same pid; fail, over-limit and no-medic cases go to the supervisor |

Not built yet: stealing between schedulers, the IO ring, the work-class rule, hot upgrade, distribution. ARM64, Windows and macOS are not built either; the asm and syscalls are x86-64 Linux.

## Open decisions

1. **Stackful processes.** These would allow blocking-style `receive` deep inside a call. The recommendation is to leave them out of the core. They cost a stack per process, need the missing stack bound, and break live mode's one-stack-per-thread tables. Revisit them after phase 3 if run-to-completion handlers prove awkward.
2. **Crypto for Noise** is written in Mettle (X25519, ChaCha20-Poly1305, BLAKE2s), following the rule of no C unless Mettle cannot do it. It needs test vectors and constant-time review before it carries real traffic.

## Layout

The library is called alph: imports are `"alph/<module>"`, exports `alph_*`, types `Alph*`, constants `ALPH_*`.

```text
alph/
  README.md
  DESIGN.md
  check.sh             checks docs/api.md, then builds and runs every test and example in debug and release
  mettle.deps          alph=./src
  src/
    alph.mettle        the runtime in one import
    core/
      node.mettle      actors, schedulers, messages, links, monitors, requests, timers, held crashes
      mailbox.mettle   messages and the bounded mailbox
      queue.mettle     intrusive multi-producer queue
    heal/
      supervisor.mettle  passive healing
      medic.mettle       proactive healing
    sys/               the x86-64 Linux layer
      linux.mettle     syscall numbers and flags
      atomic.mettle    64-bit atomics
      clock.mettle     monotonic time, futex
      thread.mettle    threads with a guard page and their own signal stack; CPU count
      recover.mettle   recovery points over the runtime's crash hook
  docs/
    guide.md           how to use the runtime
    api.md             every export with its doc comment; built by tools/apidoc.sh
  tools/               apidoc.sh and apidoc.awk
  tests/               t_*.mettle, self-checking programs
  examples/            counter, request, supervised, medic; run by check.sh
  reference_model/     local research: OTP source and notes; not in git
```

Later modules get their own directories: `io/` for the IO ring, `dist/` for distribution. Code for another platform goes beside `sys/`.
