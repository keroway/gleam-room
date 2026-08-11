import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleamroom/registry
import gleamroom/room

pub fn repeated_lookup_resolves_to_same_room_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-1")

  let assert Ok(first) = registry.lookup(started.data, id)
  let assert Ok(second) = registry.lookup(started.data, id)

  assert first == second
}

pub fn different_room_ids_resolve_to_isolated_rooms_test() {
  let assert Ok(started) = registry.start()
  let assert Ok(room_a) =
    registry.lookup(started.data, registry.room_id("room-a"))
  let assert Ok(room_b) =
    registry.lookup(started.data, registry.room_id("room-b"))
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
      let assert Ok(subject) = registry.lookup(started.data, id)
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
  assert unique == [registry_subject_of(started.data, id)]
}

/// 空になった room を registry から外せること（#26）。
///
/// 外さないと、一度でも join された RoomId の Room actor と Dict エントリが
/// プロセス終了まで残り続ける。稼働時間とユニークな RoomId の種類に比例して
/// 単調増加するため、**エラーにはならず静かにメモリを食う**。
pub fn release_removes_the_room_so_the_next_lookup_starts_a_fresh_actor_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-release")

  let assert Ok(first) = registry.lookup(started.data, id)
  // 同じ ID の lookup は同じ actor を返す（解放前）。
  assert registry_subject_of(started.data, id) == first

  process.send(started.data, registry.Release(id, first))
  // Release は非同期なので、次の同期呼び出しで処理済みを保証する。
  let assert Ok(second) = registry.lookup(started.data, id)

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

  let assert Ok(old) = registry.lookup(started.data, id)
  process.send(started.data, registry.Release(id, old))
  let assert Ok(current) = registry.lookup(started.data, id)

  // 遅れて届いた古い Release。current を消してはいけない。
  process.send(started.data, registry.Release(id, old))

  assert registry_subject_of(started.data, id) == current
}

/// Release された room の **actor プロセス自体**が終了すること（#26）。
///
/// registry の Dict から外すだけでは足りない。エントリは消えても BEAM
/// プロセスは生き続けるため、リークの半分しか塞げない。
pub fn release_stops_the_room_actor_process_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-release-stops")

  let assert Ok(subject) = registry.lookup(started.data, id)
  let assert Ok(pid) = process.subject_owner(subject)
  assert process.is_alive(pid)

  process.send(started.data, registry.Release(id, subject))
  // Release は非同期。registry への同期呼び出しで処理済みを保証してから、
  // room 側の停止が伝播するのを待つ。
  let assert Ok(_) = registry.lookup(started.data, id)
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

  let assert Ok(subject) = registry.lookup(started.data, id)
  let assert Ok(pid) = process.subject_owner(subject)

  // Release より先に新しい参加者が入る（レースの後半だけを再現する）。
  let session = process.new_subject()
  let joiner = room.participant_id("late-joiner")
  let _ = room.dispatch(subject, room.Join(joiner, "late"), session)

  process.send(started.data, registry.Release(id, subject))
  // Release は非同期。registry への同期呼び出しで処理済みを保証する。
  let assert Ok(after) = registry.lookup(started.data, id)
  process.sleep(50)

  // 停止していない。
  assert process.is_alive(pid)
  // 登録も外れていない（外れると次の lookup が別 actor を作り参加者が分断される）。
  assert after == subject
  // 参加者も残っている。
  assert room.get_snapshot(subject) != []
}

/// テスト内で room の起動成功を前提に subject を取り出すヘルパ。
/// `lookup` は #32 以降 `Result` を返す（room の起動失敗を registry ごと
/// クラッシュさせないため）。
fn registry_subject_of(
  registry_subject: process.Subject(registry.Message),
  id: registry.RoomId,
) -> process.Subject(room.Message) {
  let assert Ok(subject) = registry.lookup(registry_subject, id)
  subject
}

/// room の起動に失敗しても registry が生き続けること（#32）。
///
/// 以前は `let assert Ok(started) = room.start()` で受けており、失敗すると
/// **registry アクター自体がクラッシュ**していた。registry は全ルーム共通の
/// 単一プロセスで全 Lookup を直列に処理するため、1 ルームの起動失敗が
/// 無関係な既存ルームの lookup まで巻き添えにする。
/// docs/architecture.md の "One room should be isolated from failures/state
/// in other rooms." に反する。
///
/// BEAM のプロセス生成は資源が尽きない限り成功するため、起動関数を注入して
/// 失敗を再現する。**型を Result にしただけでは内部の `let assert` を防げない**
/// （実際、型だけの検証では回帰を捉えられないことを確認した）。
pub fn a_room_start_failure_does_not_crash_the_registry_test() {
  let assert Ok(started) =
    registry.start_with_room_starter(fn() { Error(actor.InitFailed("boom")) })
  let assert Ok(registry_pid) = process.subject_owner(started.data)

  // 起動に失敗した lookup は Error を返す（パニックしない）。
  assert registry.lookup(started.data, registry.room_id("room-fails"))
    == Error(Nil)

  // registry は生きている。
  assert process.is_alive(registry_pid)

  // 別の RoomId の lookup も引き続き処理される（巻き添えになっていない）。
  assert registry.lookup(started.data, registry.room_id("room-other"))
    == Error(Nil)
  assert process.is_alive(registry_pid)
}

/// room actor がクラッシュしたら registry から自動で外れること（#39）。
///
/// room は supervisor の子ではなく registry が直接起動するため、クラッシュ
/// しても誰も片付けない。監視していないと **死んだ subject が Dict に残り続け**、
/// 以後その RoomId の lookup は死んだ subject を返す。`room.dispatch` は
/// `actor.call(waiting: 1000)` なので毎回タイムアウトし、その部屋は
/// サーバー再起動まで恒久的に使用不能になる。
pub fn a_crashed_room_is_removed_from_the_registry_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-crash")

  let before = registry_subject_of(started.data, id)
  let assert Ok(pid) = process.subject_owner(before)

  process.kill(pid)
  // Down メッセージが registry に届くのを待つ。
  process.sleep(100)

  // 次の lookup は**新しい** actor を返す（死んだ subject が残っていない）。
  let after = registry_subject_of(started.data, id)
  assert after != before

  let assert Ok(after_pid) = process.subject_owner(after)
  assert process.is_alive(after_pid)
  // 新しい room は使える。
  assert room.get_snapshot(after) == []
}
