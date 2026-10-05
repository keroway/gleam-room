import gleam/erlang/process
import gleam/option.{None, Some}
import gleamroom/poker
import gleamroom/poker_protocol
import gleamroom/poker_registry
import gleamroom/poker_websocket
import gleamroom/wire

pub fn release_room_sends_release_when_registry_is_reachable_test() {
  let registry_subject = process.new_subject()
  let room_subject = process.new_subject()
  let room_id = poker_registry.room_id("room-1")

  poker_websocket.release_room(registry_subject, room_id, room_subject)

  let assert Ok(received) = process.receive(registry_subject, 100)
  assert received == poker_registry.Release(room_id, room_subject)
}

/// registry の named subject が(再起動中などで)未登録でも panic しないこと（#116）。
pub fn release_room_does_not_panic_when_registry_is_unregistered_test() {
  let name = process.new_name("gleamroom_poker_release_room_test")
  let registry_subject = process.named_subject(name)
  let room_subject = process.new_subject()
  let room_id = poker_registry.room_id("room-2")

  poker_websocket.release_room(registry_subject, room_id, room_subject)
}

/// ワイヤーコード文字列が docs/planning-poker.md のエラーコード表と一致することを
/// 保証する回帰テスト（#303）。
pub fn vote_reject_code_and_message_voter_not_joined_test() {
  assert poker_websocket.vote_reject_code_and_message(poker.VoterNotJoined)
    == #("voter_not_joined", "This connection has not joined the room yet.")
}

pub fn vote_reject_code_and_message_round_already_revealed_test() {
  assert poker_websocket.vote_reject_code_and_message(
      poker.RoundAlreadyRevealed,
    )
    == #("round_already_revealed", "Voting is closed until the round is reset.")
}

pub fn join_reject_code_and_message_room_full_test() {
  assert poker_websocket.join_reject_code_and_message(poker.RoomFull)
    == #(
      "room_full",
      "This room has reached its maximum number of participants.",
    )
}

pub fn join_reject_code_and_message_invalid_display_name_test() {
  assert poker_websocket.join_reject_code_and_message(poker.InvalidDisplayName)
    == #("invalid_display_name", "The provided display name is not valid.")
}

pub fn join_reject_code_and_message_already_joined_test() {
  assert poker_websocket.join_reject_code_and_message(poker.AlreadyJoined)
    == #("already_joined", "This connection has already joined a room.")
}

pub fn room_unavailable_message_lookup_failed_test() {
  assert poker_websocket.room_unavailable_message(
      poker_websocket.RoomLookupFailed,
    )
    == "The room could not be started. Please try again."
}

pub fn room_unavailable_message_capacity_reached_test() {
  assert poker_websocket.room_unavailable_message(
      poker_websocket.RoomCapacityReached,
    )
    == "The server is at room capacity. Try an existing room or wait until another room ends."
}

pub fn room_unavailable_message_join_timed_out_test() {
  assert poker_websocket.room_unavailable_message(poker_websocket.JoinTimedOut)
    == "The room did not respond in time. Reconnect to try again."
}

pub fn room_unavailable_message_reply_timed_out_test() {
  assert poker_websocket.room_unavailable_message(poker_websocket.ReplyTimedOut)
    == "The room did not respond in time. Please try again."
}

pub fn not_joined_message_test() {
  assert poker_websocket.not_joined_message
    == "Join a room before sending this command."
}

pub fn to_wire_participant_id_test() {
  assert poker_websocket.to_wire_participant_id(poker.participant_id("p1"))
    == wire.participant_id("p1")
}

pub fn to_wire_participant_view_not_voted_test() {
  let participant = poker.Participant(poker.participant_id("p1"), "Alice")

  assert poker_websocket.to_wire_participant_view(participant, False)
    == poker_protocol.ParticipantView(wire.participant_id("p1"), "Alice", False)
}

pub fn to_wire_participant_view_voted_test() {
  let participant = poker.Participant(poker.participant_id("p1"), "Alice")

  assert poker_websocket.to_wire_participant_view(participant, True)
    == poker_protocol.ParticipantView(wire.participant_id("p1"), "Alice", True)
}

pub fn to_wire_round_phase_voting_test() {
  assert poker_websocket.to_wire_round_phase(poker.Voting)
    == poker_protocol.Voting
}

pub fn to_wire_round_phase_revealed_test() {
  assert poker_websocket.to_wire_round_phase(poker.Revealed)
    == poker_protocol.Revealed
}

pub fn to_wire_card_test() {
  assert poker_websocket.to_wire_card(poker.Zero) == poker_protocol.Zero
  assert poker_websocket.to_wire_card(poker.One) == poker_protocol.One
  assert poker_websocket.to_wire_card(poker.Two) == poker_protocol.Two
  assert poker_websocket.to_wire_card(poker.Three) == poker_protocol.Three
  assert poker_websocket.to_wire_card(poker.Five) == poker_protocol.Five
  assert poker_websocket.to_wire_card(poker.Eight) == poker_protocol.Eight
  assert poker_websocket.to_wire_card(poker.Thirteen) == poker_protocol.Thirteen
  assert poker_websocket.to_wire_card(poker.TwentyOne)
    == poker_protocol.TwentyOne
  assert poker_websocket.to_wire_card(poker.QuestionMark)
    == poker_protocol.QuestionMark
  assert poker_websocket.to_wire_card(poker.Coffee) == poker_protocol.Coffee
}

