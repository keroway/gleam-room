import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleamroom/wire.{
  type ParticipantId, type ProtocolError, type RoomId, participant_id_to_string,
}

/// The wire-format client/server protocol boundary for the buzzer MVP.
///
/// This module only translates between JSON text and typed Gleam values. It
/// does not know about room registries, actors, or game rules — see
/// `docs/architecture.md` for the transport/domain boundary this module sits
/// on. Identifier types and join validation live in `wire.gleam`.
/// `connected` is false while the participant is within the resume grace
/// period after losing their connection (#766).
pub type Participant {
  Participant(id: ParticipantId, display_name: String, connected: Bool)
}

pub type BuzzResult {
  BuzzResult(participant_id: ParticipantId, display_name: String, position: Int)
}

/// The buzzer wire protocol version this server speaks (#765, ADR 0010).
/// A `join` without `"v": 2` is rejected with `client_outdated`, and every
/// `state` carries it as `protocol_version` so a page served by an older
/// deployment can tell it must reload.
pub const protocol_version = 2

/// A message sent from a client to the server.
///
/// `round_id` names the round the client saw; the room rejects a command for
/// any other round (`stale_round`). `request_id` is optional and only
/// correlates the direct reply with the request; ordering comes from the
/// `revision` on server messages, never from `request_id` (#765).
pub type ClientMessage {
  Join(room_id: RoomId, display_name: String)
  Buzz(round_id: Int, request_id: Option(String))
  Reset(round_id: Int, request_id: Option(String))
  /// Re-attaches to the participant identified by `resume_token`, issued
  /// when this client first joined room `room_instance_id` (#766).
  Resume(room_id: RoomId, instance_id: String, resume_token: String)
  /// Leaves the room for good: the participant is removed at once and the
  /// resume token stops working (#766). Closing the socket is not a leave.
  Leave
  /// Asks for a fresh `state` after the client detected a missing revision.
  Sync
  /// アプリレベルのkeepalive（#764）。ブラウザはWebSocketのping frameを送れず、
  /// 無操作の部屋ではサーバ側のハートビートが30〜60秒で接続を閉じるため、
  /// クライアントが定期的に送る。ドメイン（Room）には届かない。
  Ping
}

/// A message sent from the server to a client.
///
/// Every message that reports a state change carries the room's
/// `instance_id` and the `revision` it produced, so the client applies each
/// change exactly once and ignores notifications from an earlier room with
/// the same code (#765).
pub type ServerMessage {
  /// `resume_token` is present only in the `state` answering a successful
  /// `join`, and only to that client (#766). Every other `state` omits it.
  State(
    instance_id: String,
    self_id: ParticipantId,
    round_id: Int,
    revision: Int,
    participants: List(Participant),
    buzzes: List(BuzzResult),
    resume_token: Option(String),
  )
  ParticipantJoined(
    instance_id: String,
    revision: Int,
    participant: Participant,
  )
  ParticipantLeft(
    instance_id: String,
    revision: Int,
    participant_id: ParticipantId,
  )
  BuzzAccepted(
    instance_id: String,
    revision: Int,
    round_id: Int,
    participant_id: ParticipantId,
    display_name: String,
    position: Int,
  )
  /// `round_id` is the round that starts with this reset.
  RoundReset(instance_id: String, revision: Int, round_id: Int)
  /// The participant lost their connection and may still resume (#766).
  ParticipantDisconnected(
    instance_id: String,
    revision: Int,
    participant_id: ParticipantId,
  )
  /// The participant resumed within the grace period (#766).
  ParticipantReconnected(
    instance_id: String,
    revision: Int,
    participant_id: ParticipantId,
  )
  /// The direct answer to a request that carried a `request_id`. The same
  /// change may also arrive as a broadcast; both carry the same revision.
  Reply(request_id: String, result: ServerMessage)
  /// `Ping` への応答（#764）。
  Pong
  ProtocolErrorMessage(code: String, message: String)
}

