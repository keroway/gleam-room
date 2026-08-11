import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/string

/// The wire-format client/server protocol boundary for the buzzer MVP.
///
/// This module only translates between JSON text and typed Gleam values. It
/// does not know about room registries, actors, or game rules — see
/// `docs/architecture.md` for the transport/domain boundary this module sits
/// on.
///
/// JSON is handled via a direct binding to `thoas` (the Erlang JSON library
/// that `gleam_json` itself wraps) rather than `gleam_json`, because the
/// published `gleam_json` releases available to this project's locked
/// `gleam_stdlib` version target an incompatible `gleam/dynamic` API on
/// either side of the version range.
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
  BuzzResult(participant_id: ParticipantId, position: Int)
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
  BuzzAccepted(participant_id: ParticipantId, position: Int)
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
  case thoas_decode(json_string) {
    Error(_) ->
      Error(ProtocolError(
        code: "malformed_json",
        message: "Message body was not valid JSON.",
      ))
    Ok(dynamic_value) ->
      case decode.run(dynamic_value, client_message_decoder()) {
        Ok(message) -> Ok(message)
        Error(_) ->
          Error(ProtocolError(
            code: "invalid_message",
            message: "Message did not match a known client message shape.",
          ))
      }
  }
}

@external(erlang, "thoas", "decode")
fn thoas_decode(json_string: String) -> Result(Dynamic, Dynamic)

fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use message_type <- decode.field("type", decode.string)
  case message_type {
    "join" -> join_decoder()
    "buzz" -> decode.success(Buzz)
    "reset" -> decode.success(Reset)
    _ -> decode.failure(Buzz, "ClientMessage")
  }
}

fn join_decoder() -> decode.Decoder(ClientMessage) {
  use raw_room_id <- decode.field("room_id", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  case string.is_empty(raw_room_id), string.is_empty(display_name) {
    False, False -> decode.success(Join(RoomId(raw_room_id), display_name))
    _, _ -> decode.failure(Buzz, "Join")
  }
}

pub fn encode_server_message(message: ServerMessage) -> String {
  message
  |> server_message_to_dynamic
  |> thoas_encode
}

@external(erlang, "thoas", "encode")
fn thoas_encode(term: Dynamic) -> String

fn server_message_to_dynamic(message: ServerMessage) -> Dynamic {
  case message {
    State(participants, buzzes) ->
      json_object([
        #("type", dynamic.string("state")),
        #(
          "participants",
          dynamic.list(list.map(participants, participant_to_dynamic)),
        ),
        #("buzzes", dynamic.list(list.map(buzzes, buzz_result_to_dynamic))),
      ])
    ParticipantJoined(participant) ->
      json_object([
        #("type", dynamic.string("participant_joined")),
        #("participant", participant_to_dynamic(participant)),
      ])
    ParticipantLeft(left_participant_id) ->
      json_object([
        #("type", dynamic.string("participant_left")),
        #(
          "participant_id",
          dynamic.string(participant_id_to_string(left_participant_id)),
        ),
      ])
    BuzzAccepted(accepted_participant_id, position) ->
      json_object([
        #("type", dynamic.string("buzz_accepted")),
        #(
          "participant_id",
          dynamic.string(participant_id_to_string(accepted_participant_id)),
        ),
        #("position", dynamic.int(position)),
      ])
    RoundReset -> json_object([#("type", dynamic.string("round_reset"))])
    ProtocolErrorMessage(code, message) ->
      json_object([
        #("type", dynamic.string("error")),
        #("code", dynamic.string(code)),
        #("message", dynamic.string(message)),
      ])
  }
}

fn participant_to_dynamic(participant: Participant) -> Dynamic {
  json_object([
    #("id", dynamic.string(participant_id_to_string(participant.id))),
    #("display_name", dynamic.string(participant.display_name)),
  ])
}

fn buzz_result_to_dynamic(buzz_result: BuzzResult) -> Dynamic {
  json_object([
    #(
      "participant_id",
      dynamic.string(participant_id_to_string(buzz_result.participant_id)),
    ),
    #("position", dynamic.int(buzz_result.position)),
  ])
}

/// Builds a JSON object as an order-preserving proplist (`thoas` encodes
/// `[{key, value}, ...]` as an object, unlike an Erlang map, whose key order
/// is not guaranteed).
fn json_object(fields: List(#(String, Dynamic))) -> Dynamic {
  fields
  |> list.map(fn(field) {
    let #(key, value) = field
    dynamic.array([dynamic.string(key), value])
  })
  |> dynamic.list
}
