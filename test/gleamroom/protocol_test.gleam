import gleam/option.{None, Some}
import gleam/string
import gleamroom/protocol.{
  BuzzAccepted, BuzzResult, Participant, ParticipantJoined, ParticipantLeft,
  ProtocolErrorMessage, Reply, RoundReset, State,
}
import gleamroom/wire.{ParticipantId, ProtocolError, RoomId}

pub fn decode_join_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_without_version_is_client_outdated_test() {
  let json =
    "{\"type\":\"join\",\"room_id\":\"ABCD\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(protocol.client_outdated_error)
}

pub fn decode_join_with_other_version_is_client_outdated_test() {
  let json =
    "{\"type\":\"join\",\"v\":1,\"room_id\":\"ABCD\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(protocol.client_outdated_error)
}

pub fn decode_buzz_test() {
  assert protocol.decode_client_message("{\"type\":\"buzz\",\"round_id\":3}")
    == Ok(protocol.Buzz(3, None))
}

pub fn decode_buzz_with_request_id_test() {
  assert protocol.decode_client_message(
      "{\"type\":\"buzz\",\"round_id\":3,\"request_id\":\"r1\"}",
    )
    == Ok(protocol.Buzz(3, Some("r1")))
}

pub fn decode_buzz_without_round_id_is_invalid_test() {
  let assert Error(ProtocolError(code: "invalid_message", ..)) =
    protocol.decode_client_message("{\"type\":\"buzz\"}")
}

pub fn decode_buzz_with_empty_request_id_is_invalid_test() {
  let assert Error(ProtocolError(code: "invalid_message", ..)) =
    protocol.decode_client_message(
      "{\"type\":\"buzz\",\"round_id\":1,\"request_id\":\"\"}",
    )
}

pub fn decode_sync_test() {
  assert protocol.decode_client_message("{\"type\":\"sync\"}")
    == Ok(protocol.Sync)
}

pub fn request_id_is_read_from_an_otherwise_invalid_frame_test() {
  assert protocol.request_id("{\"type\":\"buzz\",\"request_id\":\"r9\"}")
    == Some("r9")
  assert protocol.request_id("{\"type\":\"buzz\"}") == None
  assert protocol.request_id("{not json") == None
}

pub fn correlate_wraps_only_when_a_request_id_exists_test() {
  let message = ProtocolErrorMessage("stale_round", "old")
  assert protocol.correlate(message, None) == message
  assert protocol.correlate(message, Some("r1")) == Reply("r1", message)
}

pub fn decode_ping_test() {
  assert protocol.decode_client_message("{\"type\":\"ping\"}")
    == Ok(protocol.Ping)
}

pub fn encode_pong_test() {
  assert protocol.encode_server_message(protocol.Pong) == "{\"type\":\"pong\"}"
}

/// MVP の reset は無くなり、司会の next_question に置き換わった（#768）。
/// reset を送るのは #768 より前に配られたページだけなので、invalid_message
/// ではなく client_outdated で再読み込みに誘導する。
pub fn decode_reset_from_an_old_page_is_client_outdated_test() {
  assert protocol.decode_client_message(
      "{\"type\":\"reset\",\"round_id\":1,\"request_id\":\"r1\"}",
    )
    == Error(protocol.client_outdated_error)
}

pub fn decode_host_commands_test() {
  assert protocol.decode_client_message(
      "{\"type\":\"open\",\"round_id\":1,\"request_id\":\"r1\"}",
    )
    == Ok(protocol.OpenAcceptance(1, Some("r1")))
  assert protocol.decode_client_message("{\"type\":\"close\",\"round_id\":2}")
    == Ok(protocol.CloseAcceptance(2, None))
  assert protocol.decode_client_message("{\"type\":\"skip\",\"round_id\":3}")
    == Ok(protocol.Skip(3, None))
  assert protocol.decode_client_message(
      "{\"type\":\"next_question\",\"round_id\":4}",
    )
    == Ok(protocol.NextQuestion(4, None))
  assert protocol.decode_client_message(
      "{\"type\":\"transfer_host\",\"participant_id\":\"p2\"}",
    )
    == Ok(protocol.TransferHost(ParticipantId("p2"), None))
  assert protocol.decode_client_message("{\"type\":\"end_session\"}")
    == Ok(protocol.EndSession(None))
}