pub fn to_domain_card_test() {
  assert poker_websocket.to_domain_card(poker_protocol.Zero) == poker.Zero
  assert poker_websocket.to_domain_card(poker_protocol.One) == poker.One
  assert poker_websocket.to_domain_card(poker_protocol.Two) == poker.Two
  assert poker_websocket.to_domain_card(poker_protocol.Three) == poker.Three
  assert poker_websocket.to_domain_card(poker_protocol.Five) == poker.Five
  assert poker_websocket.to_domain_card(poker_protocol.Eight) == poker.Eight
  assert poker_websocket.to_domain_card(poker_protocol.Thirteen)
    == poker.Thirteen
  assert poker_websocket.to_domain_card(poker_protocol.TwentyOne)
    == poker.TwentyOne
  assert poker_websocket.to_domain_card(poker_protocol.QuestionMark)
    == poker.QuestionMark
  assert poker_websocket.to_domain_card(poker_protocol.Coffee) == poker.Coffee
}

pub fn to_wire_revealed_vote_with_value_test() {
  let vote =
    poker.RevealedVote(poker.participant_id("p1"), "Alice", Some(poker.Five))

  assert poker_websocket.to_wire_revealed_vote(vote)
    == poker_protocol.RevealedVote(
      wire.participant_id("p1"),
      "Alice",
      Some(poker_protocol.Five),
    )
}

pub fn to_wire_revealed_vote_without_value_test() {
  let vote = poker.RevealedVote(poker.participant_id("p1"), "Alice", None)

  assert poker_websocket.to_wire_revealed_vote(vote)
    == poker_protocol.RevealedVote(wire.participant_id("p1"), "Alice", None)
}

pub fn room_event_to_server_message_participant_joined_test() {
  let participant = poker.Participant(poker.participant_id("p1"), "Alice")

  assert poker_websocket.room_event_to_server_message(poker.ParticipantJoined(
      participant,
    ))
    == Some(
      poker_protocol.ParticipantJoined(poker_protocol.ParticipantView(
        wire.participant_id("p1"),
        "Alice",
        False,
      )),
    )
}

pub fn room_event_to_server_message_participant_left_test() {
  assert poker_websocket.room_event_to_server_message(
      poker.ParticipantLeft(poker.participant_id("p1")),
    )
    == Some(poker_protocol.ParticipantLeft(wire.participant_id("p1")))
}

pub fn room_event_to_server_message_vote_registered_test() {
  assert poker_websocket.room_event_to_server_message(
      poker.VoteRegistered(poker.participant_id("p1")),
    )
    == Some(poker_protocol.VoteRegistered(wire.participant_id("p1")))
}

pub fn room_event_to_server_message_round_revealed_test() {
  let votes = [poker.RevealedVote(poker.participant_id("p1"), "Alice", None)]

  assert poker_websocket.room_event_to_server_message(poker.RoundRevealed(votes))
    == Some(
      poker_protocol.RoundRevealed([
        poker_protocol.RevealedVote(wire.participant_id("p1"), "Alice", None),
      ]),
    )
}

pub fn room_event_to_server_message_round_reset_test() {
  assert poker_websocket.room_event_to_server_message(poker.RoundReset)
    == Some(poker_protocol.RoundReset)
}

pub fn room_event_to_server_message_join_rejected_is_not_broadcast_test() {
  assert poker_websocket.room_event_to_server_message(poker.JoinRejected(
      poker.participant_id("p1"),
      poker.AlreadyJoined,
    ))
    == None
}

pub fn room_event_to_server_message_leave_rejected_is_not_broadcast_test() {
  assert poker_websocket.room_event_to_server_message(poker.LeaveRejected(
      poker.participant_id("p1"),
      poker.NotJoined,
    ))
    == None
}

pub fn room_event_to_server_message_vote_rejected_is_not_broadcast_test() {
  assert poker_websocket.room_event_to_server_message(poker.VoteRejected(
      poker.participant_id("p1"),
      poker.VoterNotJoined,
    ))
    == None
}

/// `get_state` タイムアウト後のフォールバック状態は空の participants/votes
/// と `phase: Voting` を返す(#357)。この phase 固定は「不明な phase を
/// 安全に表せない」という既知の制約であって偶然の実装詳細ではないので、
/// リグレッションとして固定しておく。
pub fn fallback_state_after_get_state_timeout_has_empty_voting_state_test() {
  let state = poker_websocket.fallback_state_after_get_state_timeout()

  assert poker.snapshot(state) == []
  assert poker_websocket.to_wire_round_phase(state.phase)
    == poker_protocol.Voting
}
