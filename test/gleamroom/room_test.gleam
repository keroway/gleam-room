import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleamroom/room
import gleamroom/wait

pub fn join_adds_participant_and_emits_joined_test() {
  let state = room.new_state()
  let id = room.participant_id("p1")

  let #(next, event) = room.apply_command(state, room.Join(id, "Alice"))

  assert room.snapshot(next) == [room.Participant(id, "Alice")]
  assert event == room.ParticipantJoined(room.Participant(id, "Alice"))
}

pub fn duplicate_join_is_rejected_and_state_is_unchanged_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(room.new_state(), room.Join(id, "Alice"))

  let #(next, event) = room.apply_command(state, room.Join(id, "Alice again"))

  assert next == state
  assert event == room.JoinRejected(id, room.AlreadyJoined)
}

pub fn join_with_blank_display_name_is_rejected_and_state_is_unchanged_test() {
  let id = room.participant_id("p1")
  let state = room.new_state()

  let #(next, event) = room.apply_command(state, room.Join(id, "   "))

  assert next == state
  assert event == room.JoinRejected(id, room.InvalidDisplayName)
}

pub fn join_with_display_name_over_the_length_limit_is_rejected_test() {
  let id = room.participant_id("p1")
  let state = room.new_state()
  let too_long = string.repeat("a", 65)

  let #(next, event) = room.apply_command(state, room.Join(id, too_long))

  assert next == state
  assert event == room.JoinRejected(id, room.InvalidDisplayName)
}

pub fn join_with_display_name_at_the_length_limit_is_accepted_test() {
  let id = room.participant_id("p1")
  let state = room.new_state()
  let at_limit = string.repeat("a", 64)

  let #(next, event) = room.apply_command(state, room.Join(id, at_limit))

  assert room.snapshot(next) == [room.Participant(id, at_limit)]
  assert event == room.ParticipantJoined(room.Participant(id, at_limit))
}

pub fn join_beyond_the_participant_limit_is_rejected_and_state_is_unchanged_test() {
  let full_state =
    int.range(from: 1, to: 65, with: room.new_state(), run: fn(state, n) {
      let id = room.participant_id("p" <> int.to_string(n))
      let #(next, _) = room.apply_command(state, room.Join(id, "Name"))
      next
    })
  let overflow_id = room.participant_id("overflow")

  let #(next, event) =
    room.apply_command(full_state, room.Join(overflow_id, "Overflow"))

  assert next == full_state
  assert event == room.JoinRejected(overflow_id, room.RoomFull)
}

pub fn join_at_the_participant_limit_is_accepted_test() {
  let almost_full_state =
    int.range(from: 1, to: 64, with: room.new_state(), run: fn(state, n) {
      let id = room.participant_id("p" <> int.to_string(n))
      let #(next, _) = room.apply_command(state, room.Join(id, "Name"))
      next
    })
  let last_id = room.participant_id("last")

  let #(next, event) =
    room.apply_command(almost_full_state, room.Join(last_id, "Last"))

  assert list.length(room.snapshot(next)) == 64
  assert event == room.ParticipantJoined(room.Participant(last_id, "Last"))
}

pub fn leave_removes_participant_and_emits_left_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(room.new_state(), room.Join(id, "Alice"))

  let #(next, event) = room.apply_command(state, room.Leave(id))

  assert room.snapshot(next) == []
  assert event == room.ParticipantLeft(id)
}

pub fn leave_of_unknown_participant_is_rejected_and_state_is_unchanged_test() {
  let id = room.participant_id("p1")
  let state = room.new_state()

  let #(next, event) = room.apply_command(state, room.Leave(id))

  assert next == state
  assert event == room.LeaveRejected(id, room.NotJoined)
}

pub fn snapshot_preserves_multiple_participants_test() {
  let alice = room.participant_id("p1")
  let bob = room.participant_id("p2")
  let #(state, _) =
    room.apply_command(room.new_state(), room.Join(alice, "Alice"))
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))

  assert room.snapshot(state)
    == [room.Participant(alice, "Alice"), room.Participant(bob, "Bob")]
}

pub fn actor_join_and_snapshot_round_trip_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let id = room.participant_id("p1")
  let session = process.new_subject()

  let assert Ok(event) = room.dispatch(subject, room.Join(id, "Alice"), session)

  assert event == room.ParticipantJoined(room.Participant(id, "Alice"))
  assert room.get_snapshot(subject) == Ok([room.Participant(id, "Alice")])
}

