import gleam/erlang/process
import gleam/option
import gleamroom/poker
import gleamroom/poker_registry

/// Integration-level validation of the acceptance scenario in
/// `docs/planning-poker.md`, driven through the poker Registry + Room actor
/// boundary that a WebSocket connection would use (see
/// `gleamroom/web_poker.upgrade`).
///
/// Mirrors `integration_test.gleam`'s approach for the buzzer application
/// (#282's precondition, ADR 0009): it resolves rooms through the same
/// `poker_registry.lookup` a real connection performs and drives multiple
/// concurrent "client" sessions (one `Subject` per participant) against the
/// room that lookup resolves to, without opening real WebSocket sockets.
pub fn three_clients_vote_reveal_reset_and_leave_scenario_test() {
  let assert Ok(registry_started) = poker_registry.start()
  let registry_subject = registry_started.data
  let room_id = poker_registry.room_id("PLAN")

  // 1. Three independent clients join room PLAN with different display
  // names, resolving the room the same way a WebSocket connection would.
  let assert Ok(room_subject) = poker_registry.lookup(registry_subject, room_id)
  let alice = poker.participant_id("alice")
  let alice_session = process.new_subject()
  let bob = poker.participant_id("bob")
  let bob_session = process.new_subject()
  let carol = poker.participant_id("carol")
  let carol_session = process.new_subject()

  let alice_join =
    poker.dispatch(room_subject, poker.Join(alice, "Alice"), alice_session)
  assert alice_join
    == Ok(poker.ParticipantJoined(poker.Participant(alice, "Alice")))

  let assert Ok(bob_join) =
    poker.dispatch(room_subject, poker.Join(bob, "Bob"), bob_session)
  assert bob_join == poker.ParticipantJoined(poker.Participant(bob, "Bob"))
  assert process.receive(alice_session, 100)
    == Ok(poker.ParticipantJoined(poker.Participant(bob, "Bob")))

  let carol_join =
    poker.dispatch(room_subject, poker.Join(carol, "Carol"), carol_session)
  assert carol_join
    == Ok(poker.ParticipantJoined(poker.Participant(carol, "Carol")))
  assert process.receive(alice_session, 100)
    == Ok(poker.ParticipantJoined(poker.Participant(carol, "Carol")))
  assert process.receive(bob_session, 100)
    == Ok(poker.ParticipantJoined(poker.Participant(carol, "Carol")))

  // A second lookup of the same room id (as a fresh connection joining
  // later would perform) resolves to the same room actor, and every
  // connected client observes the same presence snapshot.
  let assert Ok(looked_up_again) =
    poker_registry.lookup(registry_subject, room_id)
  let expected_presence = [
    poker.Participant(alice, "Alice"),
    poker.Participant(bob, "Bob"),
    poker.Participant(carol, "Carol"),
  ]
  let assert Ok(looked_up_state) = poker.get_state(looked_up_again)
  assert poker.snapshot(looked_up_state) == expected_presence
  let assert Ok(room_state) = poker.get_state(room_subject)
  assert poker.snapshot(room_state) == expected_presence

  // 2 & 3. Each participant votes. `VoteRegistered` never carries the cast
  // card (docs/planning-poker.md's "deliberate asymmetry"), so the other two
  // clients only learn *that* a vote was cast, never its value, before
  // reveal. Like `RoundReset`/`RoundRevealed`, `VoteRegistered` is broadcast
  // to every subscriber including the issuer (`poker.gleam`'s `broadcast`
  // doc comment on #143), so the issuer's own session also queues a copy
  // alongside the synchronous `dispatch` return value; drain it so it does
  // not shadow a later assertion on the same session.
  assert poker.dispatch(
      room_subject,
      poker.Vote(alice, poker.Five),
      alice_session,
    )
    == Ok(poker.VoteRegistered(alice))
  assert process.receive(bob_session, 100) == Ok(poker.VoteRegistered(alice))
  assert process.receive(carol_session, 100) == Ok(poker.VoteRegistered(alice))
  let _ = process.receive(alice_session, 100)

  assert poker.dispatch(room_subject, poker.Vote(bob, poker.Eight), bob_session)
    == Ok(poker.VoteRegistered(bob))
  assert process.receive(alice_session, 100) == Ok(poker.VoteRegistered(bob))
  assert process.receive(carol_session, 100) == Ok(poker.VoteRegistered(bob))
  let _ = process.receive(bob_session, 100)

  assert poker.dispatch(
      room_subject,
      poker.Vote(carol, poker.Three),
      carol_session,
    )
    == Ok(poker.VoteRegistered(carol))
  assert process.receive(alice_session, 100) == Ok(poker.VoteRegistered(carol))
  assert process.receive(bob_session, 100) == Ok(poker.VoteRegistered(carol))
  let _ = process.receive(carol_session, 100)

  let assert Ok(pre_reveal_state) = poker.get_state(room_subject)
  assert poker.has_voted(pre_reveal_state, alice) == True
  assert poker.has_voted(pre_reveal_state, bob) == True
  assert poker.has_voted(pre_reveal_state, carol) == True

  // 4. Bob changes his vote before reveal; only the latest value counts.
  assert poker.dispatch(
      room_subject,
      poker.Vote(bob, poker.Thirteen),
      bob_session,
    )
    == Ok(poker.VoteRegistered(bob))
  assert process.receive(alice_session, 100) == Ok(poker.VoteRegistered(bob))
  assert process.receive(carol_session, 100) == Ok(poker.VoteRegistered(bob))
  let _ = process.receive(bob_session, 100)

  // 5. Reveal broadcasts the same result to all three clients, including
  // the issuer (mirrors `poker.gleam`'s `broadcast` doc comment on #143).
  let expected_reveal =
    poker.RoundRevealed([
      poker.RevealedVote(alice, "Alice", option.Some(poker.Five)),
      poker.RevealedVote(bob, "Bob", option.Some(poker.Thirteen)),
      poker.RevealedVote(carol, "Carol", option.Some(poker.Three)),
    ])
  assert poker.dispatch(room_subject, poker.Reveal, alice_session)
    == Ok(expected_reveal)
  assert process.receive(alice_session, 100) == Ok(expected_reveal)
  assert process.receive(bob_session, 100) == Ok(expected_reveal)
  assert process.receive(carol_session, 100) == Ok(expected_reveal)

  // 6. Reset returns the round to Voting and clears every cast vote for all
  // clients.
  assert poker.dispatch(room_subject, poker.ResetRound, alice_session)
    == Ok(poker.RoundReset)
  assert process.receive(alice_session, 100) == Ok(poker.RoundReset)
  assert process.receive(bob_session, 100) == Ok(poker.RoundReset)
  assert process.receive(carol_session, 100) == Ok(poker.RoundReset)

  let assert Ok(post_reset_state) = poker.get_state(room_subject)
  assert post_reset_state.phase == poker.Voting
  assert poker.has_voted(post_reset_state, alice) == False
  assert poker.has_voted(post_reset_state, bob) == False
  assert poker.has_voted(post_reset_state, carol) == False

  // 7. One client (Carol) leaves; the remaining two observe the presence
  // change.
  assert poker.dispatch(room_subject, poker.Leave(carol), carol_session)
    == Ok(poker.ParticipantLeft(carol))
  assert process.receive(alice_session, 100) == Ok(poker.ParticipantLeft(carol))
  assert process.receive(bob_session, 100) == Ok(poker.ParticipantLeft(carol))

  let assert Ok(final_state) = poker.get_state(room_subject)
  assert poker.snapshot(final_state)
    == [poker.Participant(alice, "Alice"), poker.Participant(bob, "Bob")]
}
