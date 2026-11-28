import gleam/erlang/process
import gleamroom/registry
import gleamroom/room

/// Integration-level validation of the acceptance scenario in
/// `docs/mvp.md` (with the host of #768), driven through the Registry + Room actor boundary that a
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
pub fn host_and_three_clients_scenario_test() {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data

  // 1. The host creates the room (#767) and three independent clients join
  // it with different display names, resolving the room the same way a
  // WebSocket connection would.
  let assert Ok(#(room_id, room_subject)) = registry.create(registry_subject)
  let host = room.participant_id("host")
  let host_session = process.new_subject()
  let alice = room.participant_id("alice")
  let alice_session = process.new_subject()
  let bob = room.participant_id("bob")
  let bob_session = process.new_subject()
  let carol = room.participant_id("carol")
  let carol_session = process.new_subject()

  let assert Ok(room.JoinReply(
    event: room.ParticipantJoined(room.Participant(role: room.Host, ..), 1),
    ..,
  )) = room.join_as_creator(room_subject, host, "Host", host_session)

  let alice_join =
    room.dispatch(room_subject, room.Join(alice, "Alice"), alice_session)
  assert alice_join == Ok(room.ParticipantJoined(player(alice, "Alice"), 2))

  let assert Ok(bob_join) =
    room.dispatch(room_subject, room.Join(bob, "Bob"), bob_session)
  assert bob_join == room.ParticipantJoined(player(bob, "Bob"), 3)
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantJoined(player(bob, "Bob"), 3))

  let carol_join =
    room.dispatch(room_subject, room.Join(carol, "Carol"), carol_session)
  assert carol_join == Ok(room.ParticipantJoined(player(carol, "Carol"), 4))
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantJoined(player(carol, "Carol"), 4))
  assert process.receive(bob_session, 100)
    == Ok(room.ParticipantJoined(player(carol, "Carol"), 4))
  drain(host_session)

  // A second find of the same room code (as a fresh connection joining
  // later would perform) resolves to the same room actor, and every
  // connected client observes the same presence snapshot.
  let assert Ok(looked_up_again) = registry.find(registry_subject, room_id)
  let expected_presence = [
    room.Participant(host, "Host", True, room.Host),
    player(alice, "Alice"),
    player(bob, "Bob"),
    player(carol, "Carol"),
  ]
  assert room.get_snapshot(looked_up_again) == Ok(expected_presence)
  assert room.get_snapshot(room_subject) == Ok(expected_presence)

  // 2. Nobody can buzz before the host opens acceptance (#768).
  assert room.dispatch(room_subject, room.Buzz(bob, 1), bob_session)
    == Ok(room.BuzzRejected(bob, room.NotAccepting))

  // 3. The host opens. Every accepted change carries the next revision.
  assert room.dispatch(room_subject, room.OpenAcceptance(host, 1), host_session)
    == Ok(room.PhaseChanged(room.Open, 1, 5))
  assert process.receive(alice_session, 100)
    == Ok(room.PhaseChanged(room.Open, 1, 5))
  drain(host_session)
  drain(bob_session)
  drain(carol_session)

  // 4 & 5. Clients buzz in the accepted order B, A, C; all clients observe
  // the identical ordering. The first buzz locks the question.
  assert room.dispatch(room_subject, room.Buzz(bob, 1), bob_session)
    == Ok(room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 6))
  assert process.receive(alice_session, 100)
    == Ok(room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 6))
  assert process.receive(carol_session, 100)
    == Ok(room.BuzzAccepted(bob, "Bob", 1, 1, room.Locked, 6))
  let _ = process.receive(bob_session, 100)

  assert room.dispatch(room_subject, room.Buzz(alice, 1), alice_session)
    == Ok(room.BuzzAccepted(alice, "Alice", 2, 1, room.Locked, 7))
  assert process.receive(bob_session, 100)
    == Ok(room.BuzzAccepted(alice, "Alice", 2, 1, room.Locked, 7))
  let _ = process.receive(carol_session, 100)
  let _ = process.receive(alice_session, 100)

  assert room.dispatch(room_subject, room.Buzz(carol, 1), carol_session)
    == Ok(room.BuzzAccepted(carol, "Carol", 3, 1, room.Locked, 8))
  let _ = process.receive(alice_session, 100)
  let _ = process.receive(bob_session, 100)
  let _ = process.receive(carol_session, 100)

  let expected_order = [
    room.BuzzResult(bob, "Bob", 1),
    room.BuzzResult(alice, "Alice", 2),
    room.BuzzResult(carol, "Carol", 3),
  ]
  let assert Ok(room.Snapshot(buzzes:, phase: room.Locked, ..)) =
    room.get_state(room_subject)
  assert buzzes == expected_order

  // 6. A second buzz from B does not alter or duplicate the ordering, and a
  // player cannot run the host's commands.
  assert room.dispatch(room_subject, room.Buzz(bob, 1), bob_session)
    == Ok(room.BuzzRejected(bob, room.AlreadyBuzzed))
  assert room.dispatch(room_subject, room.NextQuestion(bob, 1), bob_session)
    == Ok(room.CommandRejected(room.Forbidden))
  assert process.receive(alice_session, 100) == Error(Nil)
  assert process.receive(carol_session, 100) == Error(Nil)
  let assert Ok(room.Snapshot(buzzes:, ..)) = room.get_state(room_subject)
  assert buzzes == expected_order

  // 7. The next question clears the results for all clients.
  drain(host_session)
  assert room.dispatch(room_subject, room.NextQuestion(host, 1), host_session)
    == Ok(room.RoundReset(2, 9))
  assert process.receive(bob_session, 100) == Ok(room.RoundReset(2, 9))
  assert process.receive(carol_session, 100) == Ok(room.RoundReset(2, 9))
  let assert Ok(room.Snapshot(buzzes: [], phase: room.Waiting, ..)) =
    room.get_state(room_subject)
  let _ = process.receive(alice_session, 100)

  // 8. One client (Carol) leaves and remaining clients observe the leave.
  assert room.dispatch(room_subject, room.Leave(carol), carol_session)
    == Ok(room.ParticipantLeft(carol, 10))
  assert process.receive(alice_session, 100)
    == Ok(room.ParticipantLeft(carol, 10))
  assert process.receive(bob_session, 100)
    == Ok(room.ParticipantLeft(carol, 10))

  // 9. Joining again after an explicit leave is a new participant.
  let carol_rejoined = room.participant_id("carol-rejoined")
  let carol_rejoin_session = process.new_subject()
  assert room.dispatch(
      room_subject,
      room.Join(carol_rejoined, "Carol"),
      carol_rejoin_session,
    )
    == Ok(room.ParticipantJoined(player(carol_rejoined, "Carol"), 11))
  assert room.get_snapshot(room_subject)
    == Ok([
      room.Participant(host, "Host", True, room.Host),
      player(alice, "Alice"),
      player(bob, "Bob"),
      player(carol_rejoined, "Carol"),
    ])
}

fn player(id: room.ParticipantId, name: String) -> room.Participant {
  room.Participant(id, name, True, room.Player)
}

fn drain(session: process.Subject(room.RoomEvent)) -> Nil {
  case process.receive(session, 50) {
    Ok(_) -> drain(session)
    Error(Nil) -> Nil
  }
}
