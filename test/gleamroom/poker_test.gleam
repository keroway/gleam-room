import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleamroom/poker
import gleamroom/wait

pub fn join_adds_participant_and_emits_joined_test() {
  let state = poker.new_state()
  let id = poker.participant_id("p1")

  let #(next, event) = poker.apply_command(state, poker.Join(id, "Alice"))

  assert poker.snapshot(next) == [poker.Participant(id, "Alice")]
  assert event == poker.ParticipantJoined(poker.Participant(id, "Alice"))
}

pub fn duplicate_join_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))

  let #(next, event) = poker.apply_command(state, poker.Join(id, "Alice again"))

  assert next == state
  assert event == poker.JoinRejected(id, poker.AlreadyJoined)
}

pub fn join_with_blank_display_name_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()

  let #(next, event) = poker.apply_command(state, poker.Join(id, "   "))

  assert next == state
  assert event == poker.JoinRejected(id, poker.InvalidDisplayName)
}

pub fn join_with_display_name_over_the_length_limit_is_rejected_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()
  let too_long = string.repeat("a", 65)

  let #(next, event) = poker.apply_command(state, poker.Join(id, too_long))

  assert next == state
  assert event == poker.JoinRejected(id, poker.InvalidDisplayName)
}

pub fn join_beyond_the_participant_limit_is_rejected_and_state_is_unchanged_test() {
  let full_state = fill_room(64)
  let overflow_id = poker.participant_id("overflow")

  let #(next, event) =
    poker.apply_command(full_state, poker.Join(overflow_id, "Overflow"))

  assert next == full_state
  assert event == poker.JoinRejected(overflow_id, poker.RoomFull)
}

pub fn join_with_display_name_at_the_length_limit_is_accepted_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()
  let at_limit = string.repeat("a", 64)

  let #(next, event) = poker.apply_command(state, poker.Join(id, at_limit))

  assert poker.snapshot(next) == [poker.Participant(id, at_limit)]
  assert event == poker.ParticipantJoined(poker.Participant(id, at_limit))
}

pub fn join_at_the_participant_limit_is_accepted_test() {
  let almost_full_state = fill_room(63)
  let last_id = poker.participant_id("last")

  let #(next, event) =
    poker.apply_command(almost_full_state, poker.Join(last_id, "Last"))

  assert list.length(poker.snapshot(next)) == 64
  assert event == poker.ParticipantJoined(poker.Participant(last_id, "Last"))
}

pub fn leave_removes_participant_and_emits_left_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))

  let #(next, event) = poker.apply_command(state, poker.Leave(id))

  assert poker.snapshot(next) == []
  assert event == poker.ParticipantLeft(id)
}

pub fn leave_of_unknown_participant_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()

  let #(next, event) = poker.apply_command(state, poker.Leave(id))

  assert next == state
  assert event == poker.LeaveRejected(id, poker.NotJoined)
}

pub fn vote_from_unjoined_participant_is_rejected_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()

  let #(next, event) = poker.apply_command(state, poker.Vote(id, poker.Five))

  assert next == state
  assert event == poker.VoteRejected(id, poker.VoterNotJoined)
}

pub fn vote_registers_without_revealing_the_value_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))

  let #(next, event) = poker.apply_command(state, poker.Vote(id, poker.Five))

  assert event == poker.VoteRegistered(id)
  assert poker.has_voted(next, id)
}

pub fn revoting_before_reveal_keeps_only_the_last_value_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Three))

  let #(state, event) = poker.apply_command(state, poker.Vote(id, poker.Eight))
  let #(_, revealed) = poker.apply_command(state, poker.Reveal)

  assert event == poker.VoteRegistered(id)
  assert revealed
    == poker.RoundRevealed([poker.RevealedVote(id, "Alice", Some(poker.Eight))])
}

pub fn vote_after_reveal_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Reveal)

  let #(next, event) = poker.apply_command(state, poker.Vote(id, poker.Eight))

  assert next == state
  assert event == poker.VoteRejected(id, poker.RoundAlreadyRevealed)
}

pub fn reveal_reports_every_participant_including_those_who_did_not_vote_test() {
  let alice = poker.participant_id("p1")
  let bob = poker.participant_id("p2")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(alice, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Join(bob, "Bob"))
  let #(state, _) = poker.apply_command(state, poker.Vote(alice, poker.Five))

  let #(next, event) = poker.apply_command(state, poker.Reveal)

  assert next.phase == poker.Revealed
  assert event
    == poker.RoundRevealed([
      poker.RevealedVote(alice, "Alice", Some(poker.Five)),
      poker.RevealedVote(bob, "Bob", None),
    ])
}

