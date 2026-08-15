import gleam/dynamic/decode
import gleam/json
import gleam/string

/// The wire-format client/server protocol boundary for the buzzer MVP.
///
/// This module only translates between JSON text and typed Gleam values. It
/// does not know about room registries, actors, or game rules — see
/// `docs/architecture.md` for the transport/domain boundary this module sits
/// on.
pub type RoomId {
  RoomId(String)
}

pub fn room_id(value: String) -> RoomId {
  RoomId(value)
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

pub type Participant {
  Participant(id: ParticipantId, display_name: String)
}

pub type BuzzResult {
  BuzzResult(participant_id: ParticipantId, display_name: String, position: Int)
}

/// A message sent from a client to the server.
pub type ClientMessage {
  Join(room_id: RoomId, display_name: String)
  Buzz
  Reset
}

/// A message sent from the server to a client.
pub type ServerMessage {
  State(participants: List(Participant), buzzes: List(BuzzResult))
  ParticipantJoined(participant: Participant)
  ParticipantLeft(participant_id: ParticipantId)
  BuzzAccepted(
    participant_id: ParticipantId,
    display_name: String,
    position: Int,
  )
  RoundReset
  ProtocolErrorMessage(code: String, message: String)
}

/// An explicit decode/protocol failure, returned instead of crashing the
/// calling process when a client sends an invalid or unknown message.
pub type ProtocolError {
  ProtocolError(code: String, message: String)
}

pub fn decode_client_message(
  from json_string: String,
) -> Result(ClientMessage, ProtocolError) {
  case json.parse(from: json_string, using: client_message_decoder()) {
    Ok(Join(RoomId(room_id), display_name)) ->
      validate_join(room_id, display_name)
    Ok(message) -> Ok(message)
    Error(json.UnableToDecode(_)) ->
      Error(ProtocolError(
        code: "invalid_message",
        message: "Message did not match a known client message shape.",
      ))
    Error(_) ->
      Error(ProtocolError(
        code: "malformed_json",
        message: "Message body was not valid JSON.",
      ))
  }
}

fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use message_type <- decode.field("type", decode.string)
  case message_type {
    "join" -> join_decoder()
    "buzz" -> decode.success(Buzz)
    "reset" -> decode.success(Reset)
    _ -> decode.failure(Buzz, "ClientMessage")
  }
}

/// The maximum accepted length for a trimmed `room_id` or `display_name`.
/// Chosen to comfortably fit any human-typed value while bounding the
/// per-participant memory/bandwidth cost of broadcasting `State`.
const max_field_length = 64

fn join_decoder() -> decode.Decoder(ClientMessage) {
  use raw_room_id <- decode.field("room_id", decode.string)
  use raw_display_name <- decode.field("display_name", decode.string)
  let room_id = string.trim(raw_room_id) |> string.uppercase
  let display_name = string.trim(raw_display_name)
  decode.success(Join(RoomId(room_id), display_name))
}

/// Content-validates an already-shape-decoded `join` message, reporting
/// which field is invalid instead of collapsing both cases into the generic
/// `invalid_message` shape error. A `room_id` failure takes priority over a
/// `display_name` failure when both are invalid, since `room_id` decides
/// which room the client would otherwise join.
fn validate_join(
  room_id: String,
  display_name: String,
) -> Result(ClientMessage, ProtocolError) {
  case is_valid_field(room_id), is_valid_field(display_name) {
    True, True -> Ok(Join(RoomId(room_id), display_name))
    False, _ ->
      Error(ProtocolError(
        code: "invalid_room_id",
        message: "room_id must be 1-64 characters after trimming whitespace.",
      ))
    True, False ->
      Error(ProtocolError(
        code: "invalid_display_name",
        message: "display_name must be 1-64 characters after trimming whitespace.",
      ))
  }
}

fn is_valid_field(value: String) -> Bool {
  !string.is_empty(value)
  && string.length(value) <= max_field_length
  && string.byte_size(value) <= max_field_length
}

pub fn encode_server_message(message: ServerMessage) -> String {
  message
  |> server_message_to_json
  |> json.to_string
}

fn server_message_to_json(message: ServerMessage) -> json.Json {
  case message {
    State(participants, buzzes) ->
      json.object([
        #("type", json.string("state")),
        #("participants", json.array(participants, participant_to_json)),
        #("buzzes", json.array(buzzes, buzz_result_to_json)),
      ])
    ParticipantJoined(participant) ->
      json.object([
        #("type", json.string("participant_joined")),
        #("participant", participant_to_json(participant)),
      ])
    ParticipantLeft(left_participant_id) ->
      json.object([
        #("type", json.string("participant_left")),
        #(
          "participant_id",
          json.string(participant_id_to_string(left_participant_id)),
        ),
      ])
    BuzzAccepted(accepted_participant_id, display_name, position) ->
      json.object([
        #("type", json.string("buzz_accepted")),
        #(
          "participant_id",
          json.string(participant_id_to_string(accepted_participant_id)),
        ),
        #("display_name", json.string(display_name)),
        #("position", json.int(position)),
      ])
    RoundReset -> json.object([#("type", json.string("round_reset"))])
    ProtocolErrorMessage(code, message) ->
      json.object([
        #("type", json.string("error")),
        #("code", json.string(code)),
        #("message", json.string(message)),
      ])
  }
}

fn participant_to_json(participant: Participant) -> json.Json {
  json.object([
    #("id", json.string(participant_id_to_string(participant.id))),
    #("display_name", json.string(participant.display_name)),
  ])
}

fn buzz_result_to_json(buzz_result: BuzzResult) -> json.Json {
  json.object([
    #(
      "participant_id",
      json.string(participant_id_to_string(buzz_result.participant_id)),
    ),
    #("display_name", json.string(buzz_result.display_name)),
    #("position", json.int(buzz_result.position)),
  ])
}
