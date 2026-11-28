import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleamroom/room
import gleamroom/wait

pub fn join_adds_participant_and_emits_joined_test() {
  let state = open_state()
  let id = room.participant_id("p1")

  let #(next, event) = room.apply_command(state, room.Join(id, "Alice"))

  assert room.snapshot(next)
    == [room.Participant(id, "Alice", True, room.Player)]
  assert event
    == room.ParticipantJoined(
      room.Participant(id, "Alice", True, room.Player),
      1,
    )
}

pub fn duplicate_join_is_rejected_and_state_is_unchanged_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(open_state(), room.Join(id, "Alice"))

  let #(next, event) = room.apply_command(state, room.Join(id, "Alice again"))

  assert next == state
  assert event == room.JoinRejected(id, room.AlreadyJoined)
}

pub fn join_with_blank_display_name_is_rejected_and_state_is_unchanged_test() {
  let id = room.participant_id("p1")
  let state = open_state()

  let #(next, event) = room.apply_command(state, room.Join(id, "   "))

  assert next == state
  assert event == room.JoinRejected(id, room.InvalidDisplayName)
}

pub fn join_with_display_name_over_the_length_limit_is_rejected_test() {
  let id = room.participant_id("p1")
  let state = open_state()
  let too_long = string.repeat("a", 65)

  let #(next, event) = room.apply_command(state, room.Join(id, too_long))

  assert next == state
  assert event == room.JoinRejected(id, room.InvalidDisplayName)
}

pub fn join_with_display_name_at_the_length_limit_is_accepted_test() {
  let id = room.participant_id("p1")
  let state = open_state()
  let at_limit = string.repeat("a", 64)

  let #(next, event) = room.apply_command(state, room.Join(id, at_limit))

  assert room.snapshot(next)
    == [room.Participant(id, at_limit, True, room.Player)]
  assert event
    == room.ParticipantJoined(
      room.Participant(id, at_limit, True, room.Player),
      1,
    )
}

pub fn join_beyond_the_participant_limit_is_rejected_and_state_is_unchanged_test() {
  let full_state =
    int.range(from: 1, to: 65, with: open_state(), run: fn(state, n) {
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
    int.range(from: 1, to: 64, with: open_state(), run: fn(state, n) {
      let id = room.participant_id("p" <> int.to_string(n))
      let #(next, _) = room.apply_command(state, room.Join(id, "Name"))
      next
    })
  let last_id = room.participant_id("last")

  let #(next, event) =
    room.apply_command(almost_full_state, room.Join(last_id, "Last"))

  assert list.length(room.snapshot(next)) == 64
  assert event
    == room.ParticipantJoined(
      room.Participant(last_id, "Last", True, room.Player),
      64,
    )
}

pub fn leave_removes_participant_and_emits_left_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(open_state(), room.Join(id, "Alice"))

  let #(next, event) = room.apply_command(state, room.Leave(id))

  assert room.snapshot(next) == []
  assert event == room.ParticipantLeft(id, 2)
}

pub fn leave_of_unknown_participant_is_rejected_and_state_is_unchanged_test() {
  let id = room.participant_id("p1")
  let state = open_state()

  let #(next, event) = room.apply_command(state, room.Leave(id))

  assert next == state
  assert event == room.LeaveRejected(id, room.NotJoined)
}

pub fn snapshot_preserves_multiple_participants_test() {
  let alice = room.participant_id("p1")
  let bob = room.participant_id("p2")
  let #(state, _) = room.apply_command(open_state(), room.Join(alice, "Alice"))
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))

  assert room.snapshot(state)
    == [
      room.Participant(alice, "Alice", True, room.Player),
      room.Participant(bob, "Bob", True, room.Player),
    ]
}

pub fn actor_join_and_snapshot_round_trip_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let id = room.participant_id("p1")
  let session = process.new_subject()

  let assert Ok(event) = room.dispatch(subject, room.Join(id, "Alice"), session)

  assert event
    == room.ParticipantJoined(
      room.Participant(id, "Alice", True, room.Player),
      1,
    )
  assert room.get_snapshot(subject)
    == Ok([room.Participant(id, "Alice", True, room.Player)])
}

pub fn independent_room_actors_do_not_share_state_test() {
  let assert Ok(room_a) = start_open()
  let assert Ok(room_b) = start_open()
  let id = room.participant_id("p1")
  let session = process.new_subject()

  let assert Ok(_) = room.dispatch(room_a.data, room.Join(id, "Alice"), session)

  assert room.get_snapshot(room_a.data)
    == Ok([room.Participant(id, "Alice", True, room.Player)])
  assert room.get_snapshot(room_b.data) == Ok([])
}

pub fn join_broadcasts_to_other_subscribers_but_not_the_joiner_test() {
  let assert Ok(started) = start_open()
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
    == Ok(room.ParticipantJoined(
      room.Participant(bob, "Bob", True, room.Player),
      2,
    ))
}

pub fn leave_broadcasts_to_remaining_subscribers_test() {
  let assert Ok(started) = start_open()
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

  assert process.receive(alice_session, 100) == Ok(room.ParticipantLeft(bob, 3))
  assert process.receive(bob_session, 100) == Error(Nil)
}

pub fn buzz_order_matches_acceptance_order_test() {
  let alice = room.participant_id("a")
  let bob = room.participant_id("b")
  let carol = room.participant_id("c")
  let #(state, _) = room.apply_command(open_state(), room.Join(alice, "Alice"))
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))
  let #(state, _) = room.apply_command(state, room.Join(carol, "Carol"))

  let #(state, bob_event) = room.apply_command(state, room.Buzz(bob, 1))
  let #(state, alice_event) = room.apply_command(state, room.Buzz(alice, 1))
  let #(state, carol_event) = room.apply_command(state, room.Buzz(carol, 1))

  assert bob_event == room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 4)
  assert alice_event == room.BuzzAccepted(alice, "Alice", 2, 1, room.Locked, 5)
  assert carol_event == room.BuzzAccepted(carol, "Carol", 3, 1, room.Locked, 6)
  assert room.buzz_snapshot(state)
    == [
      room.BuzzResult(bob, "Bob", 1),
      room.BuzzResult(alice, "Alice", 2),
      room.BuzzResult(carol, "Carol", 3),
    ]
}

pub fn duplicate_buzz_is_rejected_and_state_unchanged_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(open_state(), room.Join(id, "Alice"))
  let #(state, _) = room.apply_command(state, room.Buzz(id, 1))

  let #(next, event) = room.apply_command(state, room.Buzz(id, 1))

  assert next == state
  assert event == room.BuzzRejected(id, room.AlreadyBuzzed)
}

