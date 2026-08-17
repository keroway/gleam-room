import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleamroom
import gleamroom/registry
import gleamroom/room
import gleamroom/wait

/// registry が落ちても supervisor が作り直し、**同じ名前で引き続き使えること**（#23）。
///
/// 以前は registry と web server が `let assert Ok(...)` で個別に起動された
/// 独立プロセスで、親子関係も再起動戦略も無かった。registry が落ちると
/// HTTP は 200 を返し続けるのに join だけが無反応になる。
///
/// 名前を経由しない実装（起動時の subject を握る）だと、再起動後は死んだ
/// プロセスへ送り続けることになる。送信自体はエラーにならないため、
/// 「join しても何も起きない」という形でしか現れない。
pub fn registry_is_restarted_and_reachable_by_name_test() {
  let name = process.new_name("gleamroom_registry_test")
  let subject = process.named_subject(name)

  let assert Ok(_) =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.add(supervision.worker(fn() { registry.start_named(name) }))
    |> supervisor.start

  // 起動直後は名前経由で使える。
  let assert Ok(before) = registry.lookup(subject, registry.room_id("room-sup"))
  assert room.get_snapshot(before) == Ok([])

  let assert Ok(pid) = process.subject_owner(subject)
  process.kill(pid)

  // supervisor が作り直すまで待つ。
  wait.until(
    fn() { process.subject_owner(process.named_subject(name)) != Ok(pid) },
    "registry が再起動する",
  )

  // **同じ名前**で引き続き使える（呼び出し側は subject を取り直していない）。
  let assert Ok(after) = registry.lookup(subject, registry.room_id("room-sup"))
  assert room.get_snapshot(after) == Ok([])

  // 再起動後は新しいプロセスなので、状態は引き継がれない（作り直された証拠）。
  assert before != after
}

/// `RestForOne` を選んだ根拠（`src/gleamroom.gleam` のコメント）である
/// 「registry がクラッシュしたら、後ろに追加した子（web server 相当）も
/// 作り直される」ことそのものを検証する（#95）。
///
/// 以前の唯一のテストは registry 単体を子に持つ supervisor しか組んでおらず、
/// 「後ろの子も巻き添えで再起動される」という `RestForOne` 固有の主張は
/// `OneForOne` でも成立してしまうため検証できていなかった。ここでは registry
/// の後ろにもう一つ子を追加し、registry を kill したときにその子まで
/// 再起動されている（pid が変わっている）ことを確認する。
pub fn rest_for_one_restarts_children_added_after_the_killed_child_test() {
  let registry_name = process.new_name("gleamroom_registry_rfo_test")
  let registry_subject = process.named_subject(registry_name)

  // registry より後ろに登録する「web server 相当」の子。実装は問わないので
  // registry と同じ actor を別名で流用する。
  let after_name = process.new_name("gleamroom_after_child_rfo_test")
  let after_subject = process.named_subject(after_name)

  let assert Ok(_) =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.add(
      supervision.worker(fn() { registry.start_named(registry_name) }),
    )
    |> supervisor.add(
      supervision.worker(fn() { registry.start_named(after_name) }),
    )
    |> supervisor.start

  let assert Ok(registry_pid_before) = process.subject_owner(registry_subject)
  let assert Ok(after_pid_before) = process.subject_owner(after_subject)

  process.kill(registry_pid_before)

  // 両方が作り直されるまで待つ。RestForOne は registry(id0) を再起動する前に
  // after(id1) を shutdown させる必要があり、after 側が exit signal を
  // trap していないため既定の shutdown タイムアウト（5000ms）いっぱいまで
  // かかってから強制 kill される。既定の 2 秒枠（wait.until）では機材やCI
  // 負荷次第でこの区間に収まりきらずフレークするため、ここだけ広めの
  // 枠（20 秒）を明示する。
  wait.until_within(
    fn() {
      case process.subject_owner(registry_subject) {
        Ok(pid) -> pid != registry_pid_before
        Error(_) -> False
      }
    },
    "registry が再起動する",
    1000,
  )
  wait.until_within(
    fn() {
      case process.subject_owner(after_subject) {
        Ok(pid) -> pid != after_pid_before
        Error(_) -> False
      }
    },
    "registry より後ろの子も再起動する（RestForOne の主張）",
    1000,
  )

  let assert Ok(registry_pid_after) = process.subject_owner(registry_subject)
  let assert Ok(after_pid_after) = process.subject_owner(after_subject)

  // registry 自身が作り直された証拠。
  assert registry_pid_before != registry_pid_after
  // **RestForOne 選択の根拠そのもの**: registry の後ろに追加した子も
  // 巻き添えで作り直されている。OneForOne ならここは変わらないはず。
  assert after_pid_before != after_pid_after
}

