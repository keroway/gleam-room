import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string
import gleamroom/wire.{
  type ParticipantId, type ProtocolError, type RoomId, RoomId,
  participant_id_to_string,
}

/// The wire-format client/server protocol boundary for the buzzer MVP.
///
/// This module only translates between JSON text and typed Gleam values. It
/// does not know about room registries, actors, or game rules — see
/// `docs/architecture.md` for the transport/domain boundary this module sits
/// on. Identifier types and join validation live in `wire.gleam`.
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

pub fn decode_client_message(
  from json_string: String,
) -> Result(ClientMessage, ProtocolError) {
  case json.parse(from: json_string, using: client_message_decoder()) {
    Ok(Join(RoomId(room_id), display_name)) ->
      wire.validate_join(room_id, display_name)
      |> result.map(fn(joined) { Join(joined.0, joined.1) })
    Ok(message) -> Ok(message)
    Error(error) -> Error(wire.decode_error(error))
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

fn join_decoder() -> decode.Decoder(ClientMessage) {
  use raw_room_id <- decode.field("room_id", decode.string)
  use raw_display_name <- decode.field("display_name", decode.string)
  let room_id = string.trim(raw_room_id) |> string.uppercase
  let display_name = string.trim(raw_display_name)
  decode.success(Join(RoomId(room_id), display_name))
}

pub fn encode_server_message(message: ServerMessage) -> String {
  wire.encode_message(message, with: server_message_to_json)
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
    #("participant_id", json.string(participant_id_to_string(participant.id))),
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
