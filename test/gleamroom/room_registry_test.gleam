import gleam/dict
import gleam/erlang/process
import gleam/otp/actor
import gleam/set
import gleamroom/room_registry

/// 空判定で room を外したとき、`stuck_rooms` の同じ key も外れること（#669）。
///
/// `subject_owner` が成功して `monitored` も消えると、後続の `RoomDown` は
/// 未登録分岐に入り stuck を回収できない。close 側で消さないと、登録部屋が
/// 0 件でも `/health` の `stuck` が恒久的に残る。
pub fn close_if_empty_prunes_the_stuck_record_test() {
  let subject: process.Subject(String) = process.new_subject()
  let core =
    room_registry.new(
      fn() { Ok(actor.Started(pid: process.self(), data: subject)) },
      10,
    )
  let #(looked_up, core) = room_registry.lookup(core, "R", "room")
  assert looked_up == Ok(subject)

  let #(_, core) = room_registry.begin_probes(core)
  let core = room_registry.record_probe(core, "R", subject, False)
  assert set.size(core.stuck_rooms) == 1

  let core = room_registry.close_if_empty(core, "R", subject, True, "room")
  let core = room_registry.room_down(core, process.self(), "room")

  assert dict.size(core.rooms) == 0
  assert set.size(core.stuck_rooms) == 0
}
