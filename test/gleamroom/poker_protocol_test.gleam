import gleam/option.{None, Some}
import gleam/string
import gleamroom/poker_protocol.{
  Coffee, Eight, Five, Join, ParticipantId, ParticipantJoined, ParticipantLeft,
  ParticipantView, ProtocolError, ProtocolErrorMessage, Reset, Reveal,
  RevealedVote, RoomId, RoundReset, RoundRevealed, State, Vote, VoteRegistered,
  Voting,
}

pub fn decode_join_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\"Alice\"}"

  assert poker_protocol.decode_client_message(json)
    == Ok(Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_trims_and_normalizes_room_id_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\" abCD \",\"display_name\":\" Alice \"}"

  assert poker_protocol.decode_client_message(json)
    == Ok(Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_empty_room_id_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"\",\"display_name\":\"Alice\"}"

  assert poker_protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_empty_display_name_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\"\"}"

  assert poker_protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_room_id_over_max_length_test() {
  let too_long = string.repeat("a", 65)
  let json =
    "{\"type\":\"join\",\"room_id\":\""
    <> too_long
    <> "\",\"display_name\":\"Alice\"}"

  assert poker_protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_display_name_multibyte_within_grapheme_limit_but_over_byte_limit_test() {
  // Each "あ" is 1 grapheme but 3 UTF-8 bytes, so 64 of them stay within the
  // grapheme-length limit while exceeding the byte-size limit (mirrors the
  // buzzer's #265 regression test in protocol_test.gleam).
  let too_long_in_bytes = string.repeat("あ", 64)
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\""
    <> too_long_in_bytes
    <> "\"}"

  assert poker_protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_vote_test() {
  assert poker_protocol.decode_client_message(
      "{\"type\":\"vote\",\"value\":\"5\"}",
    )
    == Ok(Vote(Five))
}

pub fn decode_vote_question_mark_test() {
  assert poker_protocol.decode_client_message(
      "{\"type\":\"vote\",\"value\":\"?\"}",
    )
    == Ok(Vote(poker_protocol.QuestionMark))
}

pub fn decode_vote_coffee_test() {
  assert poker_protocol.decode_client_message(
      "{\"type\":\"vote\",\"value\":\"coffee\"}",
    )
    == Ok(Vote(Coffee))
}

pub fn decode_vote_invalid_card_test() {
  assert poker_protocol.decode_client_message(
      "{\"type\":\"vote\",\"value\":\"100\"}",
    )
    == Error(ProtocolError(
      code: "invalid_card",
      message: "value must be one of the fixed card set.",
    ))
}

pub fn decode_reveal_test() {
  assert poker_protocol.decode_client_message("{\"type\":\"reveal\"}")
    == Ok(Reveal)
}

pub fn decode_reset_test() {
  assert poker_protocol.decode_client_message("{\"type\":\"reset\"}")
    == Ok(Reset)
}

pub fn decode_unknown_type_test() {
  assert poker_protocol.decode_client_message("{\"type\":\"shout\"}")
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_missing_vote_value_test() {
  assert poker_protocol.decode_client_message("{\"type\":\"vote\"}")
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_malformed_json_test() {
  assert poker_protocol.decode_client_message("{not json")
    == Error(ProtocolError(
      code: "malformed_json",
      message: "Message body was not valid JSON.",
    ))
}

pub fn card_round_trip_test() {
  let cards = [
    poker_protocol.Zero,
    poker_protocol.One,
    poker_protocol.Two,
    poker_protocol.Three,
    Five,
    Eight,
    poker_protocol.Thirteen,
    poker_protocol.TwentyOne,
    poker_protocol.QuestionMark,
    Coffee,
  ]

  cards
  |> list_all(fn(card) {
    assert poker_protocol.card_from_wire_string(
        poker_protocol.card_to_wire_string(card),
      )
      == Ok(card)
  })
}

fn list_all(items: List(a), check: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      check(first)
      list_all(rest, check)
    }
  }
}

pub fn encode_state_test() {
  let message =
    State(phase: Voting, participants: [
      ParticipantView(ParticipantId("p1"), "Alice", True),
    ])

  assert poker_protocol.encode_server_message(message)
    == "{\"type\":\"state\",\"phase\":\"voting\",\"participants\":[{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"has_voted\":true}]}"
}

pub fn encode_participant_joined_test() {
  let message =
    ParticipantJoined(ParticipantView(ParticipantId("p1"), "Alice", False))

  assert poker_protocol.encode_server_message(message)
    == "{\"type\":\"participant_joined\",\"participant\":{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"has_voted\":false}}"
}

pub fn encode_participant_left_test() {
  assert poker_protocol.encode_server_message(
      ParticipantLeft(ParticipantId("p1")),
    )
    == "{\"type\":\"participant_left\",\"participant_id\":\"p1\"}"
}

pub fn encode_vote_registered_test() {
  assert poker_protocol.encode_server_message(
      VoteRegistered(ParticipantId("p1")),
    )
    == "{\"type\":\"vote_registered\",\"participant_id\":\"p1\"}"
}

pub fn encode_revealed_with_vote_test() {
  let message =
    RoundRevealed([RevealedVote(ParticipantId("p1"), "Alice", Some(Five))])

  assert poker_protocol.encode_server_message(message)
    == "{\"type\":\"revealed\",\"votes\":[{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"value\":\"5\"}]}"
}

pub fn encode_revealed_without_vote_test() {
  let message =
    RoundRevealed([RevealedVote(ParticipantId("p1"), "Alice", None)])

  assert poker_protocol.encode_server_message(message)
    == "{\"type\":\"revealed\",\"votes\":[{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"value\":null}]}"
}

pub fn encode_round_reset_test() {
  assert poker_protocol.encode_server_message(RoundReset)
    == "{\"type\":\"round_reset\"}"
}

pub fn encode_error_test() {
  let message = ProtocolErrorMessage("invalid_card", "bad card")

  assert poker_protocol.encode_server_message(message)
    == "{\"type\":\"error\",\"code\":\"invalid_card\",\"message\":\"bad card\"}"
}

pub fn encode_error_already_joined_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "already_joined",
      "This connection has already joined a room.",
    ))
    == "{\"type\":\"error\",\"code\":\"already_joined\",\"message\":\"This connection has already joined a room.\"}"
}

pub fn encode_error_room_full_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "room_full",
      "This room has reached its maximum number of participants.",
    ))
    == "{\"type\":\"error\",\"code\":\"room_full\",\"message\":\"This room has reached its maximum number of participants.\"}"
}

