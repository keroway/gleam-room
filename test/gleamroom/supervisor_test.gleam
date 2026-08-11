import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleamroom/registry
import gleamroom/room

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
  wait_for_new_registry(name, pid, 50)

  // **同じ名前**で引き続き使える（呼び出し側は subject を取り直していない）。
  let assert Ok(after) = registry.lookup(subject, registry.room_id("room-sup"))
  assert room.get_snapshot(after) == Ok([])

  // 再起動後は新しいプロセスなので、状態は引き継がれない（作り直された証拠）。
  assert before != after
}

fn wait_for_new_registry(
  name: process.Name(registry.Message),
  old: process.Pid,
  attempts: Int,
) -> Nil {
  case attempts {
    0 -> panic as "registry が再起動しなかった"
    _ -> {
      process.sleep(20)
      case process.subject_owner(process.named_subject(name)) {
        Ok(current) if current != old -> Nil
        _ -> wait_for_new_registry(name, old, attempts - 1)
      }
    }
  }
}
