%% spawn: a parent spawns N processes; each sends the parent one message and
%% exits. Done when the parent has all N messages. Metrics: spawns_per_s,
%% ns_per_spawn. See bench/README.md.
%%
%% Like the alph side, the parent keeps at most WINDOW children in flight
%% (spawned, message not yet received). alph needs that because its mailboxes
%% are bounded; here it is the faster way too, since the parent is not
%% flooded with messages while it is still spawning (a plain spawn-all-then-
%% receive loop measured about 2.5 times slower on this machine).
-module(spawn).
-export([main/0]).

-define(N, 200000).
-define(WINDOW, 256).

main() ->
    Parent = self(),
    T0 = erlang:monotonic_time(nanosecond),
    run(Parent, 0, 0),
    T1 = erlang:monotonic_time(nanosecond),
    Elapsed = T1 - T0,
    io:format("RESULT spawn spawns_per_s=~b ns_per_spawn=~b~n",
              [?N * 1000000000 div Elapsed, Elapsed div ?N]).

%% Spawned and Received count the children so far.
run(_Parent, ?N, ?N) ->
    ok;
run(Parent, Spawned, Received) when Spawned < ?N, Spawned - Received < ?WINDOW ->
    spawn(fun() -> Parent ! hello end),
    run(Parent, Spawned + 1, Received);
run(Parent, Spawned, Received) ->
    receive hello -> run(Parent, Spawned, Received + 1) end.
