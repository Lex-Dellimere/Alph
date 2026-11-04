%% fanin: P producers (P = number of schedulers) each send M one-word
%% messages to one consumer. Done when the consumer has P * M. Timing starts
%% when the producers are told to go and stops when the consumer has the last
%% message. Metric: msgs_per_s. See bench/README.md.
%%
%% The producers just send; a mailbox here is unbounded, so there is no
%% backpressure to respect. The consumer is the main process. Its queue is
%% kept off the heap (message_queue_data off_heap), the standard setting for
%% a process that is flooded: with the default, every garbage collection
%% walks the whole queue, and the run had not finished after 100 seconds.
-module(fanin).
-export([main/0]).

-define(M, 200000).

main() ->
    process_flag(message_queue_data, off_heap),
    P = erlang:system_info(schedulers),
    Consumer = self(),
    Producers = [spawn(fun() -> producer(Consumer, I) end) || I <- lists:seq(0, P - 1)],
    T0 = erlang:monotonic_time(nanosecond),
    [Pid ! go || Pid <- Producers],
    Counts = consume(P * ?M, erlang:make_tuple(P, 0)),
    T1 = erlang:monotonic_time(nanosecond),
    case [I || I <- lists:seq(1, P), element(I, Counts) =/= ?M] of
        [] ->
            Elapsed = T1 - T0,
            io:format("RESULT fanin msgs_per_s=~b~n", [P * ?M * 1000000000 div Elapsed]);
        [I | _] ->
            io:format("FAIL producer ~b delivered ~b, wanted ~b~n", [I - 1, element(I, Counts), ?M]),
            halt(1)
    end.

%% Counts holds the messages taken from each producer, by producer index + 1.
consume(0, Counts) ->
    Counts;
consume(Left, Counts) ->
    receive
        I ->
            consume(Left - 1, setelement(I, Counts, element(I, Counts) + 1))
    end.

producer(Consumer, I) ->
    receive go -> ok end,
    send(Consumer, I + 1, ?M).

send(_Consumer, _I, 0) ->
    ok;
send(Consumer, I, N) ->
    Consumer ! I,
    send(Consumer, I, N - 1).