pub fn repeat_reveal_is_idempotent_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, first_reveal) = poker.apply_command(state, poker.Reveal)

  let #(next, second_reveal) = poker.apply_command(state, poker.Reveal)

  assert next == state
  assert second_reveal == first_reveal
}

pub fn reset_round_clears_votes_and_returns_to_voting_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Reveal)

  let #(next, event) = poker.apply_command(state, poker.ResetRound)

  assert event == poker.RoundReset
  assert next.phase == poker.Voting
  assert !poker.has_voted(next, id)
}

pub fn reset_from_voting_also_clears_votes_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))

  let #(next, event) = poker.apply_command(state, poker.ResetRound)

  assert event == poker.RoundReset
  assert next.phase == poker.Voting
  assert !poker.has_voted(next, id)
}

pub fn vote_is_allowed_again_after_reset_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Reveal)
  let #(state, _) = poker.apply_command(state, poker.ResetRound)

  let #(_, event) = poker.apply_command(state, poker.Vote(id, poker.Eight))

  assert event == poker.VoteRegistered(id)
}

pub fn leaving_participant_is_dropped_from_a_later_reveal_test() {
  let alice = poker.participant_id("p1")
  let bob = poker.participant_id("p2")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(alice, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Join(bob, "Bob"))
  let #(state, _) = poker.apply_command(state, poker.Vote(bob, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Leave(bob))

  let #(_, event) = poker.apply_command(state, poker.Reveal)

  assert event
    == poker.RoundRevealed([poker.RevealedVote(alice, "Alice", None)])
}

fn fill_room(count: Int) -> poker.PokerState {
  case count {
    0 -> poker.new_state()
    _ -> {
      let state = fill_room(count - 1)
      let id = poker.participant_id("p" <> string.inspect(count))
      let #(next, _) = poker.apply_command(state, poker.Join(id, "Name"))
      next
    }
  }
}

/// `poker.get_state` を経由した participants の読み出し。`room.gleam` の
/// `get_snapshot` に相当する専用メッセージを poker actor は持たないため、
/// テスト側でラップする（poker.gleam を変更しない範囲で完結させる）。
fn snapshot_of(
  subject: process.Subject(poker.Message),
) -> Result(List(poker.Participant), Nil) {
  poker.get_state(subject) |> result.map(poker.snapshot)
}

pub fn independent_poker_room_actors_do_not_share_state_test() {
  let assert Ok(room_a) = poker.start()
  let assert Ok(room_b) = poker.start()
  let id = poker.participant_id("p1")
  let session = process.new_subject()

  let assert Ok(_) =
    poker.dispatch(room_a.data, poker.Join(id, "Alice"), session)

  assert snapshot_of(room_a.data) == Ok([poker.Participant(id, "Alice")])
  assert snapshot_of(room_b.data) == Ok([])
}

pub fn join_broadcasts_to_other_subscribers_but_not_the_joiner_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let alice = poker.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = poker.participant_id("p2")
  let bob_session = process.new_subject()

  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(alice, "Alice"), alice_session)
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(bob, "Bob"), bob_session)

  // Bob's own join is only delivered synchronously via `dispatch`'s return
  // value, not re-broadcast to himself asynchronously.
  assert process.receive(bob_session, 100) == Error(Nil)
  assert process.receive(alice_session, 100)
    == Ok(poker.ParticipantJoined(poker.Participant(bob, "Bob")))
}

pub fn leave_broadcasts_to_remaining_subscribers_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let alice = poker.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = poker.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(alice, "Alice"), alice_session)
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  let assert Ok(_) = poker.dispatch(subject, poker.Leave(bob), bob_session)

  assert process.receive(alice_session, 100) == Ok(poker.ParticipantLeft(bob))
  assert process.receive(bob_session, 100) == Error(Nil)
}