pub fn buzz_from_unjoined_participant_is_rejected_test() {
  let id = room.participant_id("p1")
  let state = open_state()

  let #(next, event) = room.apply_command(state, room.Buzz(id, 1))

  assert next == state
  assert event == room.BuzzRejected(id, room.BuzzerNotJoined)
}

/// 次の問題は buzz を空にし、受付前（Waiting）から始める（#768）。司会が
/// 受付を開くまで押せない。
pub fn next_question_clears_buzzes_and_waits_for_the_host_test() {
  let host = room.participant_id("host")
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(open_state(), room.JoinAsHost(host, "H"))
  let #(state, _) = room.apply_command(state, room.Join(id, "Alice"))
  let #(state, _) = room.apply_command(state, room.Buzz(id, 1))

  let #(next_state, event) =
    room.apply_command(state, room.NextQuestion(host, 1))

  assert event == room.RoundReset(2, 4)
  assert room.buzz_snapshot(next_state) == []
  assert next_state.round_id == 2
  assert next_state.phase == room.Waiting
  let #(_, early) = room.apply_command(next_state, room.Buzz(id, 2))
  assert early == room.BuzzRejected(id, room.NotAccepting)

  let #(opened, _) =
    room.apply_command(next_state, room.OpenAcceptance(host, 2))
  let #(_, rebuzz_event) = room.apply_command(opened, room.Buzz(id, 2))
  assert rebuzz_event == room.BuzzAccepted(id, "Alice", 1, 2, room.Locked, 6)
}

pub fn buzz_history_survives_the_buzzer_leaving_test() {
  // ADR 0003 / #30: buzz history outlives the participant's connection, so
  // `apply_leave` must not remove a departed participant's BuzzResult. This
  // pins the inverse of poker's leaving_participant_is_dropped_from_a_later_reveal_test.
  let alice = room.participant_id("p1")
  let bob = room.participant_id("p2")
  let #(state, _) = room.apply_command(open_state(), room.Join(alice, "Alice"))
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))
  let #(state, _) = room.apply_command(state, room.Buzz(bob, 1))

  let #(next, event) = room.apply_command(state, room.Leave(bob))

  assert event == room.ParticipantLeft(bob, 4)
  assert room.buzz_snapshot(next) == [room.BuzzResult(bob, "Bob", 1)]
}

pub fn actor_buzz_broadcasts_ordering_to_other_subscribers_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  let assert Ok(event) = room.dispatch(subject, room.Buzz(bob, 1), bob_session)

  assert event == room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 3)
  assert process.receive(alice_session, 100)
    == Ok(room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 3))
  // Bob also receives his own accepted buzz asynchronously (#143), on top
  // of the synchronous `dispatch` return value already asserted above.
  assert process.receive(bob_session, 100)
    == Ok(room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 3))
}

pub fn actor_next_question_clears_buzz_snapshot_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let host = room.participant_id("host")
  let host_session = process.new_subject()
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let assert Ok(_) = room.join_as_creator(subject, host, "Host", host_session)
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Buzz(alice, 1), alice_session)
  let _ = drain(host_session, [])

  let assert Ok(event) =
    room.dispatch(subject, room.NextQuestion(host, 1), host_session)

  assert event == room.RoundReset(2, 4)
  let assert Ok(room.Snapshot(buzzes:, phase:, ..)) = room.get_state(subject)
  assert buzzes == []
  assert phase == room.Waiting
  // RoundReset is on the same issuer-inclusive branch as Buzz (#465), so
  // the host also receives an async second copy.
  assert process.receive(host_session, 100) == Ok(room.RoundReset(2, 4))
}

pub fn departed_subscriber_receives_no_further_broadcasts_test() {
  let assert Ok(started) = start_open()
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
    == Ok(room.ParticipantJoined(
      room.Participant(carol, "Carol", True, room.Player),
      4,
    ))
}

pub fn rejoin_after_leave_is_a_new_transient_identity_with_current_snapshot_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let alice_old = room.participant_id("connection-1")
  let alice_old_session = process.new_subject()
  let _ =
    room.dispatch(subject, room.Join(alice_old, "Alice"), alice_old_session)
  let assert Ok(_) =
    room.dispatch(subject, room.Buzz(alice_old, 1), alice_old_session)

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
    == Ok(room.ParticipantJoined(
      room.Participant(alice_new, "Alice", True, room.Player),
      4,
    ))
  assert alice_new != alice_old

  // The snapshot delivered on rejoin reflects current room state: the old
  // identity's buzz is preserved (per ADR 0003, buzz history lives in the
  // active Room process, not tied to any one connection), and presence
  // reflects only the reconnected participant.
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice_new, "Alice", True, room.Player)])
  let assert Ok(room.Snapshot(buzzes:, ..)) = room.get_state(subject)
  assert buzzes == [room.BuzzResult(alice_old, "Alice", 1)]
}

pub fn rejoin_before_old_connections_leave_keeps_both_identities_present_test() {
  let assert Ok(started) = start_open()
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
      room.Participant(alice_old, "Alice", True, room.Player),
      room.Participant(alice_new, "Alice", True, room.Player),
    ])

  let assert Ok(_) =
    room.dispatch(subject, room.Leave(alice_old), alice_old_session)

  // Once the stale connection's `Leave` is processed, only the reconnected
  // identity remains present.
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice_new, "Alice", True, room.Player)])
}

pub fn independent_room_actors_do_not_share_buzz_state_test() {
  let assert Ok(room_a) = start_open()
  let assert Ok(room_b) = start_open()
  let id = room.participant_id("p1")
  let session = process.new_subject()
  let assert Ok(_) = room.dispatch(room_a.data, room.Join(id, "Alice"), session)
  let assert Ok(_) = room.dispatch(room_b.data, room.Join(id, "Alice"), session)

  let assert Ok(_) = room.dispatch(room_a.data, room.Buzz(id, 1), session)

  let assert Ok(room.Snapshot(instance_id: instance_a, buzzes: buzzes_a, ..)) =
    room.get_state(room_a.data)
  assert buzzes_a == [room.BuzzResult(id, "Alice", 1)]
  let assert Ok(room.Snapshot(instance_id: instance_b, buzzes: buzzes_b, ..)) =
    room.get_state(room_b.data)
  assert buzzes_b == []
  // 同じ部屋コードで作り直された room と取り違えないよう、actor ごとに
  // 異なる世代を持つ（#765）。
  assert instance_a != instance_b
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
/// 1 つ置くほうが確実。#766 以降は、まず切断中になり、復帰の猶予が切れて
/// から消える。猶予を短くした room で両方の段階を確かめる。
pub fn a_participant_whose_session_dies_is_removed_test() {
  let assert Ok(started) = room.start_accepting_with_grace(100)
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
    room.Participant(survivor, "Survivor", True, room.Player),
    room.Participant(doomed, "Doomed", True, room.Player),
  ]
  wait.until(fn() { room.get_snapshot(subject) == Ok(both) }, "2 人とも join し終わる")

  process.kill(doomed_pid)

  // まず切断中として残る（同じ参加者として戻れる）。
  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([
        room.Participant(survivor, "Survivor", True, room.Player),
        room.Participant(doomed, "Doomed", False, room.Player),
      ])
    },
    "死んだ接続の参加者が切断中になる",
  )

  // 猶予が切れると、死んだ接続の参加者だけが消え、room 自体は生きている。
  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([room.Participant(survivor, "Survivor", True, room.Player)])
    },
    "死んだ接続の参加者が片付く",
  )
}

