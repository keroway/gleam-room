import gleam/dynamic/decode
import gleam/json
import gleam/list
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
  Participant(
    id: ParticipantId,
    display_name: String,
    connected: Bool,
    role: Role,
  )
}

/// A connection's role on the wire (#768). `DisplayRole` is never a
/// participant's role; it is what a display's own `state` says about itself.
pub type Role {
  HostRole
  PlayerRole
  DisplayRole
}

/// The acceptance phase on the wire (#768).
pub type Phase {
  Waiting
  Open
  Locked
  Finished
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
  /// 新しい部屋を作り、作った本人として参加する（#767）。部屋コードは
  /// サーバが発行する。
  Create(display_name: String)
  /// 会場表示として部屋を見る（#768）。参加者にはならず、操作もできない。
  Watch(room_id: RoomId)
  Buzz(round_id: Int, request_id: Option(String))
  /// 司会の操作（#768）。司会かどうかは room が判定する。
  OpenAcceptance(round_id: Int, request_id: Option(String))
  CloseAcceptance(round_id: Int, request_id: Option(String))
  Skip(round_id: Int, request_id: Option(String))
  NextQuestion(round_id: Int, request_id: Option(String))
  TransferHost(participant_id: ParticipantId, request_id: Option(String))
  EndSession(request_id: Option(String))
  /// Re-attaches to the participant identified by `resume_token`, issued
  /// when this client first joined room `room_instance_id` (#766). A host
  /// also sends its `host_token`, which lets it come back even after its
  /// grace period ran out (#768).
  Resume(
    room_id: RoomId,
    instance_id: String,
    resume_token: String,
    host_token: Option(String),
  )
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
  ///
  /// `self_id` is absent for a display, which is not a participant (#768).
  State(
    instance_id: String,
    self_id: Option(ParticipantId),
    self_role: Role,
    round_id: Int,
    revision: Int,
    phase: Phase,
    participants: List(Participant),
    buzzes: List(BuzzResult),
    resume_token: Option(String),
    /// 部屋を作った本人への応答にだけ付く（#767）。発行された部屋コードと
    /// 司会 token。token はこの応答以外に出さない。
    created_room_id: Option(String),
    host_token: Option(String),
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
  /// `phase` is the phase after this buzz (the first buzz locks, #768).
  BuzzAccepted(
    instance_id: String,
    revision: Int,
    round_id: Int,
    participant_id: ParticipantId,
    display_name: String,
    position: Int,
    phase: Phase,
  )
  /// `round_id` is the question that starts with the host's `next_question`.
  /// The phase is `waiting` and the buzz list is empty.
  RoundReset(instance_id: String, revision: Int, round_id: Int)
  /// The acceptance phase changed (#768).
  PhaseChanged(instance_id: String, revision: Int, round_id: Int, phase: Phase)
  /// The host role moved (#768).
  HostTransferred(
    instance_id: String,
    revision: Int,
    from: ParticipantId,
    to: ParticipantId,
  )
  /// Sent only to the new host after a transfer (#768): the token to keep
  /// for coming back as host. Not a state change, so no revision.
  HostAssigned(host_token: String)
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
    Ok(RawCreate(Some(version), display_name)) if version == protocol_version ->
      wire.validate_display_name(display_name)
      |> result.map(Create)
    Ok(RawCreate(_, _)) -> Error(client_outdated_error)
    Ok(RawWatch(Some(version), room_id)) if version == protocol_version ->
      wire.validate_room_id(room_id) |> result.map(Watch)
    Ok(RawWatch(_, _)) -> Error(client_outdated_error)
    Ok(RawResume(Some(version), room_id, instance_id, token, host_token))
      if version == protocol_version
    ->
      case wire.validate_room_id(room_id) {
        Error(error) -> Error(error)
        Ok(room_id) ->
          case
            wire.is_valid_field(instance_id)
            && wire.is_valid_field(token)
            && option.unwrap(option.map(host_token, wire.is_valid_field), True)
          {
            True -> Ok(Resume(room_id, instance_id, token, host_token))
            False -> Error(invalid_token_error)
          }
      }
    Ok(RawResume(_, _, _, _, _)) -> Error(client_outdated_error)
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
  RawCreate(version: Option(Int), display_name: String)
  RawWatch(version: Option(Int), room_id: String)
  RawResume(
    version: Option(Int),
    room_id: String,
    instance_id: String,
    token: String,
    host_token: Option(String),
  )
  RawMessage(ClientMessage)
}

fn raw_client_message_decoder() -> decode.Decoder(RawClientMessage) {
  use message_type <- decode.field("type", decode.string)
  case message_type {
    "join" -> join_decoder()
    "create" -> create_decoder()
    "resume" -> resume_decoder()
    "watch" -> watch_decoder()
    "leave" -> decode.success(RawMessage(Leave))
    "buzz" -> round_command_decoder(Buzz)
    "open" -> round_command_decoder(OpenAcceptance)
    "close" -> round_command_decoder(CloseAcceptance)
    "skip" -> round_command_decoder(Skip)
    "next_question" -> round_command_decoder(NextQuestion)
    "transfer_host" -> transfer_host_decoder()
    "end_session" -> {
      use request_id <- optional_request_id()
      decode.success(RawMessage(EndSession(request_id)))
    }
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

fn create_decoder() -> decode.Decoder(RawClientMessage) {
  use version <- decode.optional_field("v", None, decode.map(decode.int, Some))
  use raw_display_name <- decode.field("display_name", decode.string)
  decode.success(RawCreate(version, string.trim(raw_display_name)))
}

fn resume_decoder() -> decode.Decoder(RawClientMessage) {
  use version <- decode.optional_field("v", None, decode.map(decode.int, Some))
  use raw_room_id <- decode.field("room_id", decode.string)
  use instance_id <- decode.field("room_instance_id", decode.string)
  use token <- decode.field("resume_token", decode.string)
  use host_token <- decode.optional_field(
    "host_token",
    None,
    decode.map(decode.string, Some),
  )
  let room_id = string.trim(raw_room_id) |> string.uppercase
  decode.success(RawResume(version, room_id, instance_id, token, host_token))
}

fn watch_decoder() -> decode.Decoder(RawClientMessage) {
  use version <- decode.optional_field("v", None, decode.map(decode.int, Some))
  use raw_room_id <- decode.field("room_id", decode.string)
  decode.success(RawWatch(version, string.trim(raw_room_id) |> string.uppercase))
}

fn round_command_decoder(
  make: fn(Int, Option(String)) -> ClientMessage,
) -> decode.Decoder(RawClientMessage) {
  use round_id <- decode.field("round_id", decode.int)
  use request_id <- optional_request_id()
  decode.success(RawMessage(make(round_id, request_id)))
}

fn transfer_host_decoder() -> decode.Decoder(RawClientMessage) {
  use raw_id <- decode.field("participant_id", decode.string)
  use request_id <- optional_request_id()
  case wire.is_valid_field(raw_id) {
    True ->
      decode.success(
        RawMessage(TransferHost(wire.participant_id(raw_id), request_id)),
      )
    False ->
      decode.failure(RawMessage(Sync), "participant_id (1-64 characters)")
  }
}

fn optional_request_id(
  next: fn(Option(String)) -> decode.Decoder(a),
) -> decode.Decoder(a) {
  decode.optional_field(
    "request_id",
    None,
    decode.map(request_id_decoder(), Some),
    next,
  )
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
      self_role,
      round_id,
      revision,
      phase,
      participants,
      buzzes,
      resume_token,
      created_room_id,
      host_token,
    ) ->
      json.object([
        #("type", json.string("state")),
        #("protocol_version", json.int(protocol_version)),
        #("room_instance_id", json.string(instance_id)),
        #("self_role", json.string(role_to_string(self_role))),
        #("round_id", json.int(round_id)),
        #("revision", json.int(revision)),
        #("phase", json.string(phase_to_string(phase))),
        #("participants", json.array(participants, participant_to_json)),
        #("buzzes", json.array(buzzes, buzz_result_to_json)),
        ..list.flatten([
          optional_string_field(
            "self_id",
            option.map(self_id, participant_id_to_string),
          ),
          optional_string_field("resume_token", resume_token),
          optional_string_field("room_id", created_room_id),
          optional_string_field("host_token", host_token),
        ])
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
      phase,
    ) ->
      json.object([
        #("type", json.string("buzz_accepted")),
        #("phase", json.string(phase_to_string(phase))),
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
    PhaseChanged(instance_id, revision, round_id, phase) ->
      json.object([
        #("type", json.string("phase_changed")),
        #("room_instance_id", json.string(instance_id)),
        #("revision", json.int(revision)),
        #("round_id", json.int(round_id)),
        #("phase", json.string(phase_to_string(phase))),
      ])
    HostTransferred(instance_id, revision, from, to) ->
      json.object([
        #("type", json.string("host_transferred")),
        #("room_instance_id", json.string(instance_id)),
        #("revision", json.int(revision)),
        #("from", json.string(participant_id_to_string(from))),
        #("to", json.string(participant_id_to_string(to))),
      ])
    HostAssigned(host_token) ->
      json.object([
        #("type", json.string("host_assigned")),
        #("host_token", json.string(host_token)),
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

fn optional_string_field(
  name: String,
  value: Option(String),
) -> List(#(String, json.Json)) {
  case value {
    Some(value) -> [#(name, json.string(value))]
    None -> []
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
    #("role", json.string(role_to_string(participant.role))),
  ])
}

pub fn role_to_string(role: Role) -> String {
  case role {
    HostRole -> "host"
    PlayerRole -> "player"
    DisplayRole -> "display"
  }
}

pub fn phase_to_string(phase: Phase) -> String {
  case phase {
    Waiting -> "waiting"
    Open -> "open"
    Locked -> "locked"
    Finished -> "finished"
  }
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
