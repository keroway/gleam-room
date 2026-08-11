import gleam/erlang/process
import gleamroom/room

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
    == [room.Participant(bob, "Bob"), room.Participant(alice, "Alice")]
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

  assert bob_event == room.BuzzAccepted(bob, 1)
  assert alice_event == room.BuzzAccepted(alice, 2)
  assert carol_event == room.BuzzAccepted(carol, 3)
  assert room.buzz_snapshot(state)
    == [
      room.BuzzResult(bob, 1),
      room.BuzzResult(alice, 2),
      room.BuzzResult(carol, 3),
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
  assert rebuzz_event == room.BuzzAccepted(id, 1)
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

  assert event == room.BuzzAccepted(bob, 1)
  assert process.receive(alice_session, 100) == Ok(room.BuzzAccepted(bob, 1))
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
  assert room.get_buzz_snapshot(subject) == Ok([room.BuzzResult(alice_old, 1)])
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
      room.Participant(alice_new, "Alice"),
      room.Participant(alice_old, "Alice"),
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

  assert room.get_buzz_snapshot(room_a.data) == Ok([room.BuzzResult(id, 1)])
  assert room.get_buzz_snapshot(room_b.data) == Ok([])
}