/// 同一物理接続がタイムアウト後に再joinしても、接続が死ねば両方の
/// `ParticipantId` が片付くこと（#459）。
///
/// `with_room_reply` のタイムアウト分岐は `ConnectionState.room` を `None` に
/// 戻すだけで `Leave` を送らないため、同じ接続（＝同じ pid）が新しい
/// `ParticipantId` で再joinしうる（#100）。修正前は `sessions` の値が
/// pid ごとの単一エントリだったため、2回目の join が1回目の監視エントリを
/// 上書きし、接続が最終的に死んでも1回目の参加者（`alice_old`）が
/// `state.room.participants` に残り続ける「幽霊参加者」になっていた。
pub fn ghost_participant_from_same_connection_rejoin_is_cleaned_up_on_death_test() {
  let assert Ok(started) = room.start_accepting_with_grace(50)
  let subject = started.data

  // room が空になって自己停止しないよう、無関係な生存者を先に join させておく
  // （`get_snapshot` を最後まで問い合わせ続けられるようにするため）。
  let survivor = room.participant_id("survivor")
  let survivor_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(survivor, "Survivor"), survivor_session)

  let alice_old = room.participant_id("connection-1")
  let alice_new = room.participant_id("connection-2")

  let connection_pid =
    process.spawn_unlinked(fn() {
      let session = process.new_subject()
      let _ = room.dispatch(subject, room.Join(alice_old, "Alice"), session)
      // 同一接続（同一 session/pid）から、旧IDに対する Leave を送らずに
      // 再度 Join する。
      let _ = room.dispatch(subject, room.Join(alice_new, "Alice"), session)
      // room 側が両方の監視を張るまで生きている必要がある。
      process.sleep(500)
    })

  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([
        room.Participant(survivor, "Survivor", True, room.Player),
        room.Participant(alice_old, "Alice", True, room.Player),
        room.Participant(alice_new, "Alice", True, room.Player),
      ])
    },
    "同一接続からの再joinで両方のIDが一時的に併存する",
  )

  process.kill(connection_pid)

  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([room.Participant(survivor, "Survivor", True, room.Player)])
    },
    "接続が死ねば再joinで増えた分も含めて全員が片付く",
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
  let assert Ok(started) = start_open()
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
  assert room.get_snapshot(subject)
    == Ok([room.Participant(id, "Alice", True, room.Player)])
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
  let assert Ok(started) = start_open()
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
  // 残った参加者も引き続き使える。落ちた参加者は猶予中の切断扱い（#766）。
  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([
        room.Participant(survivor, "Survivor", True, room.Player),
        room.Participant(doomed, "Doomed", False, room.Player),
      ])
    },
    "落ちた参加者が切断中になり、残りは使える",
  )
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
    let assert Ok(started) = start_open()
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
  let assert Ok(started) = start_open()
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
      let assert Ok(event) = room.dispatch(subject, room.Buzz(id, 1), session)
      process.send(results, #(event, display_name))
      process.sleep(3000)
    })
  })

  let accepted = collect_buzz_events(results, count, [])
  let positions =
    accepted
    |> list.map(fn(reported) {
      let assert room.BuzzAccepted(position:, ..) = reported.0
      position
    })
    |> list.sort(int.compare)

  // 1..N が重複なく揃う。同じ位置を 2 人が取っていれば長さが足りなくなる。
  assert positions == one_to(count)

  // room 側の記録と、各参加者が受け取った通知が食い違わない。
  let assert Ok(room.Snapshot(buzzes: snapshot, ..)) = room.get_state(subject)
  assert list.length(snapshot) == count
  assert list.map(snapshot, fn(result) { result.position }) == one_to(count)

  let reported =
    accepted
    |> list.map(fn(reported) {
      let assert room.BuzzAccepted(id:, position:, ..) = reported.0
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

fn fill_round_with_churn(state: room.RoomState, count: Int) -> room.RoomState {
  int.range(from: 1, to: count + 1, with: state, run: fn(state, i) {
    let id = room.participant_id("churn" <> int.to_string(i))
    let #(state, _) = room.apply_command(state, room.Join(id, "Guest"))
    let #(state, _) = room.apply_command(state, room.Buzz(id, 1))
    let #(state, _) = room.apply_command(state, room.Leave(id))
    state
  })
}

pub fn buzz_beyond_round_limit_is_rejected_and_order_kept_test() {
  let anchor = room.participant_id("anchor")
  let #(state, _) =
    room.apply_command(open_state(), room.Join(anchor, "Anchor"))
  let state = fill_round_with_churn(state, 128)
  assert list.length(room.buzz_snapshot(state)) == 128

  let #(next, event) = room.apply_command(state, room.Buzz(anchor, 1))

  assert next == state
  assert event == room.BuzzRejected(anchor, room.RoundFull)
}

pub fn buzz_at_round_limit_minus_one_is_still_accepted_test() {
  let anchor = room.participant_id("anchor")
  let #(state, _) =
    room.apply_command(open_state(), room.Join(anchor, "Anchor"))
  let state = fill_round_with_churn(state, 127)

  let #(next, event) = room.apply_command(state, room.Buzz(anchor, 1))

  // 1 join + 127 x (join, buzz, leave) = revision 382 before this buzz.
  assert event == room.BuzzAccepted(anchor, "Anchor", 128, 1, room.Locked, 383)
  assert list.length(room.buzz_snapshot(next)) == 128
}

pub fn next_question_lifts_round_limit_test() {
  let host = room.participant_id("host")
  let anchor = room.participant_id("anchor")
  let #(state, _) = room.apply_command(open_state(), room.JoinAsHost(host, "H"))
  let #(state, _) = room.apply_command(state, room.Join(anchor, "Anchor"))
  let state = fill_round_with_churn(state, 128)
  let #(state, _) = room.apply_command(state, room.NextQuestion(host, 1))
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 2))

  let #(_, event) = room.apply_command(state, room.Buzz(anchor, 2))

  // 2 joins + 128 x 3 = 386, next question 387, open 388.
  assert event == room.BuzzAccepted(anchor, "Anchor", 1, 2, room.Locked, 389)
}