pub fn departed_subscriber_receives_no_further_broadcasts_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let alice = poker.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = poker.participant_id("p2")
  let bob_session = process.new_subject()
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(alice, "Alice"), alice_session)
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  // Bob disconnects: the transport layer dispatches `Leave` on his behalf,
  // which drops his subject from the subscriber set (mirrors `on_close`).
  let assert Ok(_) = poker.dispatch(subject, poker.Leave(bob), bob_session)
  let _ = process.receive(alice_session, 100)

  // A later room event must not reach Bob's now-stale subject.
  let carol = poker.participant_id("p3")
  let carol_session = process.new_subject()
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(carol, "Carol"), carol_session)

  assert process.receive(bob_session, 100) == Error(Nil)
  assert process.receive(alice_session, 100)
    == Ok(poker.ParticipantJoined(poker.Participant(carol, "Carol")))
}

/// 接続プロセスが死んだ参加者が poker room から自動で消えること。
/// `room_test.gleam` の `a_participant_whose_session_dies_is_removed_test`
/// (#56 / #35) を poker ドメインへ移植したもの。
pub fn a_participant_whose_session_dies_is_removed_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data

  let survivor = poker.participant_id("survivor")
  let survivor_session = process.new_subject()
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(survivor, "Survivor"), survivor_session)

  // 別プロセスから join させ、そのプロセスを殺す。
  let doomed = poker.participant_id("doomed")
  let doomed_pid =
    process.spawn_unlinked(fn() {
      let doomed_session = process.new_subject()
      let _ =
        poker.dispatch(subject, poker.Join(doomed, "Doomed"), doomed_session)
      // room 側が監視を張るまで生きている必要がある。
      process.sleep(500)
    })

  let both = [
    poker.Participant(survivor, "Survivor"),
    poker.Participant(doomed, "Doomed"),
  ]
  wait.until(fn() { snapshot_of(subject) == Ok(both) }, "2 人とも join し終わる")

  process.kill(doomed_pid)

  // 死んだ接続の参加者だけが消え、room 自体は生きている。
  wait.until(
    fn() {
      snapshot_of(subject) == Ok([poker.Participant(survivor, "Survivor")])
    },
    "死んだ接続の参加者が片付く",
  )
}

/// `select_monitors` の `PortDown` 分岐が no-op であること。
/// `room_test.gleam` の `session_down_for_an_untracked_pid_is_a_no_op_test`
/// (#147) を poker ドメインへ移植したもの。
pub fn session_down_for_an_untracked_pid_is_a_no_op_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let assert Ok(room_pid) = process.subject_owner(subject)

  let id = poker.participant_id("p1")
  let session = process.new_subject()
  let assert Ok(_) = poker.dispatch(subject, poker.Join(id, "Alice"), session)

  // `PortDown` 分岐が実際に送るのと同じメッセージを、追跡されていない pid
  // （room actor 自身の pid）で直接送る。
  process.send(subject, poker.SessionDown(room_pid))

  // no-op なので room は生きたままで、参加者も変わらない。
  assert process.is_alive(room_pid)
  assert snapshot_of(subject) == Ok([poker.Participant(id, "Alice")])
}

/// 接続プロセスがクラッシュしても poker room actor が生き残ること。
/// `room_test.gleam` の `a_crashing_session_does_not_take_down_the_room_test`
/// (#69) を poker ドメインへ移植したもの。
pub fn a_crashing_session_does_not_take_down_the_room_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let assert Ok(room_pid) = process.subject_owner(subject)

  let survivor = poker.participant_id("survivor")
  let survivor_session = process.new_subject()
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(survivor, "Survivor"), survivor_session)

  // 別プロセスから join し、**異常終了**させる。
  let doomed = poker.participant_id("doomed")
  // 固定 sleep で join 完了を待たない。child が Join 前に死ぬと「room が
  // 生きている」だけが確認され、道連れの検証になっていない。
  let ready = process.new_subject()
  let doomed_pid =
    process.spawn_unlinked(fn() {
      let doomed_session = process.new_subject()
      let assert Ok(_) =
        poker.dispatch(subject, poker.Join(doomed, "Doomed"), doomed_session)
      process.send(ready, Nil)
      process.sleep(500)
    })

  let assert Ok(Nil) = process.receive(ready, 1000)
  process.kill(doomed_pid)
  wait.until_dead(doomed_pid, "接続プロセスが終了する")

  // room actor は生きている（link だとここで死んでいた）。
  assert process.is_alive(room_pid)
  // 残った参加者も引き続き使える。
  assert snapshot_of(subject) == Ok([poker.Participant(survivor, "Survivor")])
}

