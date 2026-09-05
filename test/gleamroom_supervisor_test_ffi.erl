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
-export([first_child_pid/1, third_child_pid/1]).

first_child_pid(SupervisorPid) ->
    wait_for_nth_child_pid(SupervisorPid, 1, 50).

%% #78 の one_for_one 検証用: registry(1番目の子)を kill しても
%% mist(3番目の子、#279 で poker_registry が2番目に追加されて以降)が
%% 巻き添えで再起動されていないことを確認するために使う。
third_child_pid(SupervisorPid) ->
    wait_for_nth_child_pid(SupervisorPid, 3, 50).

wait_for_nth_child_pid(_SupervisorPid, _N, 0) ->
    {error, nil};
wait_for_nth_child_pid(SupervisorPid, N, Retries) ->
    try supervisor:which_children(SupervisorPid) of
        Children when length(Children) >= N ->
            {_Id, Child, _Type, _Modules} = lists:nth(N, Children),
            case is_pid(Child) of
                true -> {ok, Child};
                false ->
                    timer:sleep(20),
                    wait_for_nth_child_pid(SupervisorPid, N, Retries - 1)
            end;
        _ ->
            timer:sleep(20),
            wait_for_nth_child_pid(SupervisorPid, N, Retries - 1)
    catch
        exit:_ ->
            {error, nil}
    end.