/// 前の round を名指しした buzz は拒否され、状態も revision も変わらない（#765）。
pub fn buzz_for_a_stale_round_is_rejected_and_state_unchanged_test() {
  let host = room.participant_id("host")
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(open_state(), room.JoinAsHost(host, "H"))
  let #(state, _) = room.apply_command(state, room.Join(id, "Alice"))
  let #(state, _) = room.apply_command(state, room.NextQuestion(host, 1))
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 2))

  let #(next, event) = room.apply_command(state, room.Buzz(id, 1))

  assert next == state
  assert event == room.BuzzRejected(id, room.BuzzStaleRound)
}

/// 同じ round への2回目の「次の問題」は新しい round を始めない（#765, #768）。
/// 二重クリックや再送で、始まったばかりの問題の buzz を消さない。
pub fn second_next_question_for_the_same_round_is_rejected_test() {
  let host = room.participant_id("host")
  let alice = room.participant_id("a")
  let #(state, _) = room.apply_command(open_state(), room.JoinAsHost(host, "H"))
  let #(state, _) = room.apply_command(state, room.Join(alice, "Alice"))
  let #(state, _) = room.apply_command(state, room.NextQuestion(host, 1))
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 2))
  let #(state, _) = room.apply_command(state, room.Buzz(alice, 2))

  let #(next, event) = room.apply_command(state, room.NextQuestion(host, 1))

  assert next == state
  assert event == room.CommandRejected(room.StaleRound)
  assert room.buzz_snapshot(next) == [room.BuzzResult(alice, "Alice", 1)]
}

/// 受理された変更だけが revision を1ずつ進める（#765）。
pub fn only_accepted_changes_advance_the_revision_test() {
  let host = room.participant_id("host")
  let id = room.participant_id("p1")
  let state = open_state()
  assert state.revision == 0
  let #(state, _) = room.apply_command(state, room.JoinAsHost(host, "H"))
  let #(state, _) = room.apply_command(state, room.Join(id, "Alice"))
  assert state.revision == 2
  let #(state, _) = room.apply_command(state, room.Join(id, "Alice"))
  assert state.revision == 2
  let #(state, _) = room.apply_command(state, room.Buzz(id, 1))
  let #(state, _) = room.apply_command(state, room.Buzz(id, 1))
  assert state.revision == 3
  let #(state, _) = room.apply_command(state, room.NextQuestion(host, 1))
  let #(state, _) = room.apply_command(state, room.NextQuestion(host, 1))
  let #(state, _) = room.apply_command(state, room.NextQuestion(id, 2))
  assert state.revision == 4
  assert state.round_id == 2
}

/// `room.join` のスナップショットは自分の join を含み、以後に購読経由で
/// 届く配信は必ずその revision の次から始まる（#765, #43）。
pub fn join_snapshot_is_taken_with_the_join_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let host = room.participant_id("host")
  let host_session = process.new_subject()
  let assert Ok(_) = room.join_as_creator(subject, host, "Host", host_session)
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let assert Ok(_) = room.dispatch(subject, room.Buzz(alice, 1), alice_session)

  let assert Ok(room.JoinReply(event, snapshot, _token, _)) =
    room.join(subject, bob, "Bob", bob_session)

  assert event
    == room.ParticipantJoined(
      room.Participant(bob, "Bob", True, room.Player),
      4,
    )
  assert snapshot.revision == 4
  assert snapshot.round_id == 1
  assert snapshot.participants
    == [
      room.Participant(host, "Host", True, room.Host),
      room.Participant(alice, "Alice", True, room.Player),
      room.Participant(bob, "Bob", True, room.Player),
    ]
  assert snapshot.buzzes == [room.BuzzResult(alice, "Alice", 1)]
  // 参加より前の変更は bob の購読には届かない。
  assert process.receive(bob_session, 50) == Error(Nil)

  let assert Ok(_) =
    room.dispatch(subject, room.NextQuestion(host, 1), host_session)
  assert process.receive(bob_session, 100) == Ok(room.RoundReset(2, 5))

  let assert Ok(again) = room.get_state(subject)
  assert again.instance_id == snapshot.instance_id
  assert again.revision == 5
}

// --- #766: 短時間の切断からの復帰 -------------------------------------------

fn join_with_token(
  subject: process.Subject(room.Message),
  id: room.ParticipantId,
  name: String,
  session: process.Subject(room.RoomEvent),
) -> #(String, room.Snapshot) {
  let assert Ok(room.JoinReply(
    room.ParticipantJoined(..),
    snapshot,
    option.Some(token),
    option.None,
  )) = room.join(subject, id, name, session)
  #(token, snapshot)
}

pub fn disconnect_and_reconnect_are_revisioned_presence_changes_test() {
  let id = room.participant_id("p1")
  let #(state, _) = room.apply_command(open_state(), room.Join(id, "A"))
  let #(state, event) = room.apply_command(state, room.Disconnect(id))
  assert event == room.ParticipantDisconnected(id, 2)
  assert room.snapshot(state) == [room.Participant(id, "A", False, room.Player)]
  // 既に切断中なら何も変えない（revision も進めない）。
  let #(same, again) = room.apply_command(state, room.Disconnect(id))
  assert again == room.PresenceRejected(id)
  assert same == state
  let #(state, event) = room.apply_command(state, room.Reconnect(id))
  assert event == room.ParticipantReconnected(id, 3)
  assert room.snapshot(state) == [room.Participant(id, "A", True, room.Player)]
}

pub fn resume_within_grace_keeps_the_participant_and_their_buzz_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let alice = room.participant_id("alice")
  let bob = room.participant_id("bob")
  let alice_session = process.new_subject()
  let bob_session = process.new_subject()
  let #(token, snapshot) =
    join_with_token(subject, alice, "Alice", alice_session)
  let _ = join_with_token(subject, bob, "Bob", bob_session)
  let _ = process.receive(alice_session, 100)
  let assert Ok(room.BuzzAccepted(..)) =
    room.dispatch(subject, room.Buzz(alice, 1), alice_session)
  let _ = process.receive(alice_session, 100)
  let _ = process.receive(bob_session, 100)

  room.detach(subject, alice, alice_session)
  assert process.receive(bob_session, 100)
    == Ok(room.ParticipantDisconnected(alice, 4))

  let new_session = process.new_subject()
  let assert Ok(room.Resumed(resumed_id, resumed)) =
    room.resume_session(
      subject,
      token,
      option.None,
      snapshot.instance_id,
      new_session,
    )
  assert resumed_id == alice
  assert resumed.participants
    == [
      room.Participant(alice, "Alice", True, room.Player),
      room.Participant(bob, "Bob", True, room.Player),
    ]
  assert resumed.buzzes == [room.BuzzResult(alice, "Alice", 1)]
  assert process.receive(bob_session, 100)
    == Ok(room.ParticipantReconnected(alice, 5))
  // 戻った本人には配信しない（スナップショットに含まれている）。
  assert process.receive(new_session, 50) == Error(Nil)

  // 押下済みは引き継がれ、二重には押せない。
  assert room.dispatch(subject, room.Buzz(alice, 1), new_session)
    == Ok(room.BuzzRejected(alice, room.AlreadyBuzzed))
}

