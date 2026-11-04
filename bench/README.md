# Benchmarks: alph against BEAM

Each workload has an alph program (`bench/<name>.mettle`) and an Erlang twin (`bench/erl/<name>.erl`) that does the same work the idiomatic BEAM way. `bench/run.sh` builds the alph side with `-s --release`, runs both, and prints one table. Numbers are only compared on the same machine in the same run.

Rules for every workload:

- The program prints exactly one result line: `RESULT <name> <metric>=<value> [<metric>=<value> ...]`, where values are integers or decimals, then exits 0. On a failed self-check it prints `FAIL <reason>` and exits 1.
- Timing starts after setup that both sides do the same way (starting the node, spawning a fixed population when the workload is not about spawning) and stops when the last piece of work is confirmed done.
- The alph side uses one scheduler per CPU (`alph_config` default), as the BEAM uses one scheduler per core by default.
- Sizes are constants at the top of each file, the same on both sides.

| Name | Work | Metrics |
|---|---|---|
| `spawn` | A parent spawns N = 200 000 actors, each of which sends the parent one message in INIT and stops. Done when the parent has all N messages. | `spawns_per_s`, `ns_per_spawn` |
| `ring` | R = 10 000 actors in a ring. One token travels the ring T = 100 times (1 000 000 hops). Timing excludes building the ring. | `hops_per_s`, `ns_per_hop` |
| `pingpong` | Two actors, on different schedulers where the runtime allows it, exchange a message K = 200 000 times; each round trip is timed separately. | `rtt_p50_ns`, `rtt_p99_ns`, `round_trips_per_s` |
| `fanin` | P = number of schedulers producer actors each send M = 200 000 one-word messages to one consumer, respecting backpressure (alph: retry on ALPH_FULL after the consumer's ack; Erlang: plain send). Done when the consumer has P*M. | `msgs_per_s` |
| `pairs` | S = 1 000 independent sender/receiver pairs, each sending 1 000 messages with a credit window of 32 (the receiver acks every 32). All pairs run at once. | `msgs_per_s` |
| `restart` | A one-for-one supervisor with one permanent child. The child crashes (divide by zero) on request, the supervisor restarts it, and the new child reports from INIT. Repeated C = 2 000 times, one at a time, with max restart intensity set high enough not to give up. | `restart_p50_us`, `restart_p99_us` |
| `distping` | Two nodes on one machine over TCP on 127.0.0.1. Round trip: the client sends one message to a remote echo actor and waits for the reply, K = 50 000 times (after 1 000 untimed), each timed. One way: the client sends N = 500 000 one-word messages to a remote sink that acks every 1 000, so at most 10 000 are in flight; done when the client has the ack for all N. | `rtt_p50_ns`, `rtt_p99_ns`, `msgs_per_s` |
| `http` | Later, with an HTTP server on alph: many connections, small GET, keep-alive. | `req_per_s`, `p99_us` |

Notes on `distping`:

- **Encryption:** alph's distribution is always Noise encrypted and authenticated (Noise_XXpsk3_25519_ChaChaPoly_SHA256) and cannot be turned off. Erlang distribution is cleartext by default (no `-proto_dist inet_tls`), and the Erlang twin uses the default. So this workload compares encrypted alph against cleartext BEAM; read the ratios with that in mind.
- **Nodes:** the alph twin runs both nodes in one process, each with its own schedulers (as `tests/t_dist.mettle` does). `run.sh` starts the BEAM side as two real nodes (`erl -sname`, one cookie) and stops the server node after each run. Connecting and name lookups are done before timing on both sides.

Not yet: `http`, memory per actor (needs a matching measure on both sides).

## Latest results

2026-11-05, 16 CPUs, Erlang/OTP 27, Mettle v0.18.0, median of 3 runs. A ratio above 1 means alph is better.

| Workload | Metric | alph | BEAM | Ratio |
|---|---|---|---|---|
| spawn | ns_per_spawn | 948 | 1201 | 1.27 |
| ring | ns_per_hop | 519 | 286 | 0.55 |
| pingpong | rtt_p50_ns | 601 | 1322 | 2.20 |
| pingpong | rtt_p99_ns | 942 | 4699 | 4.99 |
| fanin | msgs_per_s | 7.4 M | 13.6 M | 0.54 |
| pairs | msgs_per_s | 57.4 M | 24.5 M | 2.34 |
| restart | restart_p50_us | 65 | 14 | 0.22 |
| distping | rtt_p50_ns | 15960 | 20518 | 1.29 |
| distping | rtt_p99_ns | 31668 | 52587 | 1.66 |
| distping | msgs_per_s | 170 K | 222 K | 0.77 |

- **distping:** alph's traffic is Noise-encrypted; BEAM's distribution is cleartext by default. Two fixes took alph from 0.26x to 1.29x on latency: idle schedulers now poll their sockets while they spin, and sealing no longer maps and unmaps 64 KiB of scratch per message.

- **pingpong:** alph spawns a child on its parent's scheduler, so both actors share one scheduler here, while the Erlang pair is pinned to two. alph has no pinning API.
- **fanin:** 16 producers into one mailbox contend on its enqueue counter; with 2 producers alph does 14 to 15 M/s. Per-sender lanes are the planned fix (alph/reports/010).
- **restart:** most of alph's time is the Mettle runtime printing a crash report for every fault before alph's recovery runs; without it, about 17 µs.
- **Machine:** a busy desktop. BEAM's numbers vary between runs; this run's BEAM ring was faster than the previous one.
