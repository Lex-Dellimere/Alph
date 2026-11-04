%% pingpong: two processes, on different schedulers, exchange a message K
%% times. Each round trip is timed on its own, from just before the ping is
%% sent to the moment the pong is received. Metrics: rtt_p50_ns, rtt_p99_ns,
%% round_trips_per_s (K over the sum of the round trips). See bench/README.md.
-module(pingpong).
-export([main/0]).

-define(K, 200000).

main() ->
    Boss = self(),
    %% Pinned to two different schedulers (always more than one when the
    %% machine has more than one CPU), as the node places the alph pair.
    Other = case erlang:system_info(schedulers) of
                1 -> 1;
                _ -> 2
            end,
    Ponger = spawn_opt(fun ponger/0, [{scheduler, 1}]),
    spawn_opt(fun() -> pinger(Boss, Ponger) end, [{scheduler, Other}]),
    Samples = receive {samples, S} -> S end,
    Total = lists:sum(Samples),
    Sorted = list_to_tuple(lists:sort(Samples)),
    P50 = element(?K div 2 + 1, Sorted),
    P99 = element(?K * 99 div 100 + 1, Sorted),
    io:format("RESULT pingpong rtt_p50_ns=~b rtt_p99_ns=~b round_trips_per_s=~b~n",
              [P50, P99, ?K * 1000000000 div Total]).

ponger() ->
    receive
        {ping, From, N} ->
            From ! {pong, N},
            ponger()
    end.

pinger(Boss, Ponger) ->
    Boss ! {samples, loop(Ponger, 0, [])}.

loop(_Ponger, ?K, Acc) ->
    Acc;
loop(Ponger, N, Acc) ->
    T0 = erlang:monotonic_time(nanosecond),
    Ponger ! {ping, self(), N},
    receive
        {pong, N} ->
            T1 = erlang:monotonic_time(nanosecond),
            loop(Ponger, N + 1, [T1 - T0 | Acc])
    end.
