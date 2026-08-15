import gleam/erlang/process
import gleamroom/registry
import gleamroom/room

/// Integration-level validation of the acceptance scenario in
/// `docs/mvp.md`, driven through the Registry + Room actor boundary that a
/// WebSocket connection would use (see `gleamroom/websocket.upgrade`).
///
/// Unlike `room_test.gleam`, which exercises `room.apply_command` as a pure
/// state transition and single actors in isolation, this module resolves
/// rooms through the same `registry.lookup` a real connection performs and
/// drives multiple concurrent "client" sessions (one `Subject` per
/// participant, mirroring one WebSocket connection each) against the room
/// that lookup resolves to. It intentionally stops short of opening real
/// WebSocket sockets: the wire-format translation in `websocket.gleam` is
/// a thin, already-covered layer, and adding a WebSocket client dependency
/// solely to re-exercise it here would be the "heavy E2E framework" the
/// issue explicitly avoids.
pub fn three_clients_buzz_reset_and_reconnect_scenario_test() {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data
  let room_id = registry.room_id("ABCD")

  // 1. Three independent clients join room ABCD with different display
  // names, resolving the room the same way a WebSocket connection would.
  let assert Ok(room_subject) = registry.lookup(registry_subject, room_id)
  let alice = room.participant_id("alice")
  let alice_session = process.new_subject()
  let bob = room.participant_id("bob")
  let bob_session = process.new_subject()
  let carol = room.participant_id("carol")
  let carol_session = process.new_subject()

  let alice_join =
    room.dispatch(room_subject, room.Join(alice, "Alice"), alice_session)
  assert alice_join
    == Ok(room.ParticipantJoined(room.Participant(alice, "Alice")))

  let assert Ok(bob_join) =
    room.dispatch(room_subject, room.Join(bob, "Bob"), bob_session)
  assert bob_join == room.ParticipantJoined(room.Participant(bob, "Bob"))
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantJoined(room.Participant(bob, "Bob")))

  let carol_join =
    room.dispatch(room_subject, room.Join(carol, "Carol"), carol_session)
  assert carol_join
    == Ok(room.ParticipantJoined(room.Participant(carol, "Carol")))
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantJoined(room.Participant(carol, "Carol")))
  assert process.receive(bob_session, 100)
    == Ok(room.ParticipantJoined(room.Participant(carol, "Carol")))

  // A second lookup of the same room id (as a fresh connection joining
  // later would perform) resolves to the same room actor, and every
  // connected client observes the same presence snapshot.
  let assert Ok(looked_up_again) = registry.lookup(registry_subject, room_id)
  let expected_presence = [
    room.Participant(alice, "Alice"),
    room.Participant(bob, "Bob"),
    room.Participant(carol, "Carol"),
  ]
  assert room.get_snapshot(looked_up_again) == Ok(expected_presence)
  assert room.get_snapshot(room_subject) == Ok(expected_presence)

  // 3. Reset the round before buzzing (idempotent on an already-empty
  // round).
  assert room.dispatch(room_subject, room.ResetRound, alice_session)
    == Ok(room.RoundReset)
  assert process.receive(bob_session, 100) == Ok(room.RoundReset)
  assert process.receive(carol_session, 100) == Ok(room.RoundReset)

  // 4 & 5. Clients buzz in the accepted order B, A, C; all clients observe
  // the identical ordering.
  assert room.dispatch(room_subject, room.Buzz(bob), bob_session)
    == Ok(room.BuzzAccepted(bob, 1))
  assert process.receive(alice_session, 100) == Ok(room.BuzzAccepted(bob, 1))
  assert process.receive(carol_session, 100) == Ok(room.BuzzAccepted(bob, 1))

  assert room.dispatch(room_subject, room.Buzz(alice), alice_session)
    == Ok(room.BuzzAccepted(alice, 2))
  assert process.receive(bob_session, 100) == Ok(room.BuzzAccepted(alice, 2))
  assert process.receive(carol_session, 100) == Ok(room.BuzzAccepted(alice, 2))

  assert room.dispatch(room_subject, room.Buzz(carol), carol_session)
    == Ok(room.BuzzAccepted(carol, 3))
  assert process.receive(alice_session, 100) == Ok(room.BuzzAccepted(carol, 3))
  assert process.receive(bob_session, 100) == Ok(room.BuzzAccepted(carol, 3))

  let expected_order = [
    room.BuzzResult(bob, "Bob", 1),
    room.BuzzResult(alice, "Alice", 2),
    room.BuzzResult(carol, "Carol", 3),
  ]
  assert room.get_buzz_snapshot(room_subject) == Ok(expected_order)

  // 6. A second buzz from B does not alter or duplicate the ordering.
  assert room.dispatch(room_subject, room.Buzz(bob), bob_session)
    == Ok(room.BuzzRejected(bob, room.AlreadyBuzzed))
  assert process.receive(alice_session, 100) == Error(Nil)
  assert process.receive(carol_session, 100) == Error(Nil)
  assert room.get_buzz_snapshot(room_subject) == Ok(expected_order)

  // 7. Reset clears the results for all clients.
  assert room.dispatch(room_subject, room.ResetRound, alice_session)
    == Ok(room.RoundReset)
  assert process.receive(bob_session, 100) == Ok(room.RoundReset)
  assert process.receive(carol_session, 100) == Ok(room.RoundReset)
  assert room.get_buzz_snapshot(room_subject) == Ok([])

  // 8. One client (Carol) disconnects and remaining clients observe the
  // leave.
  assert room.dispatch(room_subject, room.Leave(carol), carol_session)
    == Ok(room.ParticipantLeft(carol))
  assert process.receive(alice_session, 100) == Ok(room.ParticipantLeft(carol))
  assert process.receive(bob_session, 100) == Ok(room.ParticipantLeft(carol))

  // 9. A client reconnects/rejoins and receives the current room snapshot.
  // Per ADR 0003 / docs/mvp.md, a reconnect is a brand new connection with
  // a new ParticipantId; it is not correlated with the old one.
  let carol_rejoined = room.participant_id("carol-reconnected")
  let carol_rejoin_session = process.new_subject()
  let rejoin_event =
    room.dispatch(
      room_subject,
      room.Join(carol_rejoined, "Carol"),
      carol_rejoin_session,
    )
  assert rejoin_event
    == Ok(room.ParticipantJoined(room.Participant(carol_rejoined, "Carol")))
  assert room.get_snapshot(room_subject)
    == Ok([
      room.Participant(alice, "Alice"),
      room.Participant(bob, "Bob"),
      room.Participant(carol_rejoined, "Carol"),
    ])
}