/// poker room actor が落ちても接続プロセスは生き残ること。
/// `room_test.gleam` の `a_crashing_room_does_not_take_down_the_sessions_test`
/// (#69) を poker ドメインへ移植したもの。
pub fn a_crashing_room_does_not_take_down_the_sessions_test() {
  // room は別プロセスから起動する。`actor.start` は呼び出し元と link するため、
  // テストプロセスから起動して kill するとテスト自体が巻き添えで死ぬ。
  let room_ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = poker.start()
    process.send(room_ready, started.data)
    process.sleep(3000)
  })
  let assert Ok(subject) = process.receive(room_ready, 1000)
  let assert Ok(room_pid) = process.subject_owner(subject)

  let ready = process.new_subject()
  let participant = poker.participant_id("holder")
  let session_pid =
    process.spawn_unlinked(fn() {
      let session = process.new_subject()
      let assert Ok(_) =
        poker.dispatch(subject, poker.Join(participant, "Holder"), session)
      process.send(ready, Nil)
      // room が落ちたあとも生きていることを確認したいので、検証が終わるまで
      // 待つ。親が作った subject では receive できない（所有プロセス以外の
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

/// 離脱後の再接続は別の transient identity になり、離脱した参加者の投票は
/// `apply_leave` の `dict.delete` で消えること（`room.gleam` の buzz 履歴が
/// leave をまたいで残る挙動 (ADR 0003) とは異なる — reveal は現在の
/// participants しか報告しないため、poker はここで意図的に vote も消す）。
/// `room_test.gleam` の
/// `rejoin_after_leave_is_a_new_transient_identity_with_current_snapshot_test`
/// を poker ドメインへ移植したもの。
pub fn rejoin_after_leave_is_a_new_transient_identity_with_current_snapshot_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let alice_old = poker.participant_id("connection-1")
  let alice_old_session = process.new_subject()
  let _ =
    poker.dispatch(subject, poker.Join(alice_old, "Alice"), alice_old_session)
  let assert Ok(_) =
    poker.dispatch(
      subject,
      poker.Vote(alice_old, poker.Five),
      alice_old_session,
    )

  // 切断側の Leave と再接続側の Join は、別々の WebSocket プロセスから
  // 独立に dispatch される。
  let assert Ok(_) =
    poker.dispatch(subject, poker.Leave(alice_old), alice_old_session)
  let alice_new = poker.participant_id("connection-2")
  let alice_new_session = process.new_subject()
  let event =
    poker.dispatch(subject, poker.Join(alice_new, "Alice"), alice_new_session)

  // 再接続は別の ParticipantId を得る。サーバーは切断した接続と紐付けない。
  assert event
    == Ok(poker.ParticipantJoined(poker.Participant(alice_new, "Alice")))
  assert alice_new != alice_old

  let assert Ok(state) = poker.get_state(subject)
  assert poker.snapshot(state) == [poker.Participant(alice_new, "Alice")]
  assert !poker.has_voted(state, alice_new)
  assert !poker.has_voted(state, alice_old)
}

/// `room_test.gleam` の
/// `rejoin_before_old_connections_leave_keeps_both_identities_present_test`
/// を poker ドメインへ移植したもの。
pub fn rejoin_before_old_connection_leaves_keeps_both_identities_present_test() {
  let assert Ok(started) = poker.start()
  let subject = started.data
  let alice_old = poker.participant_id("connection-1")
  let alice_old_session = process.new_subject()
  let _ =
    poker.dispatch(subject, poker.Join(alice_old, "Alice"), alice_old_session)

  // 新しい接続の Join と、古い接続の Leave の相対順序は保証されない
  // （独立したプロセス）。ここでは新しい接続の Join を先に処理する。
  let alice_new = poker.participant_id("connection-2")
  let alice_new_session = process.new_subject()
  let _ =
    poker.dispatch(subject, poker.Join(alice_new, "Alice"), alice_new_session)

  assert snapshot_of(subject)
    == Ok([
      poker.Participant(alice_old, "Alice"),
      poker.Participant(alice_new, "Alice"),
    ])

  let assert Ok(_) =
    poker.dispatch(subject, poker.Leave(alice_old), alice_old_session)

  // 古い接続の Leave が処理されたあとは、再接続した identity だけが残る。
  assert snapshot_of(subject) == Ok([poker.Participant(alice_new, "Alice")])
}