pub fn decode_client_message(
  from json_string: String,
) -> Result(ClientMessage, ProtocolError) {
  case json.parse(from: json_string, using: raw_client_message_decoder()) {
    Ok(RawJoin(Some(version), room_id, display_name))
      if version == protocol_version
    ->
      wire.validate_join(room_id, display_name)
      |> result.map(fn(joined) { Join(joined.0, joined.1) })
    Ok(RawJoin(_, _, _)) -> Error(client_outdated_error)
    Ok(RawResume(Some(version), room_id, instance_id, token))
      if version == protocol_version
    ->
      case wire.validate_room_id(room_id) {
        Error(error) -> Error(error)
        Ok(room_id) ->
          case wire.is_valid_field(instance_id) && wire.is_valid_field(token) {
            True -> Ok(Resume(room_id, instance_id, token))
            False -> Error(invalid_token_error)
          }
      }
    Ok(RawResume(_, _, _, _)) -> Error(client_outdated_error)
    Ok(RawMessage(message)) -> Ok(message)
    Error(error) -> Error(wire.decode_error(error))
  }
}

/// Sent (and the connection closed) when a client speaks an older protocol
/// version (#765). Reloading the page always fixes it, because the page is
/// served by the same server.
pub const client_outdated_error =
  wire.ProtocolError(
    code: "client_outdated",
    message: "This page is outdated. Reload the page to continue.",
  )

/// A `resume` whose token or room instance is malformed. Answered the same
/// way as a token the room does not know (#766).
pub const invalid_token_error =
  wire.ProtocolError(
    code: "invalid_token",
    message: "The saved session could not be resumed. Join as a new participant.",
  )

type RawClientMessage {
  RawJoin(version: Option(Int), room_id: String, display_name: String)
  RawResume(
    version: Option(Int),
    room_id: String,
    instance_id: String,
    token: String,
  )
  RawMessage(ClientMessage)
}

fn raw_client_message_decoder() -> decode.Decoder(RawClientMessage) {
  use message_type <- decode.field("type", decode.string)
  case message_type {
    "join" -> join_decoder()
    "resume" -> resume_decoder()
    "leave" -> decode.success(RawMessage(Leave))
    "buzz" -> round_command_decoder(Buzz)
    "reset" -> round_command_decoder(Reset)
    "sync" -> decode.success(RawMessage(Sync))
    "ping" -> decode.success(RawMessage(Ping))
    _ -> decode.failure(RawMessage(Sync), "ClientMessage")
  }
}

fn join_decoder() -> decode.Decoder(RawClientMessage) {
  use version <- decode.optional_field("v", None, decode.map(decode.int, Some))
  use raw_room_id <- decode.field("room_id", decode.string)
  use raw_display_name <- decode.field("display_name", decode.string)
  let room_id = string.trim(raw_room_id) |> string.uppercase
  let display_name = string.trim(raw_display_name)
  decode.success(RawJoin(version, room_id, display_name))
}

fn resume_decoder() -> decode.Decoder(RawClientMessage) {
  use version <- decode.optional_field("v", None, decode.map(decode.int, Some))
  use raw_room_id <- decode.field("room_id", decode.string)
  use instance_id <- decode.field("room_instance_id", decode.string)
  use token <- decode.field("resume_token", decode.string)
  let room_id = string.trim(raw_room_id) |> string.uppercase
  decode.success(RawResume(version, room_id, instance_id, token))
}

fn round_command_decoder(
  make: fn(Int, Option(String)) -> ClientMessage,
) -> decode.Decoder(RawClientMessage) {
  use round_id <- decode.field("round_id", decode.int)
  use request_id <- decode.optional_field(
    "request_id",
    None,
    decode.map(request_id_decoder(), Some),
  )
  decode.success(RawMessage(make(round_id, request_id)))
}

fn request_id_decoder() -> decode.Decoder(String) {
  use id <- decode.then(decode.string)
  case is_valid_request_id(id) {
    True -> decode.success(id)
    False -> decode.failure("", "request_id (1-64 characters)")
  }
}

fn is_valid_request_id(id: String) -> Bool {
  string.length(id) > 0 && string.length(id) <= 64
}