pub fn independent_room_actors_do_not_share_state_test() {
  let assert Ok(room_a) = room.start()
  let assert Ok(room_b) = room.start()
  let id = room.participant_id("p1")
  let session = process.new_subject()

  let assert Ok(_) = room.dispatch(room_a.data, room.Join(id, "Alice"), session)

  assert room.get_snapshot(room_a.data) == Ok([room.Participant(id, "Alice")])
  assert room.get_snapshot(room_b.data) == Ok([])
}

pub fn join_broadcasts_to_other_subscribers_but_not_the_joiner_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()

  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)

  // Bob's own join is only delivered synchronously via `dispatch`'s return
  // value, not re-broadcast to himself asynchronously.
  assert process.receive(bob_session, 100) == Error(Nil)
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantJoined(room.Participant(bob, "Bob")))
}

pub fn leave_broadcasts_to_remaining_subscribers_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  let assert Ok(_) = room.dispatch(subject, room.Leave(bob), bob_session)

  assert process.receive(alice_session, 100) == Ok(room.ParticipantLeft(bob))
  assert process.receive(bob_session, 100) == Error(Nil)
}

pub fn buzz_order_matches_acceptance_order_test() {
  let alice = room.participant_id("a")
  let bob = room.participant_id("b")
  let carol = room.participant_id("c")
  let #(state, _) =
    room.apply_command(room.new_state(), room.Join(alice, "Alice"))
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))
  let #(state, _) = room.apply_command(state, room.Join(carol, "Carol"))

  let #(state, bob_event) = room.apply_command(state, room.Buzz(bob))
  let #(state, alice_event) = room.apply_command(state, room.Buzz(alice))
  let #(state, carol_event) = room.apply_command(state, room.Buzz(carol))

  assert bob_event == room.BuzzAccepted(bob, "Bob", 1)
  assert alice_event == room.BuzzAccepted(alice, "Alice", 2)
  assert carol_event == room.BuzzAccepted(carol, "Carol", 3)
  assert room.buzz_snapshot(state)
    == [
      room.BuzzResult(bob, "Bob", 1),
      room.BuzzResult(alice, "Alice", 2),
      room.BuzzResult(carol, "Carol", 3),
    ]
}

pub fn duplicate_buzz_is_rejected_and_state_unchanged_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(room.new_state(), room.Join(id, "Alice"))
  let #(state, _) = room.apply_command(state, room.Buzz(id))

  let #(next, event) = room.apply_command(state, room.Buzz(id))

  assert next == state
  assert event == room.BuzzRejected(id, room.AlreadyBuzzed)
}

pub fn buzz_from_unjoined_participant_is_rejected_test() {
  let id = room.participant_id("p1")
  let state = room.new_state()

  let #(next, event) = room.apply_command(state, room.Buzz(id))

  assert next == state
  assert event == room.BuzzRejected(id, room.BuzzerNotJoined)
}

pub fn reset_round_clears_buzzes_and_permits_rebuzz_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(room.new_state(), room.Join(id, "Alice"))
  let #(state, _) = room.apply_command(state, room.Buzz(id))

  let #(reset_state, reset_event) = room.apply_command(state, room.ResetRound)

  assert reset_event == room.RoundReset
  assert room.buzz_snapshot(reset_state) == []

  let #(_, rebuzz_event) = room.apply_command(reset_state, room.Buzz(id))
  assert rebuzz_event == room.BuzzAccepted(id, "Alice", 1)
}

pub fn actor_buzz_broadcasts_ordering_to_other_subscribers_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  let assert Ok(event) = room.dispatch(subject, room.Buzz(bob), bob_session)

  assert event == room.BuzzAccepted(bob, "Bob", 1)
  assert process.receive(alice_session, 100)
    == Ok(room.BuzzAccepted(bob, "Bob", 1))
  assert process.receive(bob_session, 100) == Error(Nil)
}

pub fn actor_reset_round_clears_buzz_snapshot_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Buzz(alice), alice_session)

  let assert Ok(event) = room.dispatch(subject, room.ResetRound, alice_session)

  assert event == room.RoundReset
  assert room.get_buzz_snapshot(subject) == Ok([])
}

pub fn departed_subscriber_receives_no_further_broadcasts_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  // Bob disconnects: the transport layer dispatches `Leave` on his behalf,
  // which drops his subject from the subscriber set (mirrors `on_close`).
  let assert Ok(_) = room.dispatch(subject, room.Leave(bob), bob_session)
  let _ = process.receive(alice_session, 100)

  // A later room event must not reach Bob's now-stale subject.
  let carol = room.participant_id("p3")
  let carol_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(carol, "Carol"), carol_session)

  assert process.receive(bob_session, 100) == Error(Nil)
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantJoined(room.Participant(carol, "Carol")))
}

