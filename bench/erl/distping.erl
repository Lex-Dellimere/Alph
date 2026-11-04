%% distping: two nodes on one machine, over TCP on 127.0.0.1.
%%
%%   1. Round trip: the client sends one message to a remote echo process and
%%      waits for the reply, K times; each round trip is timed on its own.
%%      Metrics: rtt_p50_ns, rtt_p99_ns.
%%   2. One way: the client sends N one-word messages to a remote sink, which
%%      acks every ACK_EVERY messages, so the client keeps at most WINDOW in
%%      flight. Done when the client has the sink's ack for all N. Metric:
%%      msgs_per_s.
%%
%% See bench/README.md.
%%
%% Two real BEAM nodes, started by bench/run.sh with `erl -sname` and the same
%% cookie: the server node runs serve/0 and registers `echo` and `sink`, the
%% client node runs main/0, which finds the server through the DISTPING_PEER
%% environment variable and sends with {Name, Node} ! Msg. run.sh stops the
%% server node afterwards (main/0 also asks it to halt).
%%
%% NOTE: Erlang distribution is NOT encrypted by default (no `-proto_dist
%% inet_tls`), so these BEAM numbers are for cleartext traffic. The alph side
%% is Noise encrypted and cannot turn that off, so the comparison is encrypted
%% alph against cleartext BEAM.
%%
%% Before timing, the nodes are connected and WARM round trips are made that
%% are not timed (the alph twin does the same).
-module(distping).
-export([main/0, serve/0]).

-define(K, 50000).
-define(WARM, 1000).
-define(N, 500000).
-define(WINDOW, 10000).
-define(ACK_EVERY, 1000).

%% ---- the server node ----

serve() ->
    register(echo, spawn_link(fun echo/0)),
    register(sink, spawn_link(fun sink/0)),
    receive stop -> ok end.

echo() ->
    receive
        {ping, From, N} ->
            From ! {pong, N},
            echo()
    end.

sink() ->
    receive
        {start, Client} -> sink(Client, 0)
    end.

sink(Client, Count) ->
    receive
        d ->
            C = Count + 1,
            case C rem ?ACK_EVERY of
                0 -> Client ! {ack, C};
                _ -> ok
            end,
            sink(Client, C)
    end.

%% ---- the client node ----

main() ->
    Peer = list_to_atom(os:getenv("DISTPING_PEER")),
    ok = wait_for_peer(Peer, 200),
    Echo = {echo, Peer},
    Sink = {sink, Peer},
    Samples = rtt(Echo, 0, []),
    Sorted = list_to_tuple(lists:sort(Samples)),
    P50 = element(?K div 2 + 1, Sorted),
    P99 = element(?K * 99 div 100 + 1, Sorted),
    Sink ! {start, self()},
    T0 = erlang:monotonic_time(nanosecond),
    oneway(Sink, 0, 0),
    T1 = erlang:monotonic_time(nanosecond),
    PerS = ?N * 1000000000 div (T1 - T0),
    rpc:cast(Peer, erlang, halt, []),
    io:format("RESULT distping rtt_p50_ns=~b rtt_p99_ns=~b msgs_per_s=~b~n", [P50, P99, PerS]).

%% Connects to the server node and waits until both names are registered.
wait_for_peer(_Peer, 0) ->
    io:format("FAIL the server node never came up~n"),
    halt(1);
wait_for_peer(Peer, Tries) ->
    case net_kernel:connect_node(Peer) of
        true ->
            case rpc:call(Peer, erlang, whereis, [sink]) of
                Pid when is_pid(Pid) ->
                    case rpc:call(Peer, erlang, whereis, [echo]) of
                        P when is_pid(P) -> ok;
                        _ -> retry(Peer, Tries)
                    end;
                _ -> retry(Peer, Tries)
            end;
        _ -> retry(Peer, Tries)
    end.

retry(Peer, Tries) ->
    timer:sleep(50),
    wait_for_peer(Peer, Tries - 1).

%% WARM untimed round trips, then K timed ones. Returns the K samples.
rtt(_Echo, N, Acc) when N =:= ?WARM + ?K ->
    Acc;
rtt(Echo, N, Acc) ->
    T0 = erlang:monotonic_time(nanosecond),
    Echo ! {ping, self(), N},
    receive
        {pong, N} ->
            T1 = erlang:monotonic_time(nanosecond),
            case N >= ?WARM of
                true -> rtt(Echo, N + 1, [T1 - T0 | Acc]);
                false -> rtt(Echo, N + 1, Acc)
            end
    end.

%% Sends N one-word messages, never more than WINDOW unacknowledged.
oneway(_Sink, ?N, ?N) ->
    ok;
oneway(Sink, Sent, Acked) when Sent < ?N, Sent - Acked < ?WINDOW ->
    Sink ! d,
    oneway(Sink, Sent + 1, Acked);
oneway(Sink, Sent, _Acked) ->
    receive
        {ack, A} -> oneway(Sink, Sent, A)
    end.
