import gleam/erlang/process
import gleam/list
import gleamroom/registry
import gleamroom/room

pub fn repeated_lookup_resolves_to_same_room_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-1")

  let first = registry.lookup(started.data, id)
  let second = registry.lookup(started.data, id)

  assert first == second
}

pub fn different_room_ids_resolve_to_isolated_rooms_test() {
  let assert Ok(started) = registry.start()
  let room_a = registry.lookup(started.data, registry.room_id("room-a"))
  let room_b = registry.lookup(started.data, registry.room_id("room-b"))
  let alice = room.participant_id("p1")
  let session = process.new_subject()

  let _ = room.dispatch(room_a, room.Join(alice, "Alice"), session)

  assert room.get_snapshot(room_a) == [room.Participant(alice, "Alice")]
  assert room.get_snapshot(room_b) == []
}

pub fn concurrent_lookups_for_the_same_room_id_agree_on_one_actor_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-concurrent")
  let results = process.new_subject()

  list.each(list.repeat(Nil, 20), fn(_) {
    process.spawn(fn() {
      let subject = registry.lookup(started.data, id)
      process.send(results, subject)
    })
  })

  let subjects =
    list.repeat(Nil, 20)
    |> list.map(fn(_) {
      let assert Ok(subject) = process.receive(results, 1000)
      subject
    })

  let unique = list.unique(subjects)
  assert unique == [registry.lookup(started.data, id)]
}

/// 空になった room を registry から外せること（#26）。
///
/// 外さないと、一度でも join された RoomId の Room actor と Dict エントリが
/// プロセス終了まで残り続ける。稼働時間とユニークな RoomId の種類に比例して
/// 単調増加するため、**エラーにはならず静かにメモリを食う**。
pub fn release_removes_the_room_so_the_next_lookup_starts_a_fresh_actor_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-release")

  let first = registry.lookup(started.data, id)
  // 同じ ID の lookup は同じ actor を返す（解放前）。
  assert registry.lookup(started.data, id) == first

  process.send(started.data, registry.Release(id, first))
  // Release は非同期なので、次の同期呼び出しで処理済みを保証する。
  let second = registry.lookup(started.data, id)

  assert second != first
}

/// 登録中のものと違う subject を渡した Release は無視すること（#26）。
///
/// 「空になった → Release を送る」の途中で別の参加者が同じ ID を lookup すると、
/// 遅れて届いた Release が**新しい actor** を消しうる。消えたことは誰にも
/// 通知されないため、その参加者は自分だけの room に閉じ込められる。
pub fn release_with_a_stale_subject_does_not_remove_the_current_room_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-release-stale")

  let old = registry.lookup(started.data, id)
  process.send(started.data, registry.Release(id, old))
  let current = registry.lookup(started.data, id)

  // 遅れて届いた古い Release。current を消してはいけない。
  process.send(started.data, registry.Release(id, old))

  assert registry.lookup(started.data, id) == current
}

/// Release された room の **actor プロセス自体**が終了すること（#26）。
///
/// registry の Dict から外すだけでは足りない。エントリは消えても BEAM
/// プロセスは生き続けるため、リークの半分しか塞げない。
pub fn release_stops_the_room_actor_process_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-release-stops")

  let subject = registry.lookup(started.data, id)
  let assert Ok(pid) = process.subject_owner(subject)
  assert process.is_alive(pid)

  process.send(started.data, registry.Release(id, subject))
  // Release は非同期。registry への同期呼び出しで処理済みを保証してから、
  // room 側の停止が伝播するのを待つ。
  let _ = registry.lookup(started.data, id)
  process.sleep(50)

  assert !process.is_alive(pid)
}

/// 参加者が残っている room は Release を受けても停止しないこと（#36）。
///
/// #26 の実装では websocket 層が「空か確認 → Release 送信」と 2 段階で
/// 行っていたため、その隙に join した参加者ごと room actor が停止しえた。
/// 判定と停止を room actor の 1 メッセージに閉じたことで、この経路は塞がる。
///
/// ここでは「Release が届く前に join が完了していた」状態を作って検証する。
pub fn release_does_not_stop_a_room_that_gained_a_participant_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-race")

  let subject = registry.lookup(started.data, id)
  let assert Ok(pid) = process.subject_owner(subject)

  // Release より先に新しい参加者が入る（レースの後半だけを再現する）。
  let session = process.new_subject()
  let joiner = room.participant_id("late-joiner")
  let _ = room.dispatch(subject, room.Join(joiner, "late"), session)

  process.send(started.data, registry.Release(id, subject))
  // Release は非同期。registry への同期呼び出しで処理済みを保証する。
  let after = registry.lookup(started.data, id)
  process.sleep(50)

  // 停止していない。
  assert process.is_alive(pid)
  // 登録も外れていない（外れると次の lookup が別 actor を作り参加者が分断される）。
  assert after == subject
  // 参加者も残っている。
  assert room.get_snapshot(subject) != []
}