pub fn decode_host_command_without_round_is_invalid_test() {
  let assert Error(ProtocolError(code: "invalid_message", ..)) =
    protocol.decode_client_message("{\"type\":\"open\"}")
  let assert Error(ProtocolError(code: "invalid_message", ..)) =
    protocol.decode_client_message(
      "{\"type\":\"transfer_host\",\"participant_id\":\"\"}",
    )
}

pub fn decode_watch_test() {
  assert protocol.decode_client_message(
      "{\"type\":\"watch\",\"v\":2,\"room_id\":\" abc234 \"}",
    )
    == Ok(protocol.Watch(RoomId("ABC234")))
  assert protocol.decode_client_message(
      "{\"type\":\"watch\",\"room_id\":\"ABC234\"}",
    )
    == Error(protocol.client_outdated_error)
}

pub fn decode_resume_with_a_host_token_test() {
  let json =
    "{\"type\":\"resume\",\"v\":2,\"room_id\":\"ABC234\",\"room_instance_id\":\"i1\",\"resume_token\":\"r\",\"host_token\":\"h\"}"
  assert protocol.decode_client_message(json)
    == Ok(protocol.Resume(RoomId("ABC234"), "i1", "r", Some("h")))
}

pub fn decode_join_missing_display_name_test() {
  let json = "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_join_empty_display_name_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\",\"display_name\":\"\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_missing_room_id_test() {
  let json = "{\"type\":\"join\",\"v\":2,\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_message",
      message: "Message did not match a known client message shape.",
    ))
}

pub fn decode_join_empty_room_id_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_whitespace_only_display_name_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\",\"display_name\":\"   \"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_whitespace_only_room_id_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"   \",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_both_fields_empty_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"\",\"display_name\":\"\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_trims_surrounding_whitespace_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\" ABCD \",\"display_name\":\" Alice \"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_normalizes_room_id_case_test() {
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"abCD\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Ok(protocol.Join(RoomId("ABCD"), "Alice"))
}

pub fn decode_join_display_name_over_max_length_test() {
  let too_long = string.repeat("a", 65)
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\",\"display_name\":\""
    <> too_long
    <> "\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_room_id_over_max_length_test() {
  let too_long = string.repeat("a", 65)
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\""
    <> too_long
    <> "\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_room_id",
      message: "room_id must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
    ))
}

