import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

/// The wire-format client/server protocol boundary for Planning Poker.
///
/// Mirrors `protocol.gleam`'s boundary role for the buzzer (translating JSON
/// text to/from typed Gleam values, nothing more), but is a fully separate
/// module per ADR 0009: Planning Poker duplicates the buzzer's wire types
/// rather than sharing them, and this module's `Card`/`ParticipantId` are
/// distinct types from `poker.gleam`'s domain types of the same name — see
/// `docs/planning-poker.md` for the wire protocol this module implements.
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

/// The fixed card set from `docs/planning-poker.md`. A custom type (rather
/// than passing the wire strings through) so an invalid card is rejected at
/// this boundary and never reaches the domain layer.
pub type Card {
  Zero
  One
  Two
  Three
  Five
  Eight
  Thirteen
  TwentyOne
  QuestionMark
  Coffee
}

pub fn card_to_wire_string(card: Card) -> String {
  case card {
    Zero -> "0"
    One -> "1"
    Two -> "2"
    Three -> "3"
    Five -> "5"
    Eight -> "8"
    Thirteen -> "13"
    TwentyOne -> "21"
    QuestionMark -> "?"
    Coffee -> "coffee"
  }
}

pub fn card_from_wire_string(value: String) -> Result(Card, Nil) {
  case value {
    "0" -> Ok(Zero)
    "1" -> Ok(One)
    "2" -> Ok(Two)
    "3" -> Ok(Three)
    "5" -> Ok(Five)
    "8" -> Ok(Eight)
    "13" -> Ok(Thirteen)
    "21" -> Ok(TwentyOne)
    "?" -> Ok(QuestionMark)
    "coffee" -> Ok(Coffee)
    _ -> Error(Nil)
  }
}

pub type RoundPhase {
  Voting
  Revealed
}

fn round_phase_to_wire_string(phase: RoundPhase) -> String {
  case phase {
    Voting -> "voting"
    Revealed -> "revealed"
  }
}

/// A participant as shown in `state`/`participant_joined`: presence-only
/// vote information (`has_voted`), never the vote value itself — the wire
/// contract's "deliberate asymmetry" (see `docs/planning-poker.md`).
pub type ParticipantView {
  ParticipantView(id: ParticipantId, display_name: String, has_voted: Bool)
}

/// One participant's revealed vote. `value` is `None` for a participant who
/// never cast a vote this round, sent explicitly rather than omitted from
/// the list.
pub type RevealedVote {
  RevealedVote(
    participant_id: ParticipantId,
    display_name: String,
    value: Option(Card),
  )
}

/// A message sent from a client to the server.
pub type ClientMessage {
  Join(room_id: RoomId, display_name: String)
  Vote(card: Card)
  Reveal
  Reset
}

/// A message sent from the server to a client.
pub type ServerMessage {
  State(phase: RoundPhase, participants: List(ParticipantView))
  ParticipantJoined(participant: ParticipantView)
  ParticipantLeft(participant_id: ParticipantId)
  VoteRegistered(participant_id: ParticipantId)
  RoundRevealed(votes: List(RevealedVote))
  RoundReset
  ProtocolErrorMessage(code: String, message: String)
}

/// An explicit decode/protocol failure, returned instead of crashing the
/// calling process when a client sends an invalid or unknown message.
pub type ProtocolError {
  ProtocolError(code: String, message: String)
}

/// An intermediate shape-only decode result, kept distinct from
/// `ClientMessage` so `join`/`vote` content validation (trimming, length
/// limits, card membership) happens after shape decoding succeeds, mirroring
/// `protocol.gleam`'s `validate_join` split.
type RawClientMessage {
  RawJoin(room_id: String, display_name: String)
  RawVote(value: String)
  RawReveal
  RawReset
}