pub fn the_replaced_connection_can_no_longer_act_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let alice = room.participant_id("alice")
  let old_session = process.new_subject()
  let #(token, snapshot) = join_with_token(subject, alice, "Alice", old_session)

  // 切断を検知する前に、複製したタブなどが同じ token で戻る。
  let new_session = process.new_subject()
  let assert Ok(room.Resumed(..)) =
    room.resume_session(
      subject,
      token,
      option.None,
      snapshot.instance_id,
      new_session,
    )
  assert process.receive(old_session, 100) == Ok(room.SessionReplaced)

  // 古い接続のコマンド・遅れた Detach・Leave はどれも効かない。
  assert room.dispatch(subject, room.Buzz(alice, 1), old_session)
    == Ok(room.BuzzRejected(alice, room.BuzzerNotJoined))
  assert room.dispatch(subject, room.NextQuestion(alice, 1), old_session)
    == Ok(room.CommandRejected(room.CommandNotJoined))
  room.detach(subject, alice, old_session)
  assert room.dispatch(subject, room.Leave(alice), old_session)
    == Ok(room.LeaveRejected(alice, room.NotJoined))
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice, "Alice", True, room.Player)])
  // 新しい接続は使える。
  let assert Ok(room.BuzzAccepted(..)) =
    room.dispatch(subject, room.Buzz(alice, 1), new_session)
}

pub fn a_stale_grace_timer_does_not_remove_a_resumed_participant_test() {
  let assert Ok(started) = room.start_accepting_with_grace(50)
  let subject = started.data
  let alice = room.participant_id("alice")
  let session = process.new_subject()
  let #(token, snapshot) = join_with_token(subject, alice, "Alice", session)

  room.detach(subject, alice, session)
  let resumed_session = process.new_subject()
  let assert Ok(room.Resumed(..)) =
    room.resume_session(
      subject,
      token,
      option.None,
      snapshot.instance_id,
      resumed_session,
    )
  // 1 回目の切断のタイマー（前の世代）が満了しても外れない。
  process.sleep(150)
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice, "Alice", True, room.Player)])
}

pub fn resume_is_rejected_for_wrong_room_unknown_or_expired_token_test() {
  let assert Ok(started) = room.start_accepting_with_grace(50)
  let subject = started.data
  let alice = room.participant_id("alice")
  let bob = room.participant_id("bob")
  let alice_session = process.new_subject()
  let bob_session = process.new_subject()
  let #(alice_token, snapshot) =
    join_with_token(subject, alice, "Alice", alice_session)
  let #(bob_token, _) = join_with_token(subject, bob, "Bob", bob_session)
  let other = process.new_subject()

  assert room.resume_session(
      subject,
      alice_token,
      option.None,
      "another-instance",
      other,
    )
    == Ok(room.ResumeRejected(room.RoomGone))
  assert room.resume_session(
      subject,
      "not-a-token",
      option.None,
      snapshot.instance_id,
      other,
    )
    == Ok(room.ResumeRejected(room.InvalidToken))

  // 明示的な退出の後は戻れない。
  let assert Ok(room.ParticipantLeft(..)) =
    room.dispatch(subject, room.Leave(bob), bob_session)
  assert room.resume_session(
      subject,
      bob_token,
      option.None,
      snapshot.instance_id,
      other,
    )
    == Ok(room.ResumeRejected(room.ResumeExpired))

  // 猶予切れの後は grace_expiry_removes_the_participant_but_keeps_their_buzz_test。
  let _ = alice_session
}

pub fn grace_expiry_removes_the_participant_but_keeps_their_buzz_test() {
  let assert Ok(started) = room.start_accepting_with_grace(50)
  let subject = started.data
  let alice = room.participant_id("alice")
  let bob = room.participant_id("bob")
  let alice_session = process.new_subject()
  let bob_session = process.new_subject()
  let #(token, snapshot) =
    join_with_token(subject, alice, "Alice", alice_session)
  let _ = join_with_token(subject, bob, "Bob", bob_session)
  let assert Ok(room.BuzzAccepted(..)) =
    room.dispatch(subject, room.Buzz(alice, 1), alice_session)

  room.detach(subject, alice, alice_session)
  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([room.Participant(bob, "Bob", True, room.Player)])
    },
    "猶予が切れた参加者が外れる",
  )
  let assert Ok(room.Snapshot(buzzes:, ..)) = room.get_state(subject)
  assert buzzes == [room.BuzzResult(alice, "Alice", 1)]
  assert room.resume_session(
      subject,
      token,
      option.None,
      snapshot.instance_id,
      process.new_subject(),
    )
    == Ok(room.ResumeRejected(room.ResumeExpired))
}

pub fn the_room_stops_when_the_last_grace_expires_test() {
  let assert Ok(started) = room.start_accepting_with_grace(50)
  let subject = started.data
  let assert Ok(pid) = process.subject_owner(subject)
  let alice = room.participant_id("alice")
  let session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", session)

  room.detach(subject, alice, session)
  // 猶予中は止まらない（Release による空判定でも止まらない）。
  assert room.shutdown_if_empty(subject) == False
  assert process.is_alive(pid)
  wait.until_dead(pid, "最後の参加者の猶予切れで room が止まる")
}

pub fn presence_commands_are_not_accepted_from_outside_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let alice = room.participant_id("alice")
  let session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", session)
  assert room.dispatch(subject, room.Disconnect(alice), session)
    == Ok(room.PresenceRejected(alice))
  assert room.get_snapshot(subject)
    == Ok([room.Participant(alice, "Alice", True, room.Player)])
}

pub fn resume_tokens_are_never_broadcast_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let alice = room.participant_id("alice")
  let bob = room.participant_id("bob")
  let alice_session = process.new_subject()
  let bob_session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", alice_session)
  let #(bob_token, snapshot) = join_with_token(subject, bob, "Bob", bob_session)
  room.detach(subject, bob, bob_session)
  let assert Ok(_) =
    room.resume_session(
      subject,
      bob_token,
      option.None,
      snapshot.instance_id,
      process.new_subject(),
    )
  let received = drain(alice_session, [])
  assert list.length(received) == 3
  assert !string.contains(string.inspect(received), bob_token)
  let assert Ok(state) = room.get_state(subject)
  assert !string.contains(string.inspect(state), bob_token)
}

