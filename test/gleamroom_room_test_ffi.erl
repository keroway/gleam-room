%% Test-only helper used by websocket_integration_test.gleam (#532) to make a
%% room actor unresponsive **without killing it**, simulating the "stuck but
%% alive" case that `room.dispatch`'s 1000ms timeout (see call.gleam) is
%% meant to survive. `process.kill` (already used by
%% `ws_rejoins_after_room_actor_dies_test`) instead terminates the actor, so
%% there would be nothing left alive to later detect the connection's death
%% via `SessionDown` — the exact cleanup path #532 needs covered.
%%
%% `erlang:suspend_process/1` stops the target process from being scheduled
%% (it stays alive and keeps its mailbox) until `erlang:resume_process/1` is
%% called; messages sent to it in the meantime are queued, not lost.
-module(gleamroom_room_test_ffi).
-export([suspend/1, resume/1]).

suspend(Pid) ->
    true = erlang:suspend_process(Pid),
    nil.

resume(Pid) ->
    true = erlang:resume_process(Pid),
    nil.