pub fn decode_join_display_name_at_max_length_test() {
  let exactly_max = string.repeat("a", 64)
  let json =
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\",\"display_name\":\""
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
    "{\"type\":\"join\",\"v\":2,\"room_id\":\"ABCD\",\"display_name\":\""
    <> too_long_in_bytes
    <> "\"}"

  assert protocol.decode_client_message(json)
    == Error(ProtocolError(
      code: "invalid_display_name",
      message: "display_name must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
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
    State(
      instance_id: "i1",
      self_id: Some(ParticipantId("p1")),
      self_role: protocol.PlayerRole,
      round_id: 2,
      revision: 7,
      phase: protocol.Open,
      participants: [
        Participant(ParticipantId("p1"), "Alice", True, protocol.PlayerRole),
      ],
      buzzes: [BuzzResult(ParticipantId("p1"), "Alice", 1)],
      resume_token: None,
      created_room_id: None,
      host_token: None,
    )

  assert protocol.encode_server_message(message)
    == "{\"type\":\"state\",\"protocol_version\":2,\"room_instance_id\":\"i1\",\"self_role\":\"player\",\"round_id\":2,\"revision\":7,\"phase\":\"open\",\"participants\":[{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"connected\":true,\"role\":\"player\"}],\"buzzes\":[{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"position\":1}],\"self_id\":\"p1\"}"
}

pub fn encode_participant_joined_test() {
  let message =
    ParticipantJoined(
      "i1",
      3,
      Participant(ParticipantId("p1"), "Alice", True, protocol.HostRole),
    )

  assert protocol.encode_server_message(message)
    == "{\"type\":\"participant_joined\",\"room_instance_id\":\"i1\",\"revision\":3,\"participant\":{\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"connected\":true,\"role\":\"host\"}}"
}

pub fn encode_participant_left_test() {
  let message = ParticipantLeft("i1", 4, ParticipantId("p1"))

  assert protocol.encode_server_message(message)
    == "{\"type\":\"participant_left\",\"room_instance_id\":\"i1\",\"revision\":4,\"participant_id\":\"p1\"}"
}

pub fn encode_buzz_accepted_test() {
  let message =
    BuzzAccepted("i1", 5, 2, ParticipantId("p1"), "Alice", 1, protocol.Locked)

  assert protocol.encode_server_message(message)
    == "{\"type\":\"buzz_accepted\",\"phase\":\"locked\",\"room_instance_id\":\"i1\",\"revision\":5,\"round_id\":2,\"participant_id\":\"p1\",\"display_name\":\"Alice\",\"position\":1}"
}

pub fn encode_round_reset_test() {
  assert protocol.encode_server_message(RoundReset("i1", 6, 3))
    == "{\"type\":\"round_reset\",\"room_instance_id\":\"i1\",\"revision\":6,\"round_id\":3}"
}

pub fn encode_phase_changed_test() {
  assert protocol.encode_server_message(protocol.PhaseChanged(
      "i1",
      8,
      3,
      protocol.Waiting,
    ))
    == "{\"type\":\"phase_changed\",\"room_instance_id\":\"i1\",\"revision\":8,\"round_id\":3,\"phase\":\"waiting\"}"
}

pub fn encode_host_transferred_and_assigned_test() {
  assert protocol.encode_server_message(protocol.HostTransferred(
      "i1",
      9,
      ParticipantId("p1"),
      ParticipantId("p2"),
    ))
    == "{\"type\":\"host_transferred\",\"room_instance_id\":\"i1\",\"revision\":9,\"from\":\"p1\",\"to\":\"p2\"}"
  assert protocol.encode_server_message(protocol.HostAssigned("h2"))
    == "{\"type\":\"host_assigned\",\"host_token\":\"h2\"}"
}

/// 会場表示の state には self_id が無く、self_role が display（#768）。
pub fn encode_state_for_a_display_test() {
  let encoded =
    protocol.encode_server_message(State(
      instance_id: "i1",
      self_id: None,
      self_role: protocol.DisplayRole,
      round_id: 1,
      revision: 0,
      phase: protocol.Waiting,
      participants: [],
      buzzes: [],
      resume_token: None,
      created_room_id: None,
      host_token: None,
    ))
  assert string.contains(encoded, "\"self_role\":\"display\"")
  assert !string.contains(encoded, "self_id")
}

pub fn encode_reply_test() {
  let message = Reply("r1", ProtocolErrorMessage("stale_round", "old"))

  assert protocol.encode_server_message(message)
    == "{\"type\":\"reply\",\"request_id\":\"r1\",\"result\":{\"type\":\"error\",\"code\":\"stale_round\",\"message\":\"old\"}}"
}

pub fn encode_error_test() {
  let message = ProtocolErrorMessage("invalid_message", "bad input")

  assert protocol.encode_server_message(message)
    == "{\"type\":\"error\",\"code\":\"invalid_message\",\"message\":\"bad input\"}"
}

// --- #767: 部屋の作成 ---------------------------------------------------------

pub fn decode_create_test() {
  let json = "{\"type\":\"create\",\"v\":2,\"display_name\":\" Alice \"}"

  assert protocol.decode_client_message(json) == Ok(protocol.Create("Alice"))
}

pub fn decode_create_without_version_is_client_outdated_test() {
  let json = "{\"type\":\"create\",\"display_name\":\"Alice\"}"

  assert protocol.decode_client_message(json)
    == Error(protocol.client_outdated_error)
}

pub fn decode_create_with_an_invalid_display_name_test() {
  let empty = "{\"type\":\"create\",\"v\":2,\"display_name\":\"  \"}"
  let too_long =
    "{\"type\":\"create\",\"v\":2,\"display_name\":\""
    <> string.repeat("あ", 22)
    <> "\"}"

  let assert Error(ProtocolError(code: "invalid_display_name", ..)) =
    protocol.decode_client_message(empty)
  let assert Error(ProtocolError(code: "invalid_display_name", ..)) =
    protocol.decode_client_message(too_long)
}

pub fn encode_state_for_the_creator_test() {
  let message =
    State(
      instance_id: "i1",
      self_id: Some(ParticipantId("p1")),
      self_role: protocol.HostRole,
      round_id: 1,
      revision: 1,
      phase: protocol.Waiting,
      participants: [],
      buzzes: [],
      resume_token: Some("r"),
      created_room_id: Some("ABC234"),
      host_token: Some("h"),
    )

  assert string.ends_with(
    protocol.encode_server_message(message),
    ",\"resume_token\":\"r\",\"room_id\":\"ABC234\",\"host_token\":\"h\"}",
  )
}
