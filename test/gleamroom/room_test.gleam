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

  let event = room.dispatch(subject, room.Join(id, "Alice"), session)

  assert event == room.ParticipantJoined(room.Participant(id, "Alice"))
  assert room.get_snapshot(subject) == [room.Participant(id, "Alice")]
}

pub fn independent_room_actors_do_not_share_state_test() {
  let assert Ok(room_a) = room.start()
  let assert Ok(room_b) = room.start()
  let id = room.participant_id("p1")
  let session = process.new_subject()

  let _ = room.dispatch(room_a.data, room.Join(id, "Alice"), session)

  assert room.get_snapshot(room_a.data) == [room.Participant(id, "Alice")]
  assert room.get_snapshot(room_b.data) == []
}

pub fn join_broadcasts_to_other_subscribers_but_not_the_joiner_test() {
  let assert Ok(started) = room.start()
  let subject = started.data
  let alice = room.participant_id("p1")
  let alice_session = process.new_subject()
  let bob = room.participant_id("p2")
  let bob_session = process.new_subject()

  let _ = room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let _ = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)

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
  let _ = room.dispatch(subject, room.Join(alice, "Alice"), alice_session)
  let _ = room.dispatch(subject, room.Join(bob, "Bob"), bob_session)
  let _ = process.receive(alice_session, 100)

  let _ = room.dispatch(subject, room.Leave(bob), bob_session)

  assert process.receive(alice_session, 100) == Ok(room.ParticipantLeft(bob))
  assert process.receive(bob_session, 100) == Error(Nil)
}