fn drain(
  subject: process.Subject(room.RoomEvent),
  acc: List(room.RoomEvent),
) -> List(room.RoomEvent) {
  case process.receive(subject, 50) {
    Ok(event) -> drain(subject, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn departed_participants_are_tracked_within_a_bound_test() {
  let assert Ok(started) = start_open()
  let subject = started.data
  let first = room.participant_id("churn-0")
  let first_session = process.new_subject()
  let #(first_token, snapshot) =
    join_with_token(subject, first, "P", first_session)
  let assert Ok(_) = room.dispatch(subject, room.Leave(first), first_session)
  let last_token =
    int.range(from: 1, to: 200, with: "", run: fn(_, i) {
      let id = room.participant_id("churn-" <> int.to_string(i))
      let session = process.new_subject()
      let #(token, _) = join_with_token(subject, id, "P", session)
      let assert Ok(_) = room.dispatch(subject, room.Leave(id), session)
      token
    })
  let other = process.new_subject()
  // 古い退出者の記録は上限を超えた分から捨てられ、最近の退出者は残る。
  assert room.resume_session(
      subject,
      first_token,
      option.None,
      snapshot.instance_id,
      other,
    )
    == Ok(room.ResumeRejected(room.InvalidToken))
  assert room.resume_session(
      subject,
      last_token,
      option.None,
      snapshot.instance_id,
      other,
    )
    == Ok(room.ResumeRejected(room.ResumeExpired))
}

// --- #767: 部屋の作成と司会 token ---------------------------------------------

/// 部屋を作った参加者にだけ司会 token が発行される。2人目以降は作成者の
/// 経路を通っても受け取れず、通常の join（招待）は常に受け取らない。
pub fn only_the_creator_receives_the_host_token_test() {
  let assert Ok(started) = start_open()
  let subject = started.data

  let assert Ok(room.JoinReply(
    room.ParticipantJoined(..),
    _,
    option.Some(alice_resume),
    option.Some(host_token),
  )) =
    room.join_as_creator(
      subject,
      room.participant_id("p1"),
      "Alice",
      process.new_subject(),
    )
  assert host_token != alice_resume

  let assert Ok(room.JoinReply(room.ParticipantJoined(..), _, _, option.None)) =
    room.join(subject, room.participant_id("p2"), "Bob", process.new_subject())
  let assert Ok(room.JoinReply(room.ParticipantJoined(..), _, _, option.None)) =
    room.join_as_creator(
      subject,
      room.participant_id("p3"),
      "Carol",
      process.new_subject(),
    )
}

/// 拒否された作成者の join には token が付かず、司会の席も空いたまま。
pub fn a_rejected_creator_join_issues_no_host_token_test() {
  let assert Ok(started) = start_open()
  let subject = started.data

  let assert Ok(room.JoinReply(
    room.JoinRejected(..),
    _,
    option.None,
    option.None,
  )) =
    room.join_as_creator(
      subject,
      room.participant_id("p1"),
      "",
      process.new_subject(),
    )
  let assert Ok(room.JoinReply(_, _, _, option.Some(_))) =
    room.join_as_creator(
      subject,
      room.participant_id("p2"),
      "Alice",
      process.new_subject(),
    )
}

/// 作られたまま誰も参加しない部屋は、空室の猶予が過ぎると止まる。
pub fn an_unused_room_stops_after_the_empty_room_grace_test() {
  let assert Ok(started) = room.start_with_timings(60_000, 30)
  let assert Ok(pid) = process.subject_owner(started.data)

  wait.until(fn() { !process.is_alive(pid) }, "誰も来ない部屋が止まる")
}

/// 猶予の前に参加者が来た部屋は止まらない。
pub fn a_joined_room_outlives_the_empty_room_grace_test() {
  let assert Ok(started) = room.start_with_timings(60_000, 30)
  let subject = started.data
  let assert Ok(pid) = process.subject_owner(subject)
  let assert Ok(_) =
    room.join_as_creator(
      subject,
      room.participant_id("p1"),
      "Alice",
      process.new_subject(),
    )

  process.sleep(80)
  assert process.is_alive(pid)
}

fn start_open() {
  room.start_accepting_with_grace(room.default_participant_grace_ms)
}

/// Acceptance already open, no host: for tests about buzz ordering and
/// limits that do not involve the host (#768).
fn open_state() -> room.RoomState {
  room.RoomState(..room.new_state(), phase: room.Open)
}

// --- #768: 役割・受付の段階・司会の操作 ---------------------------------------

fn hosted_room() -> #(room.RoomState, room.ParticipantId, room.ParticipantId) {
  let host = room.participant_id("host")
  let alice = room.participant_id("alice")
  let #(state, _) =
    room.apply_command(room.new_state(), room.JoinAsHost(host, "Host"))
  let #(state, _) = room.apply_command(state, room.Join(alice, "Alice"))
  #(state, host, alice)
}

pub fn the_host_opens_and_the_first_buzz_locks_test() {
  let #(state, host, alice) = hosted_room()
  let bob = room.participant_id("bob")
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))
  assert state.phase == room.Waiting

  let #(state, opened) = room.apply_command(state, room.OpenAcceptance(host, 1))
  assert opened == room.PhaseChanged(room.Open, 1, 4)

  let #(state, first) = room.apply_command(state, room.Buzz(bob, 1))
  assert first == room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 5)
  // 回答者が決まった後の buzz も順番に積まれ、回答者は変わらない。
  let #(state, second) = room.apply_command(state, room.Buzz(alice, 1))
  assert second == room.BuzzAccepted(alice, "Alice", 2, 1, room.Locked, 6)
  assert state.phase == room.Locked

  let #(state, skipped) = room.apply_command(state, room.Skip(host, 1))
  assert skipped == room.PhaseChanged(room.Waiting, 1, 7)
  // 閉じた問題の結果は次の問題まで残る。
  assert list.length(room.buzz_snapshot(state)) == 2
}

pub fn the_host_can_close_acceptance_before_anyone_buzzes_test() {
  let #(state, host, alice) = hosted_room()
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 1))
  let #(state, closed) =
    room.apply_command(state, room.CloseAcceptance(host, 1))
  assert closed == room.PhaseChanged(room.Waiting, 1, 4)
  let #(_, late) = room.apply_command(state, room.Buzz(alice, 1))
  assert late == room.BuzzRejected(alice, room.NotAccepting)
}

