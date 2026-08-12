import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleamroom/call
import gleamroom/registry
import gleamroom/room
import gleamroom/wait

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

  let assert Ok(_) = room.dispatch(room_a, room.Join(alice, "Alice"), session)

  assert room.get_snapshot(room_a) == Ok([room.Participant(alice, "Alice")])
  assert room.get_snapshot(room_b) == Ok([])
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
  wait.until_dead(pid, "空の room が停止する")

  assert !process.is_alive(pid)
}

/// Release で作り直された room を、古い actor の遅延した終了通知が消さないこと（#160）。
///
/// Release は空の room を止めるため、その exit は非同期に `RoomDown` として届く。
/// 同じ RoomId がその前に lookup されて新しい actor を持っていても、古い pid の
/// 通知は新しい subject を登録から外してはならない。
pub fn a_delayed_room_down_does_not_remove_a_recreated_room_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-delayed-down")

  let assert Ok(old) = registry.lookup(started.data, id)
  let assert Ok(old_pid) = process.subject_owner(old)

  process.send(started.data, registry.Release(id, old))
  let assert Ok(current) = registry.lookup(started.data, id)

  // trap_exits から届くものと同じ、旧 actor の遅延した終了通知を再現する。
  process.send(started.data, registry.RoomDown(old_pid))

  assert registry_subject_of(started.data, id) == current
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
  let assert Ok(_) = room.dispatch(subject, room.Join(joiner, "late"), session)

  process.send(started.data, registry.Release(id, subject))
  // Release は非同期。registry への同期呼び出しで処理済みを保証する。
  let assert Ok(after) = registry.lookup(started.data, id)
  // 「起きないこと」の確認なので、ここだけは待つ以外にない。停止するなら
  // この間に停止する（条件で待てる事象が無い）。
  process.sleep(50)

  // 停止していない。
  assert process.is_alive(pid)
  // 登録も外れていない（外れると次の lookup が別 actor を作り参加者が分断される）。
  assert after == subject
  // 参加者も残っている。
  assert room.get_snapshot(subject) != Ok([])
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
  wait.until_dead(pid, "room actor が終了する")

  // 次の lookup は**新しい** actor を返す（死んだ subject が残っていない）。
  let after = registry_subject_of(started.data, id)
  assert after != before

  let assert Ok(after_pid) = process.subject_owner(after)
  assert process.is_alive(after_pid)
  // 新しい room は使える。
  assert room.get_snapshot(after) == Ok([])
}

/// registry が応答しなくても**呼び出し元プロセスが生き残る**こと（#58）。
///
/// #33 で room 側の同期呼び出しは `call.try_call` に移したが、
/// `registry.lookup` だけ生の `actor.call` が残っていた。registry の Lookup は
/// room の起動と `shutdown_if_empty` を挟むため詰まりやすく、詰まった瞬間に
/// WebSocket の接続プロセスが理由不明のまま落ちる。
///
/// 実際の詰まり（GC 停止・メッセージ滞留）は再現できないので、
/// **誰も応答しない subject** を registry の代わりに渡して同じ状況を作る。
/// この subject の所有者はテストプロセス自身なので、送った Lookup は
/// 処理されずタイムアウトする。
pub fn lookup_returns_error_instead_of_crashing_the_caller_test() {
  let unresponsive: process.Subject(registry.Message) = process.new_subject()

  // 素の actor.call ならここで呼び出し元（このテストプロセス）が死ぬ。
  assert registry.lookup(unresponsive, registry.room_id("stalled"))
    == Error(Nil)

  // 生き残っているので後続の検証ができる。これが #58 の要点。
  let assert Ok(started) = registry.start()
  let assert Ok(_) = registry.lookup(started.data, registry.room_id("ok"))
}

/// 接続プロセスが `on_close` を経ずに死んだとき、**空になった room が
/// registry から外れる**こと（#91）。
///
/// 参加者が抜ける経路は 2 つある。通常の切断は websocket の `on_close` が
/// `registry.Release` を送って掃除するが、**突然の切断ではそこを通らない**
/// （#35 がこの経路を導入した理由）。room actor は自分を登録している registry を
/// 知らないので Release を送れず、放置すると空の room actor と Dict エントリが
/// 再起動まで残る（プロセス・メモリリーク）。
///
/// 修正後は room が自分で止まり、registry の `RoomDown`（#39）が拾って外す。
pub fn a_room_emptied_by_a_dead_session_is_removed_from_the_registry_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data
  let id = registry.room_id("room-session-down")

  let assert Ok(subject) = registry.lookup(reg, id)
  let assert Ok(room_pid) = process.subject_owner(subject)

  // **別プロセスから join する。** room が監視するのは「join を送った
  // プロセス」なので、テストプロセスから join すると殺す相手がテスト自身になる。
  let ready = process.new_subject()
  let session_pid =
    process.spawn_unlinked(fn() {
      let session = process.new_subject()
      let joiner = room.participant_id("doomed")
      let assert Ok(_) =
        room.dispatch(subject, room.Join(joiner, "doomed"), session)
      process.send(ready, Nil)
      process.sleep(5000)
    })
  let assert Ok(Nil) = process.receive(ready, 1000)

  // on_close を通らない突然の終了。
  process.kill(session_pid)
  wait.until_dead(room_pid, "空になった room が停止する")

  // 空になった room は停止し、登録も外れている。
  // 外れていれば次の lookup は**新しい actor** を作る。
  let assert Ok(after) = registry.lookup(reg, id)
  assert after != subject
}

/// `health` が **registry の応答**を確かめること（#93）。
///
/// `/health` はこれを見て 200 / 503 を切り替える。以前は無条件に 200 "ok" を
/// 返していたため、registry が死んでいても詰まっていても緑になり、
/// `gleamroom.main` のコメントが問題として挙げている
/// 「HTTP は 200 を返すのに join だけが無反応」をまさに検出できなかった。
pub fn health_reports_the_number_of_registered_rooms_test() {
  let assert Ok(started) = registry.start()
  let reg = started.data

  assert registry.health(reg) == Ok(0)

  let assert Ok(_) = registry.lookup(reg, registry.room_id("a"))
  let assert Ok(_) = registry.lookup(reg, registry.room_id("b"))

  assert registry.health(reg) == Ok(2)
}

/// **応答しない registry では失敗する**こと。ここが本体で、件数は付随情報。
///
/// 「詰まっている」を再現するため、誰も処理しない subject を渡す
/// （所有者はテストプロセス自身なので Health は処理されない）。
/// 素の `actor.call` ならここで呼び出し元が死ぬ（#33 / #58）。
pub fn health_fails_when_the_registry_does_not_answer_test() {
  let unresponsive: process.Subject(registry.Message) = process.new_subject()

  // **Timeout と分類される**こと。/health はこれを「詰まっている」として
  // 運用者に伝える（#92）。死んでいる場合と対処が違う。
  assert registry.health(unresponsive) == Error(call.Timeout)
}

/// 死んだ registry でも失敗する（クラッシュではなく Error になる）。
pub fn health_fails_when_the_registry_is_dead_test() {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = registry.start()
    process.send(ready, started.data)
    process.sleep(3000)
  })
  let assert Ok(reg) = process.receive(ready, 1000)
  let assert Ok(pid) = process.subject_owner(reg)

  assert registry.health(reg) == Ok(0)

  process.kill(pid)
  wait.until_dead(pid, "registry が終了する")

  // **ActorDown と分類される**こと。詰まっているのではなく落ちている。
  assert registry.health(reg) == Error(call.ActorDown)
}
