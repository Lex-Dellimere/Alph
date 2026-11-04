%% pairs: S independent sender/receiver pairs, each sender sending M messages
%% to its receiver with a credit window of WINDOW (the receiver acks every
%% WINDOW messages). All pairs run at once. Timing starts when the senders
%% are told to go and stops when every receiver has all its messages.
%% Metric: msgs_per_s (S * M over the elapsed time). See bench/README.md.
-module(pairs).
-export([main/0]).

-define(S, 1000).
-define(M, 1000).
-define(WINDOW, 32).

main() ->
    Boss = self(),
    Receivers = [spawn(fun() -> receiver(Boss, 0) end) || _ <- lists:seq(1, ?S)],
    Senders = [spawn(fun() -> receive go -> sender(R, 0, 0) end end) || R <- Receivers],
    T0 = erlang:monotonic_time(nanosecond),
    [Pid ! go || Pid <- Senders],
    wait(?S),
    T1 = erlang:monotonic_time(nanosecond),
    Elapsed = T1 - T0,
    io:format("RESULT pairs msgs_per_s=~b~n", [?S * ?M * 1000000000 div Elapsed]).

wait(0) ->
    ok;
wait(N) ->
    receive
        done -> wait(N - 1);
        {fail, Why} ->
            io:format("FAIL ~s~n", [Why]),
            halt(1)
    end.

sender(_Receiver, ?M, _Acked) ->
    ok;
sender(Receiver, Sent, Acked) when Sent - Acked < ?WINDOW ->
    Receiver ! {data, self(), Sent},
    sender(Receiver, Sent + 1, Acked);
sender(Receiver, Sent, _Acked) ->
    receive {ack, Acked} -> sender(Receiver, Sent, Acked) end.

receiver(Boss, ?M) ->
    Boss ! done;
receiver(Boss, Got) ->
    receive
        {data, From, Got} ->
            case (Got + 1) rem ?WINDOW of
                0 -> From ! {ack, Got + 1};
                _ -> ok
            end,
            receiver(Boss, Got + 1);
        {data, _From, _Other} ->
            Boss ! {fail, "a message arrived out of order"}
    end.