pub fn encode_error_not_joined_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "not_joined",
      "Join a room before sending this command.",
    ))
    == "{\"type\":\"error\",\"code\":\"not_joined\",\"message\":\"Join a room before sending this command.\"}"
}

pub fn encode_error_room_unavailable_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "room_unavailable",
      "The room is temporarily unavailable.",
    ))
    == "{\"type\":\"error\",\"code\":\"room_unavailable\",\"message\":\"The room is temporarily unavailable.\"}"
}

pub fn encode_error_binary_frame_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "binary_frame",
      "Binary frames are not supported.",
    ))
    == "{\"type\":\"error\",\"code\":\"binary_frame\",\"message\":\"Binary frames are not supported.\"}"
}

pub fn encode_error_rate_limited_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "rate_limited",
      "Too many messages. Please slow down.",
    ))
    == "{\"type\":\"error\",\"code\":\"rate_limited\",\"message\":\"Too many messages. Please slow down.\"}"
}

pub fn encode_error_frame_too_large_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "frame_too_large",
      "Message exceeds the maximum allowed size.",
    ))
    == "{\"type\":\"error\",\"code\":\"frame_too_large\",\"message\":\"Message exceeds the maximum allowed size.\"}"
}

pub fn encode_error_not_voting_phase_test() {
  assert poker_protocol.encode_server_message(ProtocolErrorMessage(
      "not_voting_phase",
      "This action is not allowed outside the voting phase.",
    ))
    == "{\"type\":\"error\",\"code\":\"not_voting_phase\",\"message\":\"This action is not allowed outside the voting phase.\"}"
}