pub fn rejoin_after_leave_is_a_new_transient_identity_with_current_snapshot_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice_old = room.participant_id("connection-1")
  let alice_old_session = process.new_subject()
  let _ =
    room.dispatch(subject, room.Join(alice_old, "Alice"), alice_old_session)
  let assert Ok(_) =
    room.dispatch(subject, room.Buzz(alice_old), alice_old_session)

  // The dropped connection's `Leave` and the new connection's `Join` are
  // dispatched independently, as `on_close`/`handle_join` would from two
  // separate WebSocket processes.
  let assert Ok(_) =
    room.dispatch(subject, room.Leave(alice_old), alice_old_session)
  let alice_new = room.participant_id("connection-2")
  let alice_new_session = process.new_subject()
  let event =
    room.dispatch(subject, room.Join(alice_new, "Alice"), alice_new_session)

  // Reconnect gets a distinct `ParticipantId`; the server does not correlate
  // it with the connection that dropped.
  assert event
    == Ok(room.ParticipantJoined(room.Participant(alice_new, "Alice")))
  assert alice_new != alice_old

  // The snapshot delivered on rejoin reflects current room state: the old
  // identity's buzz is preserved (per ADR 0003, buzz history lives in the
  // active Room process, not tied to any one connection), and presence
  // reflects only the reconnected participant.
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice_new, "Alice")])
  assert room.get_buzz_snapshot(subject)
    == Ok([room.BuzzResult(alice_old, "Alice", 1)])
}

pub fn rejoin_before_old_connections_leave_keeps_both_identities_present_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice_old = room.participant_id("connection-1")
  let alice_old_session = process.new_subject()
  let _ =
    room.dispatch(subject, room.Join(alice_old, "Alice"), alice_old_session)

  // The relative order of the new connection's `Join` and the old
  // connection's `Leave` is not guaranteed (independent processes). Here the
  // new connection's `Join` is processed first.
  let alice_new = room.participant_id("connection-2")
  let alice_new_session = process.new_subject()
  let _ =
    room.dispatch(subject, room.Join(alice_new, "Alice"), alice_new_session)

  assert room.get_snapshot(subject)
    == Ok([
      room.Participant(alice_old, "Alice"),
      room.Participant(alice_new, "Alice"),
    ])

  let assert Ok(_) =
    room.dispatch(subject, room.Leave(alice_old), alice_old_session)

  // Once the stale connection's `Leave` is processed, only the reconnected
  // identity remains present.
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice_new, "Alice")])
}

pub fn independent_room_actors_do_not_share_buzz_state_test() {
  let assert Ok(room_a) = room.start()
  let assert Ok(room_b) = room.start()
  let id = room.participant_id("p1")
  let session = process.new_subject()
  let assert Ok(_) = room.dispatch(room_a.data, room.Join(id, "Alice"), session)
  let assert Ok(_) = room.dispatch(room_b.data, room.Join(id, "Alice"), session)

  let assert Ok(_) = room.dispatch(room_a.data, room.Buzz(id), session)

  assert room.get_buzz_snapshot(room_a.data)
    == Ok([room.BuzzResult(id, "Alice", 1)])
  assert room.get_buzz_snapshot(room_b.data) == Ok([])
}

/// 接続プロセスが死んだ参加者が room から自動で消えること（#56 / #35）。
///
/// 参加者は WebSocket の接続プロセスと 1 対 1 で対応する。接続が死んだのに
/// Leave が届かない経路が複数ある:
///
///   - Join がタイムアウトし遅れて成立した（接続側は自分が参加者だと知らない、#33）
///   - 接続プロセスがクラッシュした
///   - 突然の切断で on_close が走らなかった（#35）
///
/// 原因ごとに塞ぐより「接続が死んだら参加者も消える」という不変条件を
/// 1 つ置くほうが確実。
pub fn a_participant_whose_session_dies_is_removed_test() {
  let assert Ok(started) = room.start()
  let subject = started.data

  let survivor = room.participant_id("survivor")
  let survivor_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(survivor, "Survivor"), survivor_session)

  // 別プロセスから join させ、そのプロセスを殺す。
  let doomed = room.participant_id("doomed")
  let doomed_pid =
    process.spawn_unlinked(fn() {
      let doomed_session = process.new_subject()
      let _ =
        room.dispatch(subject, room.Join(doomed, "Doomed"), doomed_session)
      // room 側が監視を張るまで生きている必要がある。
      process.sleep(500)
    })

  let both = [
    room.Participant(survivor, "Survivor"),
    room.Participant(doomed, "Doomed"),
  ]
  wait.until(fn() { room.get_snapshot(subject) == Ok(both) }, "2 人とも join し終わる")

  process.kill(doomed_pid)

  // 死んだ接続の参加者だけが消え、room 自体は生きている。
  wait.until(
    fn() {
      room.get_snapshot(subject) == Ok([room.Participant(survivor, "Survivor")])
    },
    "死んだ接続の参加者が片付く",
  )
}