/// `await_supervisor_exit` が対象 pid の trapped exit を受け取ったときに
/// `on_exit` を呼ぶこと（#189）。`erlang:halt` を直接呼ぶプロダクション経路
/// (`halt_with_failure`) はテストプロセスごと落ちるため検証できないが、
/// 「supervisor の exit をどう検知して何を呼ぶか」という差し替え可能な
/// ロジック自体は `on_exit` を注入して確認できる。
pub fn await_supervisor_exit_calls_on_exit_when_target_pid_exits_test() {
  process.trap_exits(True)
  let done = process.new_subject()
  let target_pid = process.spawn(fn() { process.sleep_forever() })
  process.kill(target_pid)

  gleamroom.await_supervisor_exit(target_pid, fn() { process.send(done, Nil) })

  let assert Ok(Nil) = process.receive(done, 1000)
}

/// 対象以外の pid からの exit では `on_exit` を呼ばず待ち続けること（#190）。
/// 「未知の pid からの exit は無視する」という `await_supervisor_exit` の
/// ドキュメントコメントが主張する再帰分岐そのものを検証する。
pub fn await_supervisor_exit_ignores_exit_of_other_pid_test() {
  process.trap_exits(True)
  let done = process.new_subject()
  let decoy_pid = process.spawn(fn() { process.sleep_forever() })
  let target_pid = process.spawn(fn() { process.sleep_forever() })

  // decoy を先に殺し、対象より前に無関係な trapped exit が届く状況を作る。
  process.kill(decoy_pid)
  wait.until_dead(decoy_pid, "decoy が終了する")
  process.kill(target_pid)

  gleamroom.await_supervisor_exit(target_pid, fn() { process.send(done, Nil) })

  let assert Ok(Nil) = process.receive(done, 1000)
}

/// `gleamroom.start` が組む実際の supervisor 構成
/// (`intensity:2/period:5`、`main` の `trap_exits(True)` +
/// `await_supervisor_exit`) を通しで検証する（#190）。
///
/// これまでの `await_supervisor_exit_*_test` は関数単体を自前で spawn した
/// pid に対して直接呼んでおり、`start` が実際に組む supervisor 構成
/// (`intensity`/`period`) は経由していなかった。ここでは registry 子を
/// `restart_tolerance` の許容回数(2回)を超えて連続 kill し、(a) 供給元の
/// supervisor 自身が shutdown すること、(b) その exit が
/// `await_supervisor_exit` 経由で観測できることを検証する。
///
/// `gleam_otp` の `Supervisor` は opaque で子 pid を取得する API を公開して
/// いないため、`supervisor:which_children/1` を直接叩く FFI
/// (`test/gleamroom_supervisor_test_ffi.erl`)を使う。
pub fn start_shuts_down_and_is_observable_via_await_supervisor_exit_after_exceeding_restart_tolerance_test() {
  process.trap_exits(True)

  let assert Ok(#(_port, started)) = gleamroom.start_on_ephemeral_port()
  let supervisor_pid = started.pid

  // intensity:2/period:5 の許容回数(2回)までは再起動される。
  let assert Ok(registry_pid_1) = first_child_pid(supervisor_pid)
  process.kill(registry_pid_1)
  wait.until(
    fn() {
      case first_child_pid(supervisor_pid) {
        Ok(pid) -> pid != registry_pid_1
        Error(Nil) -> False
      }
    },
    "registry が1回目の再起動をする",
  )

  let assert Ok(registry_pid_2) = first_child_pid(supervisor_pid)
  process.kill(registry_pid_2)
  wait.until(
    fn() {
      case first_child_pid(supervisor_pid) {
        Ok(pid) -> pid != registry_pid_2
        Error(Nil) -> False
      }
    },
    "registry が2回目の再起動をする",
  )

  // 3回目のクラッシュは intensity:2/period:5 を超える。supervisor は
  // 子を再起動せず全子を terminate してから自身も shutdown するはず
  // ——これが本 issue の主張そのもの: `main` の `trap_exits(True)` +
  // `await_supervisor_exit` がこの実際の shutdown を検知できること。
  let assert Ok(registry_pid_3) = first_child_pid(supervisor_pid)
  process.kill(registry_pid_3)

  let done = process.new_subject()
  gleamroom.await_supervisor_exit(supervisor_pid, fn() {
    process.send(done, Nil)
  })

  let assert Ok(Nil) = process.receive(done, 5000)
}

@external(erlang, "gleamroom_supervisor_test_ffi", "first_child_pid")
fn first_child_pid(supervisor_pid: process.Pid) -> Result(process.Pid, Nil)