/// Leniently reads a valid `request_id` from a raw frame, for replies sent
/// before (or instead of) a full decode, such as `rate_limited` or a decode
/// error, so the client can still resolve the pending request (#765; same
/// approach as `poker_protocol.vote_request_id`).
pub fn request_id(text: String) -> Option(String) {
  let decoder = {
    use id <- decode.field("request_id", request_id_decoder())
    decode.success(id)
  }
  option.from_result(json.parse(text, decoder))
}

/// Wraps `message` as the direct reply to `request_id`, or returns it
/// unchanged when the request carried none.
pub fn correlate(
  message: ServerMessage,
  request_id: Option(String),
) -> ServerMessage {
  case request_id {
    Some(id) -> Reply(id, message)
    None -> message
  }
}

pub fn encode_server_message(message: ServerMessage) -> String {
  wire.encode_message(message, with: server_message_to_json)
}

fn server_message_to_json(message: ServerMessage) -> json.Json {
  case message {
    State(
      instance_id,
      self_id,
      round_id,
      revision,
      participants,
      buzzes,
      resume_token,
    ) ->
      json.object([
        #("type", json.string("state")),
        #("protocol_version", json.int(protocol_version)),
        #("room_instance_id", json.string(instance_id)),
        #("self_id", json.string(participant_id_to_string(self_id))),
        #("round_id", json.int(round_id)),
        #("revision", json.int(revision)),
        #("participants", json.array(participants, participant_to_json)),
        #("buzzes", json.array(buzzes, buzz_result_to_json)),
        ..case resume_token {
          Some(token) -> [#("resume_token", json.string(token))]
          None -> []
        }
      ])
    ParticipantJoined(instance_id, revision, participant) ->
      json.object([
        #("type", json.string("participant_joined")),
        #("room_instance_id", json.string(instance_id)),
        #("revision", json.int(revision)),
        #("participant", participant_to_json(participant)),
      ])
    ParticipantLeft(instance_id, revision, left_participant_id) ->
      json.object([
        #("type", json.string("participant_left")),
        #("room_instance_id", json.string(instance_id)),
        #("revision", json.int(revision)),
        #(
          "participant_id",
          json.string(participant_id_to_string(left_participant_id)),
        ),
      ])
    BuzzAccepted(
      instance_id,
      revision,
      round_id,
      accepted_participant_id,
      display_name,
      position,
    ) ->
      json.object([
        #("type", json.string("buzz_accepted")),
        #("room_instance_id", json.string(instance_id)),
        #("revision", json.int(revision)),
        #("round_id", json.int(round_id)),
        #(
          "participant_id",
          json.string(participant_id_to_string(accepted_participant_id)),
        ),
        #("display_name", json.string(display_name)),
        #("position", json.int(position)),
      ])
    RoundReset(instance_id, revision, round_id) ->
      json.object([
        #("type", json.string("round_reset")),
        #("room_instance_id", json.string(instance_id)),
        #("revision", json.int(revision)),
        #("round_id", json.int(round_id)),
      ])
    ParticipantDisconnected(instance_id, revision, id) ->
      presence_to_json("participant_disconnected", instance_id, revision, id)
    ParticipantReconnected(instance_id, revision, id) ->
      presence_to_json("participant_reconnected", instance_id, revision, id)
    Reply(id, result) ->
      json.object([
        #("type", json.string("reply")),
        #("request_id", json.string(id)),
        #("result", server_message_to_json(result)),
      ])
    Pong -> json.object([#("type", json.string("pong"))])
    ProtocolErrorMessage(code, message) ->
      json.object([
        #("type", json.string("error")),
        #("code", json.string(code)),
        #("message", json.string(message)),
      ])
  }
}

fn presence_to_json(
  message_type: String,
  instance_id: String,
  revision: Int,
  id: ParticipantId,
) -> json.Json {
  json.object([
    #("type", json.string(message_type)),
    #("room_instance_id", json.string(instance_id)),
    #("revision", json.int(revision)),
    #("participant_id", json.string(participant_id_to_string(id))),
  ])
}

fn participant_to_json(participant: Participant) -> json.Json {
  json.object([
    #("participant_id", json.string(participant_id_to_string(participant.id))),
    #("display_name", json.string(participant.display_name)),
    #("connected", json.bool(participant.connected)),
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