/// `select_monitors` の `PortDown` 分岐が no-op であること（#147）。
///
/// room actor は Port を監視していないため、`PortDown` を受けても
/// `SessionDown(process.self())` を送るだけで、`sessions` に自分の pid の
/// エントリが無いので何も変わらない（room.gleam:269-276）。
///
/// 実際に Port を監視して `PortDown` を発火させる代わりに、room actor に
/// 追跡していない pid（room 自身の pid）で `SessionDown` を直接送ることで
/// 同じ帰結（sessions に一致するエントリが無い → 何も変わらない）を検証する。
pub fn session_down_for_an_untracked_pid_is_a_no_op_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let assert Ok(room_pid) = process.subject_owner(subject)

  let id = room.participant_id("p1")
  let session = process.new_subject()
  let assert Ok(_) = room.dispatch(subject, room.Join(id, "Alice"), session)

  // `PortDown` 分岐が実際に送るのと同じメッセージを、追跡されていない pid
  // （room actor 自身の pid）で直接送る。
  process.send(subject, room.SessionDown(room_pid))

  // no-op なので room は生きたままで、参加者も変わらない。
  assert process.is_alive(room_pid)
  assert room.get_snapshot(subject) == Ok([room.Participant(id, "Alice")])
}

/// 接続プロセスがクラッシュしても room actor が生き残ること（#69）。
///
/// #56 で「接続が死んだら参加者も消える」を実装した際、`process.link` を
/// 使っていた。link は **双方向** で「クラッシュしたプロセスにリンクされた
/// プロセスも クラッシュする」ため、接続プロセスが 1 つ落ちただけで room actor
/// ごと死に、**同室の全参加者が道連れ**になる。
///
/// 正しくは `process.monitor`（片方向）。対象の終了をメッセージで受け取るだけで、
/// 監視元は影響を受けない。
pub fn a_crashing_session_does_not_take_down_the_room_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let assert Ok(room_pid) = process.subject_owner(subject)

  let survivor = room.participant_id("survivor")
  let survivor_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(survivor, "Survivor"), survivor_session)

  // 別プロセスから join し、**異常終了**させる。
  let doomed = room.participant_id("doomed")
  // 固定 sleep で join 完了を待たない（#69 の指摘）。child が Join 前に死ぬと
  // 「room が生きている」だけが確認され、道連れの検証になっていない。
  let ready = process.new_subject()
  let doomed_pid =
    process.spawn_unlinked(fn() {
      let doomed_session = process.new_subject()
      let assert Ok(_) =
        room.dispatch(subject, room.Join(doomed, "Doomed"), doomed_session)
      process.send(ready, Nil)
      process.sleep(500)
    })

  let assert Ok(Nil) = process.receive(ready, 1000)
  process.kill(doomed_pid)
  wait.until_dead(doomed_pid, "接続プロセスが終了する")

  // room actor は生きている（link だとここで死んでいた）。
  assert process.is_alive(room_pid)
  // 残った参加者も引き続き使える。
  assert room.get_snapshot(subject)
    == Ok([room.Participant(survivor, "Survivor")])
}

