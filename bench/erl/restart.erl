%% restart: a one_for_one supervisor with one permanent child. The child
%% crashes (divide by zero) when told to, the supervisor restarts it, and the
%% new child reports from its init. Repeated C times, one at a time. Each
%% cycle is timed from just before the crash request is sent to the moment
%% the new child's report is received. Metrics: restart_p50_us,
%% restart_p99_us. See bench/README.md.
%%
%% A real supervisor (this module is its callback module), with a restart
%% intensity of a million restarts a second so it never gives up. Logging is
%% switched off, because a crashing process otherwise formats a crash report
%% and the supervisor a child report for every one of the C crashes, and the
%% alph runtime logs nothing of the kind.
-module(restart).
-behaviour(supervisor).
-export([main/0, init/1, start_child/1, child_init/1]).

-define(C, 2000).

main() ->
    logger:set_primary_config(level, none),
    {ok, Sup} = supervisor:start_link(?MODULE, self()),
    Child = receive {up, Pid} -> Pid end,
    Samples = cycles(Sup, Child, ?C, []),
    Sorted = list_to_tuple(lists:sort(Samples)),
    P50 = element(?C div 2 + 1, Sorted),
    P99 = element(?C * 99 div 100 + 1, Sorted),
    io:format("RESULT restart restart_p50_us=~b restart_p99_us=~b~n",
              [P50 div 1000, P99 div 1000]).

cycles(_Sup, _Child, 0, Acc) ->
    Acc;
cycles(Sup, Child, N, Acc) ->
    T0 = erlang:monotonic_time(nanosecond),
    Child ! {crash, 0},
    receive
        {up, Child} ->
            io:format("FAIL the restarted child has the old pid~n"),
            halt(1);
        {up, New} ->
            T1 = erlang:monotonic_time(nanosecond),
            cycles(Sup, New, N - 1, [T1 - T0 | Acc]);
        {'EXIT', Sup, Reason} ->
            io:format("FAIL the supervisor exited with reason ~p~n", [Reason]),
            halt(1)
    end.

%% supervisor callback
init(Boss) ->
    Flags = #{strategy => one_for_one, intensity => 1000000, period => 1},
    Child = #{id => child, start => {?MODULE, start_child, [Boss]}, restart => permanent},
    {ok, {Flags, [Child]}}.

start_child(Boss) ->
    proc_lib:start_link(?MODULE, child_init, [Boss]).

child_init(Boss) ->
    Boss ! {up, self()},
    proc_lib:init_ack({ok, self()}),
    child_loop().

child_loop() ->
    receive
        {crash, Divisor} ->
            _ = 100 div Divisor,
            child_loop()
    end.