pub fn decode_client_message(
  from json_string: String,
) -> Result(ClientMessage, ProtocolError) {
  case json.parse(from: json_string, using: client_message_decoder()) {
    Ok(RawJoin(raw_room_id, raw_display_name)) -> {
      let room_id = string.trim(raw_room_id) |> string.uppercase
      let display_name = string.trim(raw_display_name)
      validate_join(room_id, display_name)
    }
    Ok(RawVote(raw_value)) -> validate_vote(raw_value)
    Ok(RawReveal) -> Ok(Reveal)
    Ok(RawReset) -> Ok(Reset)
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

fn client_message_decoder() -> decode.Decoder(RawClientMessage) {
  use message_type <- decode.field("type", decode.string)
  case message_type {
    "join" -> join_decoder()
    "vote" -> vote_decoder()
    "reveal" -> decode.success(RawReveal)
    "reset" -> decode.success(RawReset)
    _ -> decode.failure(RawReveal, "ClientMessage")
  }
}

/// The maximum accepted length for a trimmed `room_id` or `display_name`,
/// matching `protocol.gleam`'s `max_field_length` for the same reason.
const max_field_length = 64

fn join_decoder() -> decode.Decoder(RawClientMessage) {
  use raw_room_id <- decode.field("room_id", decode.string)
  use raw_display_name <- decode.field("display_name", decode.string)
  decode.success(RawJoin(raw_room_id, raw_display_name))
}

fn vote_decoder() -> decode.Decoder(RawClientMessage) {
  use raw_value <- decode.field("value", decode.string)
  decode.success(RawVote(raw_value))
}

/// Content-validates an already-shape-decoded `join` message, reporting
/// which field is invalid instead of collapsing both cases into the generic
/// `invalid_message` shape error. A `room_id` failure takes priority over a
/// `display_name` failure when both are invalid, mirroring
/// `protocol.gleam`'s `validate_join`.
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

fn validate_vote(raw_value: String) -> Result(ClientMessage, ProtocolError) {
  case card_from_wire_string(raw_value) {
    Ok(card) -> Ok(Vote(card))
    Error(Nil) ->
      Error(ProtocolError(
        code: "invalid_card",
        message: "value must be one of the fixed card set.",
      ))
  }
}

pub fn encode_server_message(message: ServerMessage) -> String {
  message
  |> server_message_to_json
  |> json.to_string
}

fn server_message_to_json(message: ServerMessage) -> json.Json {
  case message {
    State(phase, participants) ->
      json.object([
        #("type", json.string("state")),
        #("phase", json.string(round_phase_to_wire_string(phase))),
        #("participants", json.array(participants, participant_view_to_json)),
      ])
    ParticipantJoined(participant) ->
      json.object([
        #("type", json.string("participant_joined")),
        #("participant", participant_view_to_json(participant)),
      ])
    ParticipantLeft(left_participant_id) ->
      json.object([
        #("type", json.string("participant_left")),
        #(
          "participant_id",
          json.string(participant_id_to_string(left_participant_id)),
        ),
      ])
    VoteRegistered(voted_participant_id) ->
      json.object([
        #("type", json.string("vote_registered")),
        #(
          "participant_id",
          json.string(participant_id_to_string(voted_participant_id)),
        ),
      ])
    RoundRevealed(votes) ->
      json.object([
        #("type", json.string("revealed")),
        #("votes", json.array(votes, revealed_vote_to_json)),
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

fn participant_view_to_json(participant: ParticipantView) -> json.Json {
  json.object([
    #("participant_id", json.string(participant_id_to_string(participant.id))),
    #("display_name", json.string(participant.display_name)),
    #("has_voted", json.bool(participant.has_voted)),
  ])
}

fn revealed_vote_to_json(vote: RevealedVote) -> json.Json {
  json.object([
    #(
      "participant_id",
      json.string(participant_id_to_string(vote.participant_id)),
    ),
    #("display_name", json.string(vote.display_name)),
    #("value", case vote.value {
      Some(card) -> json.string(card_to_wire_string(card))
      None -> json.null()
    }),
  ])
}