/// room actor が落ちても接続プロセスは生き残ること（#69）。
///
/// monitor は片方向なので、逆方向（room → session）へは何も伝播しない。
/// link だった頃はこちらも道連れになり、room の異常終了で全参加者の
/// 接続プロセスが落ちていた。
pub fn a_crashing_room_does_not_take_down_the_sessions_test() {
  // room は別プロセスから起動する。`actor.start` は呼び出し元と link するため、
  // テストプロセスから起動して kill するとテスト自体が巻き添えで死ぬ
  // （実際に Exit(Killed) で 3 件落ちた）。
  let room_ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = room.start()
    process.send(room_ready, started.data)
    process.sleep(3000)
  })
  let assert Ok(subject) = process.receive(room_ready, 1000)
  let assert Ok(room_pid) = process.subject_owner(subject)

  let ready = process.new_subject()
  let participant = room.participant_id("holder")
  let session_pid =
    process.spawn_unlinked(fn() {
      let session = process.new_subject()
      let assert Ok(_) =
        room.dispatch(subject, room.Join(participant, "Holder"), session)
      process.send(ready, Nil)
      // room が落ちたあとも生きていることを確認したいので、検証が終わるまで
      // 待つ。**親が作った subject では receive できない**（所有プロセス以外の
      // receive はパニックする）ので sleep で待つ。
      process.sleep(3000)
    })

  let assert Ok(Nil) = process.receive(ready, 1000)
  assert process.is_alive(session_pid)

  process.kill(room_pid)
  wait.until_dead(room_pid, "room actor が終了する")

  // room は死んだが、接続プロセスは生きている。
  assert !process.is_alive(room_pid)
  assert process.is_alive(session_pid)
}

/// **複数プロセスから同時に Buzz しても順序が一意に定まる**こと（#94）。
///
/// CLAUDE.md の MVP スコープは "Server-side ordering of buzzer events" を
/// 挙げているが、既存の `buzz_order_matches_acceptance_order_test` は純関数
/// `apply_command` を 1 プロセスで順番に呼ぶだけで、**actor の mailbox による
/// 直列化を一切通っていない**。`room.dispatch` の実装が変わって FIFO 保証が
/// 壊れても、あのテストは緑のままになる。
///
/// 実際の受付順は非決定なので、**順序そのものではなく順序が満たすべき性質**を
/// 検証する。どう interleave しても次が成り立つ:
///
///   - 位置は 1..N の重複なし・欠番なし（同じ位置を 2 人が取らない）
///   - 各参加者が受け取った `BuzzAccepted` の位置が snapshot と一致する
///   - snapshot は位置の昇順
pub fn concurrent_buzzes_get_unique_consecutive_positions_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let count = 8

  // 各参加者を**別プロセス**にする。同一プロセスから順番に送ると、
  // それは既存テストと同じ「直列に呼んだだけ」になり並行性を再現しない。
  let results = process.new_subject()
  one_to(count)
  |> list.each(fn(n) {
    process.spawn_unlinked(fn() {
      let session = process.new_subject()
      let id = room.participant_id("p" <> int.to_string(n))
      let display_name = "P" <> int.to_string(n)
      let assert Ok(_) =
        room.dispatch(subject, room.Join(id, display_name), session)
      let assert Ok(event) = room.dispatch(subject, room.Buzz(id), session)
      process.send(results, #(event, display_name))
      process.sleep(3000)
    })
  })

  let accepted = collect_buzz_events(results, count, [])
  let positions =
    accepted
    |> list.map(fn(reported) {
      let assert room.BuzzAccepted(_, _, position) = reported.0
      position
    })
    |> list.sort(int.compare)

  // 1..N が重複なく揃う。同じ位置を 2 人が取っていれば長さが足りなくなる。
  assert positions == one_to(count)

  // room 側の記録と、各参加者が受け取った通知が食い違わない。
  let assert Ok(snapshot) = room.get_buzz_snapshot(subject)
  assert list.length(snapshot) == count
  assert list.map(snapshot, fn(result) { result.position }) == one_to(count)

  let reported =
    accepted
    |> list.map(fn(reported) {
      let assert room.BuzzAccepted(id, _, position) = reported.0
      room.BuzzResult(id, reported.1, position)
    })
    |> list.sort(fn(a, b) { int.compare(a.position, b.position) })
  assert reported == snapshot
}

/// 期待件数だけ結果を集める。件数が揃わなければ待ち続けず落とす
/// （黙って少ない件数で assert すると、取りこぼしを「成功」と読み違える）。
fn collect_buzz_events(
  results: process.Subject(#(room.RoomEvent, String)),
  remaining: Int,
  acc: List(#(room.RoomEvent, String)),
) -> List(#(room.RoomEvent, String)) {
  case remaining {
    0 -> acc
    _ ->
      case process.receive(results, 2000) {
        Ok(event) -> collect_buzz_events(results, remaining - 1, [event, ..acc])
        Error(Nil) -> panic as "Buzz の結果が期限内に揃わなかった"
      }
  }
}

/// `1..n` の昇順リスト。gleam_stdlib のこの版に `list.range` が無いため自前で持つ。
fn one_to(n: Int) -> List(Int) {
  case n {
    n if n <= 0 -> []
    _ -> list.append(one_to(n - 1), [n])
  }
}
