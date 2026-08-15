import gleam/string
import gleamroom/protocol.{
  BuzzAccepted, BuzzResult, Participant, ParticipantId, ParticipantJoined,
  ParticipantLeft, ProtocolError, ProtocolErrorMessage, RoomId, RoundReset,
  State,
}

pub fn decode_join_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_buzz_test() {
  assert protocol.decode_client_message("{\"type\":\"buzz\"}")
    == Ok(protocol.Buzz)
}

pub fn decode_reset_test() {
  assert protocol.decode_client_message("{\"type\":\"reset\"}")
    == Ok(protocol.Reset)
}

pub fn decode_join_missing_display_name_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"ABCD\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_join_empty_display_name_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\"\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_missing_room_id_test() {
  let json = "{\"type\":\"join\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_join_empty_room_id_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_whitespace_only_display_name_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\"   \"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_whitespace_only_room_id_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\"   \",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_both_fields_empty_test() {
  let json = "{\"type\":\"join\",\"room_id\":\"\",\"display_name\":\"\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_trims_surrounding_whitespace_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\" ABCD \",\"display_name\":\" Alice \"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_normalizes_room_id_case_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\"abCD\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_display_name_over_max_length_test() {
  let too_long = string.repeat("a", 65)
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\""
    <> too_long
    <> "\"}"

  assert protocol.decode_client_message(json)
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

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_join_display_name_at_max_length_test() {
  let exactly_max = string.repeat("a", 64)
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\""
    <> exactly_max
    <> "\"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), exactly_max))
}

pub fn decode_join_display_name_multibyte_within_grapheme_limit_but_over_byte_limit_test() {
  // Each "あ" is 1 grapheme but 3 UTF-8 bytes, so 64 of them stay within the
  // grapheme-length limit while exceeding the byte-size limit.
  let too_long_in_bytes = string.repeat("あ", 64)
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\""
    <> too_long_in_bytes
    <> "\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters after trimming whitespace.",
    ))
}

pub fn decode_unknown_type_test() {
  let json = "{\"type\":\"shout\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_malformed_json_test() {
  assert protocol.decode_client_message("{not json")
    == Error(ProtocolError(
      code: "malformed_json",
      message: "Message body was not valid JSON.",
    ))
}

pub fn encode_state_test() {
  let message =
    State(participants: [Participant(ParticipantId("p1"), "Alice")], buzzes: [
      BuzzResult(ParticipantId("p1"), "Alice", 1),
    ])

  assert protocol.encode_server_message(message)
    == "{\"type\":\"state\",\"participants\":[{\"id\":\"p1\",\"display_name\":\"Alice\"}],\"buzzes\":[{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"position\":1}]}"
}

pub fn encode_participant_joined_test() {
  let message = ParticipantJoined(Participant(ParticipantId("p1"), "Alice"))

  assert protocol.encode_server_message(message)
    == "{\"type\":\"participant_joined\",\"participant\":{\"id\":\"p1\",\"display_name\":\"Alice\"}}"
}

pub fn encode_participant_left_test() {
  let message = ParticipantLeft(ParticipantId("p1"))

  assert protocol.encode_server_message(message)
    == "{\"type\":\"participant_left\",\"participant_id\":\"p1\"}"
}

pub fn encode_buzz_accepted_test() {
  let message = BuzzAccepted(ParticipantId("p1"), 1)

  assert protocol.encode_server_message(message)
    == "{\"type\":\"buzz_accepted\",\"participant_id\":\"p1\",\"position\":1}"
}

pub fn encode_round_reset_test() {
  assert protocol.encode_server_message(RoundReset)
    == "{\"type\":\"round_reset\"}"
}

pub fn encode_error_test() {
  let message = ProtocolErrorMessage("invalid_message", "bad input")

  assert protocol.encode_server_message(message)
    == "{\"type\":\"error\",\"code\":\"invalid_message\",\"message\":\"bad input\"}"
}
