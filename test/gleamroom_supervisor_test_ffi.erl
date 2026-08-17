%% Minimal helper used only by supervisor_test.gleam (#190) to reach into a
%% running `static_supervisor` (which itself wraps OTP's `supervisor` module)
%% and fetch the pid of its first child. gleam_otp's `Supervisor` type is
%% opaque and exposes no `which_children`-style API, so the test needs a
%% direct `supervisor:which_children/1` call to repeatedly crash the
%% registry child and force `restart_tolerance` to be exceeded.
%%
%% Immediately after a kill, `which_children` can transiently report the
%% child as `restarting` (or the not-yet-removed old pid) before the actual
%% restart completes, so this retries until a real pid is observed. Once the
%% supervisor itself has exceeded its restart_tolerance and starts shutting
%% down, the call eventually fails with `exit` — that's surfaced as
%% `{error, nil}` rather than crashing the caller.
-module(gleamroom_supervisor_test_ffi).
-export([first_child_pid/1]).

first_child_pid(SupervisorPid) ->
    wait_for_child_pid(SupervisorPid, 50).

wait_for_child_pid(_SupervisorPid, 0) ->
    {error, nil};
wait_for_child_pid(SupervisorPid, Retries) ->
    try supervisor:which_children(SupervisorPid) of
        [{_Id, Child, _Type, _Modules} | _] when is_pid(Child) ->
            {ok, Child};
        _ ->
            timer:sleep(20),
            wait_for_child_pid(SupervisorPid, Retries - 1)
    catch
        exit:_ ->
            {error, nil}
    end.