/// 二重クリックや再送で段階が二重に進まない。2回目は拒否され revision も
/// 進まない。
pub fn repeated_host_commands_do_not_transition_twice_test() {
  let #(state, host, _alice) = hosted_room()
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 1))
  let #(same, again) = room.apply_command(state, room.OpenAcceptance(host, 1))
  assert again == room.CommandRejected(room.InvalidPhase)
  assert same == state

  let #(state, _) = room.apply_command(state, room.CloseAcceptance(host, 1))
  let #(same, again) = room.apply_command(state, room.CloseAcceptance(host, 1))
  assert again == room.CommandRejected(room.InvalidPhase)
  assert same == state
  let #(_, skip_waiting) = room.apply_command(state, room.Skip(host, 1))
  assert skip_waiting == room.CommandRejected(room.InvalidPhase)
}

/// 司会の操作は司会だけ。参加者が送っても拒否され、状態は変わらない。
/// 司会は押せない。
pub fn only_the_host_runs_the_questions_and_the_host_does_not_buzz_test() {
  let #(state, host, alice) = hosted_room()
  let commands = [
    room.OpenAcceptance(alice, 1),
    room.CloseAcceptance(alice, 1),
    room.Skip(alice, 1),
    room.NextQuestion(alice, 1),
    room.TransferHost(alice, alice),
    room.EndSession(alice),
  ]
  list.each(commands, fn(command) {
    let #(next, event) = room.apply_command(state, command)
    assert event == room.CommandRejected(room.Forbidden)
    assert next == state
  })
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 1))
  let #(_, host_buzz) = room.apply_command(state, room.Buzz(host, 1))
  assert host_buzz == room.BuzzRejected(host, room.HostCannotBuzz)
}

pub fn a_host_command_for_an_old_round_is_stale_test() {
  let #(state, host, _alice) = hosted_room()
  let #(state, _) = room.apply_command(state, room.NextQuestion(host, 1))
  let #(next, event) = room.apply_command(state, room.OpenAcceptance(host, 1))
  assert event == room.CommandRejected(room.StaleRound)
  assert next == state
}

/// 終了後は読み取りだけ。押す・司会の操作・新しい参加はどれも拒否される。
pub fn after_ending_the_session_everything_is_read_only_test() {
  let #(state, host, alice) = hosted_room()
  let #(state, _) = room.apply_command(state, room.OpenAcceptance(host, 1))
  let #(state, ended) = room.apply_command(state, room.EndSession(host))
  assert ended == room.PhaseChanged(room.Finished, 1, 4)

  let #(_, buzz) = room.apply_command(state, room.Buzz(alice, 1))
  assert buzz == room.BuzzRejected(alice, room.BuzzSessionFinished)
  let #(_, next_question) =
    room.apply_command(state, room.NextQuestion(host, 1))
  assert next_question == room.CommandRejected(room.SessionFinished)
  let #(_, again) = room.apply_command(state, room.EndSession(host))
  assert again == room.CommandRejected(room.SessionFinished)
  let newcomer = room.participant_id("late")
  let #(_, join) = room.apply_command(state, room.Join(newcomer, "Late"))
  assert join == room.JoinRejected(newcomer, room.JoinSessionFinished)
}

pub fn questions_are_limited_per_session_test() {
  let #(state, host, _alice) = hosted_room()
  let state = room.RoomState(..state, round_id: room.max_rounds)
  let #(next, event) =
    room.apply_command(state, room.NextQuestion(host, room.max_rounds))
  assert event == room.CommandRejected(room.SessionFull)
  assert next == state
}

pub fn the_host_role_moves_only_to_a_connected_player_test() {
  let #(state, host, alice) = hosted_room()
  let bob = room.participant_id("bob")
  let #(state, _) = room.apply_command(state, room.Join(bob, "Bob"))
  let #(away, _) = room.apply_command(state, room.Disconnect(bob))
  let #(_, to_disconnected) =
    room.apply_command(away, room.TransferHost(host, bob))
  assert to_disconnected == room.CommandRejected(room.InvalidTarget)
  let #(_, to_self) = room.apply_command(state, room.TransferHost(host, host))
  assert to_self == room.CommandRejected(room.InvalidTarget)
  let nobody = room.participant_id("nobody")
  let #(_, to_unknown) =
    room.apply_command(state, room.TransferHost(host, nobody))
  assert to_unknown == room.CommandRejected(room.InvalidTarget)

  let #(state, moved) =
    room.apply_command(state, room.TransferHost(host, alice))
  assert moved == room.HostTransferred(host, alice, 4)
  assert room.snapshot(state)
    == [
      room.Participant(host, "Host", True, room.Player),
      room.Participant(alice, "Alice", True, room.Host),
      room.Participant(bob, "Bob", True, room.Player),
    ]
  // 元の司会はもう司会の操作ができない。
  let #(_, old_host) = room.apply_command(state, room.OpenAcceptance(host, 1))
  assert old_host == room.CommandRejected(room.Forbidden)
}

pub fn a_host_who_goes_away_stops_acceptance_test() {
  let #(state, host, alice) = hosted_room()
  let #(open, _) = room.apply_command(state, room.OpenAcceptance(host, 1))
  let #(paused, event) = room.apply_command(open, room.HostAway(False))
  assert event == room.PhaseChanged(room.Waiting, 1, 4)
  assert paused.phase == room.Waiting

  // 回答者が決まった後の切断では止めない。退出なら止める。
  let #(locked, _) = room.apply_command(open, room.Buzz(alice, 1))
  let #(same, kept) = room.apply_command(locked, room.HostAway(False))
  assert kept == room.CommandRejected(room.InvalidPhase)
  assert same == locked
  let #(left, _) = room.apply_command(locked, room.HostAway(True))
  assert left.phase == room.Waiting
}

// --- #768: actor（司会の切断・退出・復帰・移譲、会場表示） --------------------

fn start_hosted() -> #(
  process.Subject(room.Message),
  room.ParticipantId,
  process.Subject(room.RoomEvent),
  String,
  String,
) {
  let assert Ok(started) = room.start_with_grace(50)
  let subject = started.data
  let host = room.participant_id("host")
  let session = process.new_subject()
  let assert Ok(room.JoinReply(
    room.ParticipantJoined(..),
    snapshot,
    option.Some(_),
    option.Some(host_token),
  )) = room.join_as_creator(subject, host, "Host", session)
  #(subject, host, session, host_token, snapshot.instance_id)
}

