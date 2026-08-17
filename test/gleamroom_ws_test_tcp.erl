%% Minimal loopback TCP client used only by the WebSocket integration test
%% (test/gleamroom/websocket_integration_test.gleam, #158). `gleam_erlang`
%% does not expose raw sockets, and pulling in a socket library just for this
%% one test file would violate the "keep the dependency set minimal" policy
%% in CLAUDE.md, so this thin `gen_tcp` wrapper lives here instead.
%%
%% Every function returns Gleam-shaped terms directly (`{ok, _}` / `{error,
%% Binary}` / `nil`) so the Gleam side can declare plain `Result`/`Nil`
%% external types without needing extra decoding.
-module(gleamroom_ws_test_tcp).
-export([connect/1, send/2, recv/2, close/1]).

connect(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {packet, 0}, {active, false}]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

recv(Socket, TimeoutMs) ->
    case gen_tcp:recv(Socket, 0, TimeoutMs) of
        {ok, Packet} -> {ok, Packet};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.

format_reason(Reason) when is_binary(Reason) ->
    Reason;
format_reason(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).
