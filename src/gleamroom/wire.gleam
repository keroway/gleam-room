import gleam/json
import gleam/string

/// Wire-boundary pieces shared by `protocol.gleam` (buzzer) and
/// `poker_protocol.gleam` (Planning Poker): identifier types, join-field
/// validation, and the decode-error/encode skeletons. Per
/// `docs/duplication-inventory.md` 1.4 these were byte-identical in both
/// protocols; the message variants themselves stay app-specific.
pub type RoomId {
  RoomId(String)
}

pub fn room_id_to_string(id: RoomId) -> String {
  let RoomId(value) = id
  value
}

pub type ParticipantId {
  ParticipantId(String)
}

pub fn participant_id(value: String) -> ParticipantId {
  ParticipantId(value)
}

pub fn participant_id_to_string(id: ParticipantId) -> String {
  let ParticipantId(value) = id
  value
}

/// An explicit decode/protocol failure, returned instead of crashing the
/// calling process when a client sends an invalid or unknown message.
pub type ProtocolError {
  ProtocolError(code: String, message: String)
}

/// Maps a `json.parse` failure to a `ProtocolError`: a well-formed JSON
/// document of the wrong shape is `invalid_message`, anything else is
/// `malformed_json`.
pub fn decode_error(error: json.DecodeError) -> ProtocolError {
  case error {
    json.UnableToDecode(_) ->
      ProtocolError(
        code: "invalid_message",
        message: "Message did not match a known client message shape.",
      )
    _ ->
      ProtocolError(
        code: "malformed_json",
        message: "Message body was not valid JSON.",
      )
  }
}

/// The maximum accepted length for a trimmed `room_id` or `display_name`.
/// Chosen to comfortably fit any human-typed value while bounding the
/// per-participant memory/bandwidth cost of broadcasting `State`.
const max_field_length = 64

/// Content-validates an already-trimmed `join` message, reporting which field
/// is invalid instead of collapsing both cases into the generic
/// `invalid_message` shape error. A `room_id` failure takes priority over a
/// `display_name` failure when both are invalid, since `room_id` decides
/// which room the client would otherwise join.
pub fn validate_join(
  room_id: String,
  display_name: String,
) -> Result(#(RoomId, String), ProtocolError) {
  case is_valid_field(room_id), is_valid_field(display_name) {
    True, True -> Ok(#(RoomId(room_id), display_name))
    False, _ ->
      Error(ProtocolError(
        code: "invalid_room_id",
        message: "room_id must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
      ))
    True, False ->
      Error(ProtocolError(
        code: "invalid_display_name",
        message: "display_name must be 1-64 characters (max 64 UTF-8 bytes) after trimming whitespace.",
      ))
  }
}

fn is_valid_field(value: String) -> Bool {
  !string.is_empty(value)
  && string.length(value) <= max_field_length
  && string.byte_size(value) <= max_field_length
}

pub fn encode_message(message: a, with to_json: fn(a) -> json.Json) -> String {
  message
  |> to_json
  |> json.to_string
}