pub fn a_display_sees_changes_but_cannot_act_test() {
  let #(subject, host, host_session, _, _) = start_hosted()
  let display = process.new_subject()
  let assert Ok(room.Watching(snapshot)) = room.watch(subject, display)
  assert snapshot.phase == room.Waiting
  assert list.length(snapshot.participants) == 1

  let assert Ok(room.PhaseChanged(room.Open, 1, 2)) =
    room.dispatch(subject, room.OpenAcceptance(host, 1), host_session)
  assert process.receive(display, 100) == Ok(room.PhaseChanged(room.Open, 1, 2))

  // 会場表示の接続からのコマンドは、誰の名前で送っても拒否される。
  assert room.dispatch(subject, room.NextQuestion(host, 1), display)
    == Ok(room.CommandRejected(room.Forbidden))
  assert room.dispatch(subject, room.Buzz(host, 1), display)
    == Ok(room.CommandRejected(room.Forbidden))
  let assert Ok(room.Snapshot(phase: room.Open, round_id: 1, ..)) =
    room.get_state(subject)
  // 会場表示は参加者一覧に載らない。
  assert room.get_snapshot(subject)
    == Ok([room.Participant(host, "Host", True, room.Host)])
}

pub fn displays_are_limited_per_room_test() {
  let #(subject, _, _, _, _) = start_hosted()
  int.range(from: 0, to: 8, with: Nil, run: fn(_, _) {
    let assert Ok(room.Watching(_)) = room.watch(subject, process.new_subject())
    Nil
  })
  assert room.watch(subject, process.new_subject()) == Ok(room.DisplaysFull)
}

pub fn a_display_that_closes_stops_receiving_test() {
  let #(subject, host, host_session, _, _) = start_hosted()
  let display = process.new_subject()
  let assert Ok(room.Watching(_)) = room.watch(subject, display)
  room.unwatch(subject, display)
  let assert Ok(_) =
    room.dispatch(subject, room.OpenAcceptance(host, 1), host_session)
  assert process.receive(display, 50) == Error(Nil)
}

/// 司会が切れたら受付中のまま放置しない。他の参加者に知らせる。
pub fn a_disconnected_host_stops_acceptance_test() {
  let #(subject, host, host_session, _, _) = start_hosted()
  let alice = room.participant_id("alice")
  let alice_session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", alice_session)
  let assert Ok(_) =
    room.dispatch(subject, room.OpenAcceptance(host, 1), host_session)
  let _ = drain(alice_session, [])

  room.detach(subject, host, host_session)
  assert drain(alice_session, [])
    == [
      room.ParticipantDisconnected(host, 4),
      room.PhaseChanged(room.Waiting, 1, 5),
    ]
}

/// 司会は猶予が切れて一覧から外れても、司会 token で司会として戻れる。
/// resume token だけでは戻れない（猶予切れ）。
pub fn the_host_comes_back_with_the_host_token_after_the_grace_test() {
  let #(subject, host, host_session, host_token, instance) = start_hosted()
  let alice = room.participant_id("alice")
  let alice_session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", alice_session)

  room.detach(subject, host, host_session)
  wait.until(
    fn() {
      room.get_snapshot(subject)
      == Ok([room.Participant(alice, "Alice", True, room.Player)])
    },
    "司会の猶予が切れて一覧から外れる",
  )
  let _ = drain(alice_session, [])

  let back = process.new_subject()
  assert room.resume_session(
      subject,
      "wrong-resume-token",
      option.Some("forged-host-token"),
      instance,
      back,
    )
    == Ok(room.ResumeRejected(room.InvalidToken))
  let assert Ok(room.Resumed(id, snapshot)) =
    room.resume_session(
      subject,
      "wrong-resume-token",
      option.Some(host_token),
      instance,
      back,
    )
  assert id == host
  assert list.contains(
    snapshot.participants,
    room.Participant(host, "Host", True, room.Host),
  )
  let assert [room.ParticipantJoined(room.Participant(role: room.Host, ..), _)] =
    drain(alice_session, [])
  // 戻った司会は進行を続けられる。
  let assert Ok(room.PhaseChanged(room.Open, 1, _)) =
    room.dispatch(subject, room.OpenAcceptance(host, 1), back)
}

/// 移譲すると、新しい司会の接続にだけ新しい token が届き、元の token は
/// 使えなくなる。
pub fn transferring_the_host_issues_a_new_token_to_the_new_host_only_test() {
  let #(subject, host, host_session, old_token, instance) = start_hosted()
  let alice = room.participant_id("alice")
  let alice_session = process.new_subject()
  let bob = room.participant_id("bob")
  let bob_session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", alice_session)
  let _ = join_with_token(subject, bob, "Bob", bob_session)
  let _ = drain(alice_session, [])
  let _ = drain(bob_session, [])
  let _ = drain(host_session, [])

  let assert Ok(room.HostTransferred(host, alice, 4)) =
    room.dispatch(subject, room.TransferHost(host, alice), host_session)
  let alice_events = drain(alice_session, [])
  let assert [room.HostTransferred(..), room.HostAssigned(new_token)] =
    alice_events
  assert new_token != old_token
  let bob_events = drain(bob_session, [])
  assert bob_events == [room.HostTransferred(host, alice, 4)]
  assert !string.contains(string.inspect(bob_events), new_token)

  // 元の token では司会として戻れない（参加者としての resume token も無い
  // ので拒否される）。新しい司会は新しい token で戻れる。
  room.detach(subject, alice, alice_session)
  assert room.resume_session(
      subject,
      "none",
      option.Some(old_token),
      instance,
      process.new_subject(),
    )
    == Ok(room.ResumeRejected(room.InvalidToken))
  let assert Ok(room.Resumed(id, _)) =
    room.resume_session(
      subject,
      "none",
      option.Some(new_token),
      instance,
      process.new_subject(),
    )
  assert id == alice
}

/// 司会が自分で退出したら、回答者が決まった後でも受付を止める。席は残る
/// ので、token を持っていれば戻れる。
pub fn a_host_who_leaves_stops_acceptance_but_keeps_the_seat_test() {
  let #(subject, host, host_session, host_token, instance) = start_hosted()
  let alice = room.participant_id("alice")
  let alice_session = process.new_subject()
  let _ = join_with_token(subject, alice, "Alice", alice_session)
  let assert Ok(_) =
    room.dispatch(subject, room.OpenAcceptance(host, 1), host_session)
  let assert Ok(room.BuzzAccepted(phase: room.Locked, ..)) =
    room.dispatch(subject, room.Buzz(alice, 1), alice_session)
  let _ = drain(alice_session, [])

  let assert Ok(room.ParticipantLeft(..)) =
    room.dispatch(subject, room.Leave(host), host_session)
  assert drain(alice_session, [])
    == [room.ParticipantLeft(host, 5), room.PhaseChanged(room.Waiting, 1, 6)]
  let assert Ok(room.Resumed(id, _)) =
    room.resume_session(
      subject,
      "none",
      option.Some(host_token),
      instance,
      process.new_subject(),
    )
  assert id == host
}
