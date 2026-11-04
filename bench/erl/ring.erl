%% ring: R processes in a ring, one token travels the ring T times (R * T
%% hops). Timing starts when the token is sent to the first process, after
%% the ring is built, and stops when that process has it back for the last
%% time. Metrics: hops_per_s, ns_per_hop. See bench/README.md.
-module(ring).
-export([main/0]).

-define(R, 10000).
-define(T, 100).
-define(HOPS, 1000000).

main() ->
    Boss = self(),
    %% Back to front: each member is spawned already knowing the next one.
    %% The tail, spawned first, is pointed at the head last.
    Tail = spawn(fun() -> tail(Boss) end),
    Head = build(Boss, Tail, ?R - 2),
    Tail ! {link, Head},
    receive linked -> ok end,
    T0 = erlang:monotonic_time(nanosecond),
    Head ! {token, 0},
    Laps = receive {done, L} -> L end,
    T1 = erlang:monotonic_time(nanosecond),
    case Laps of
        ?T ->
            Elapsed = T1 - T0,
            io:format("RESULT ring hops_per_s=~b ns_per_hop=~b~n",
                      [?HOPS * 1000000000 div Elapsed, Elapsed div ?HOPS]);
        _ ->
            io:format("FAIL the token made ~b laps, wanted ~b~n", [Laps, ?T]),
            halt(1)
    end.

%% Spawns N plain members in front of Next, then the head. Returns the head.
build(Boss, Next, 0) ->
    spawn(fun() -> head(Boss, Next, 0) end);
build(Boss, Next, N) ->
    build(Boss, spawn(fun() -> member(Next) end), N - 1).

member(Next) ->
    receive
        {token, Hops} ->
            Next ! {token, Hops + 1},
            member(Next)
    end.

tail(Boss) ->
    receive
        {link, Next} ->
            Boss ! linked,
            member(Next)
    end.

head(Boss, Next, Laps) ->
    receive
        {token, ?HOPS} ->
            Boss ! {done, Laps};
        {token, Hops} ->
            Next ! {token, Hops + 1},
            head(Boss, Next, Laps + 1)
    end.
