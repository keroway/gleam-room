import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import gleamroom/poker
import gleamroom/poker_protocol
import gleamroom/poker_registry
import logging
import mist.{
  type Connection, type Next, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}

/// Wires the Planning Poker wire format to the poker registry and poker Room
/// actors. Mirrors `websocket.gleam`'s responsibilities (upgrade, heartbeat,
/// frame size/rate limiting, domain⇔wire translation) but is a fully
/// separate module per ADR 0009: Planning Poker duplicates the buzzer's
/// transport rather than sharing it (#281's 非目標).
type ConnectionState {
  ConnectionState(
    registry: Subject(poker_registry.Message),
    room: Option(RoomHandle),
    heartbeat_subject: Subject(ConnectionEvent),
    // クライアントから何か受け取るたびに True へ戻す（`websocket.gleam`'s
    // `active_since_heartbeat` と同じ理由、#35）。
    active_since_heartbeat: Bool,
    // 直近のハートビート窓で受理したテキストフレームの数
    // （`websocket.gleam`'s `messages_since_heartbeat` と同じ理由、#156）。
    messages_since_heartbeat: Int,
  )
}

/// 接続プロセスが `Selector` 経由で受け取りうるメッセージ全体。
/// `websocket.gleam`'s `ConnectionEvent` と同じ理由。
pub type ConnectionEvent {
  RoomBroadcast(poker.PokerEvent)
  HeartbeatTick
}

/// `websocket.gleam`'s `heartbeat_interval_ms` と同じ値・同じ理由。
const heartbeat_interval_ms = 30_000

type RoomHandle {
  RoomHandle(
    subject: Subject(poker.Message),
    participant_id: poker.ParticipantId,
    session: Subject(poker.PokerEvent),
    // 切断時に registry へ Release を送るために保持する
    // （`websocket.gleam`'s `RoomHandle.room_id` と同じ理由、#26）。
    room_id: poker_registry.RoomId,
  )
}

pub fn upgrade(
  req: Request(Connection),
  registry_subject: Subject(poker_registry.Message),
) -> Response(ResponseData) {
  case origin_allowed(req) {
    True ->
      mist.websocket(
        request: req,
        handler: handle_message,
        on_init: fn(_connection) { on_init(registry_subject) },
        on_close: on_close,
      )
    False -> {
      logging.log(
        logging.Warning,
        "poker websocket upgrade rejected: origin not allowed, host="
          <> req.host,
      )
      response.new(403)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

/// `websocket.gleam`'s `origin_allowed` と同じ理由（#124）。
fn origin_allowed(req: Request(Connection)) -> Bool {
  origin_header_allowed(request.get_header(req, "origin"), req.host)
}

/// `websocket.gleam`'s `origin_header_allowed` と同じ理由・実装。
pub fn origin_header_allowed(
  origin_header: Result(String, Nil),
  host: String,
) -> Bool {
  case origin_header {
    Error(Nil) -> True
    Ok(origin) ->
      case uri.parse(origin) {
        Ok(parsed) -> parsed.host == Some(host)
        Error(Nil) -> False
      }
  }
}

fn on_init(
  registry_subject: Subject(poker_registry.Message),
) -> #(ConnectionState, Option(Selector(ConnectionEvent))) {
  logging.log(
    logging.Info,
    "poker websocket connection opened: " <> connection_tag(),
  )
  let heartbeat_subject = process.new_subject()
  process.send_after(heartbeat_subject, heartbeat_interval_ms, HeartbeatTick)
  let selector = process.new_selector() |> process.select(heartbeat_subject)
  #(
    ConnectionState(
      registry: registry_subject,
      room: None,
      heartbeat_subject: heartbeat_subject,
      active_since_heartbeat: True,
      messages_since_heartbeat: 0,
    ),
    Some(selector),
  )
}

fn on_close(state: ConnectionState) -> Nil {
  case state.room {
    None -> {
      logging.log(
        logging.Info,
        "poker websocket connection closed (not joined): " <> connection_tag(),
      )
      Nil
    }
    Some(handle) -> {
      logging.log(
        logging.Info,
        "poker websocket connection closed: "
          <> connection_tag()
          <> ", room="
          <> poker_registry.room_id_to_string(handle.room_id)
          <> ", participant="
          <> poker.participant_id_to_string(handle.participant_id),
      )
      // `websocket.gleam`'s `on_close` と同じ理由: room が死んでいれば
      // room actor 側の SessionDown 経由で外れる。
      let _ =
        poker.dispatch(
          handle.subject,
          poker.Leave(handle.participant_id),
          handle.session,
        )
      // `websocket.gleam`'s `on_close` と同じ理由（#26 / #36）:
      // 空かどうかの判定は room actor 側で行う。
      release_room(state.registry, handle.room_id, handle.subject)
      Nil
    }
  }
}

/// `websocket.gleam`'s `binary_frame_code_and_message` と同じ理由・値。
pub const binary_frame_code_and_message = #(
  "binary_frame",
  "Binary frames are not supported.",
)

fn handle_message(
  state: ConnectionState,
  message: WebsocketMessage(ConnectionEvent),
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case message {
    mist.Text(text) -> handle_text(mark_active(state), text, connection)
    mist.Binary(_data) -> {
      logging.log(logging.Info, "protocol message rejected: code=binary_frame")
      let #(code, message) = binary_frame_code_and_message
      send_server_message(
        connection,
        poker_protocol.ProtocolErrorMessage(code, message),
      )
      mist.continue(mark_active(state))
    }
    mist.Custom(RoomBroadcast(event)) -> {
      case room_event_to_server_message(event) {
        Some(server_message) -> send_server_message(connection, server_message)
        None -> Nil
      }
      mist.continue(state)
    }
    mist.Custom(HeartbeatTick) -> handle_heartbeat_tick(state)
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
  }
}

/// `websocket.gleam`'s `mark_active` と同じ理由。
fn mark_active(state: ConnectionState) -> ConnectionState {
  ConnectionState(..state, active_since_heartbeat: True)
}

/// `websocket.gleam`'s `record_message` と同じ理由（#156）。
fn record_message(state: ConnectionState) -> ConnectionState {
  ConnectionState(
    ..state,
    messages_since_heartbeat: state.messages_since_heartbeat + 1,
  )
}

/// `websocket.gleam`'s `HeartbeatOutcome` と同じ理由・実装。
pub type HeartbeatOutcome {
  HeartbeatTimedOut
  HeartbeatContinues
}

/// `websocket.gleam`'s `heartbeat_outcome` と同じ理由・実装（#35）。
pub fn heartbeat_outcome(active_since_heartbeat: Bool) -> HeartbeatOutcome {
  case active_since_heartbeat {
    False -> HeartbeatTimedOut
    True -> HeartbeatContinues
  }
}

/// `websocket.gleam`'s `handle_heartbeat_tick` と同じ理由・実装。
fn handle_heartbeat_tick(
  state: ConnectionState,
) -> Next(ConnectionState, ConnectionEvent) {
  case heartbeat_outcome(state.active_since_heartbeat) {
    HeartbeatTimedOut -> {
      logging.log(
        logging.Info,
        "poker websocket idle timeout: " <> connection_tag(),
      )
      mist.stop()
    }
    HeartbeatContinues -> {
      process.send_after(
        state.heartbeat_subject,
        heartbeat_interval_ms,
        HeartbeatTick,
      )
      mist.continue(
        ConnectionState(
          ..state,
          active_since_heartbeat: False,
          messages_since_heartbeat: 0,
        ),
      )
    }
  }
}

/// `websocket.gleam`'s `max_text_frame_bytes` と同じ値・同じ理由（#126）。
const max_text_frame_bytes = 2048

/// `websocket.gleam`'s `FrameSizeOutcome` と同じ理由・実装。
pub type FrameSizeOutcome {
  FrameSizeAccepted
  FrameTooLarge
}

/// `websocket.gleam`'s `frame_size_outcome` と同じ理由・実装。
pub fn frame_size_outcome(text: String) -> FrameSizeOutcome {
  case string.byte_size(text) > max_text_frame_bytes {
    True -> FrameTooLarge
    False -> FrameSizeAccepted
  }
}

/// `websocket.gleam`'s `frame_too_large_code_and_message` と同じ理由・値。
pub const frame_too_large_code_and_message = #(
  "frame_too_large",
  "Message exceeds the maximum allowed size.",
)

/// `websocket.gleam`'s `max_messages_per_heartbeat_window` と同じ値・同じ理由（#156）。
const max_messages_per_heartbeat_window = 30

/// `websocket.gleam`'s `MessageRateOutcome` と同じ理由・実装。
pub type MessageRateOutcome {
  MessageRateAccepted
  MessageRateLimited
}

/// `websocket.gleam`'s `rate_limited_code_and_message` と同じ理由・値。
pub const rate_limited_code_and_message = #(
  "rate_limited",
  "Too many messages. Please slow down.",
)

/// `websocket.gleam`'s `message_rate_outcome` と同じ理由・実装。
pub fn message_rate_outcome(
  count_after_this_message: Int,
) -> MessageRateOutcome {
  case count_after_this_message > max_messages_per_heartbeat_window {
    True -> MessageRateLimited
    False -> MessageRateAccepted
  }
}

fn handle_text(
  state: ConnectionState,
  text: String,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  let state = record_message(state)
  case message_rate_outcome(state.messages_since_heartbeat) {
    MessageRateLimited -> {
      logging.log(logging.Info, "protocol message rejected: code=rate_limited")
      let #(code, message) = rate_limited_code_and_message
      send_server_message(
        connection,
        poker_protocol.ProtocolErrorMessage(code, message),
      )
      mist.continue(state)
    }
    MessageRateAccepted ->
      case frame_size_outcome(text) {
        FrameTooLarge -> {
          logging.log(
            logging.Info,
            "protocol message rejected: code=frame_too_large",
          )
          let #(code, message) = frame_too_large_code_and_message
          send_server_message(
            connection,
            poker_protocol.ProtocolErrorMessage(code, message),
          )
          mist.stop()
        }
        FrameSizeAccepted ->
          case poker_protocol.decode_client_message(text) {
            Error(error) -> {
              logging.log(
                logging.Info,
                "protocol message rejected: code=" <> error.code,
              )
              send_server_message(
                connection,
                poker_protocol.ProtocolErrorMessage(error.code, error.message),
              )
              mist.continue(state)
            }
            Ok(poker_protocol.Join(wire_room_id, display_name)) ->
              handle_join(state, connection, wire_room_id, display_name)
            Ok(poker_protocol.Vote(card)) ->
              handle_vote(state, connection, card)
            Ok(poker_protocol.Reveal) -> handle_reveal(state, connection)
            Ok(poker_protocol.Reset) -> handle_reset(state, connection)
          }
      }
  }
}

/// `websocket.gleam`'s `join_reject_code_and_message` と同じ理由・実装。
pub fn join_reject_code_and_message(
  reason: poker.JoinRejectReason,
) -> #(String, String) {
  case reason {
    poker.RoomFull -> #(
      "room_full",
      "This room has reached its maximum number of participants.",
    )
    poker.InvalidDisplayName -> #(
      "invalid_display_name",
      "The provided display name is not valid.",
    )
    poker.AlreadyJoined -> #(
      "already_joined",
      "This connection has already joined a room.",
    )
  }
}

fn handle_join(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_room_id: poker_protocol.RoomId,
  display_name: String,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    Some(handle) -> {
      logging.log(
        logging.Info,
        "already joined: room="
          <> poker_registry.room_id_to_string(handle.room_id)
          <> ", participant="
          <> poker.participant_id_to_string(handle.participant_id),
      )
      let #(code, message) = join_reject_code_and_message(poker.AlreadyJoined)
      send_server_message(
        connection,
        poker_protocol.ProtocolErrorMessage(code, message),
      )
      mist.continue(state)
    }
    None -> {
      let room_id =
        poker_registry.room_id(poker_protocol.room_id_to_string(wire_room_id))
      // `websocket.gleam`'s `handle_join` と同じ理由（#32）: room の起動に
      // 失敗しても接続は生かす。
      use room_subject <- with_room(state, connection, room_id)
      let participant_id = poker.participant_id(new_participant_id())
      let session = process.new_subject()

      // `websocket.gleam`'s `handle_join` と同じ理由（#33）: 応答が無ければ
      // join を諦め、理由をクライアントへ返す。
      use event <- with_join_reply(
        state.registry,
        room_id,
        room_subject,
        connection,
        poker.dispatch(
          room_subject,
          poker.Join(participant_id, display_name),
          session,
        ),
      )
      case event {
        poker.ParticipantJoined(participant) -> {
          logging.log(
            logging.Info,
            "poker join accepted: room="
              <> poker_registry.room_id_to_string(room_id)
              <> ", participant="
              <> poker.participant_id_to_string(participant.id),
          )
          // `websocket.gleam`'s `handle_join` と同じ理由（#65 / #121）: 1回の
          // `get_state` で snapshot を取り、取得に失敗しても接続は落とさない。
          let poker_state = case poker.get_state(room_subject) {
            Ok(poker_state) -> poker_state
            Error(Nil) -> {
              logging.log(
                logging.Warning,
                "get_state timed out after join, returning empty participants: room="
                  <> poker_registry.room_id_to_string(room_id)
                  <> ", participant="
                  <> poker.participant_id_to_string(participant.id),
              )
              poker.new_state()
            }
          }
          send_server_message(
            connection,
            poker_protocol.State(
              phase: to_wire_round_phase(poker_state.phase),
              participants: poker.snapshot(poker_state)
                |> list.map(fn(p) {
                  to_wire_participant_view(
                    p,
                    poker.has_voted(poker_state, p.id),
                  )
                }),
            ),
          )
          let next_state =
            ConnectionState(
              ..state,
              room: Some(RoomHandle(
                room_subject,
                participant_id,
                session,
                room_id,
              )),
            )
          let selector =
            process.new_selector()
            |> process.select(state.heartbeat_subject)
            |> process.select_map(session, RoomBroadcast)
          mist.continue(next_state) |> mist.with_selector(selector)
        }
        poker.JoinRejected(_, reason) -> {
          logging.log(
            logging.Info,
            "poker join rejected: room="
              <> poker_registry.room_id_to_string(room_id)
              <> ", reason="
              <> string.inspect(reason),
          )
          let #(code, message) = join_reject_code_and_message(reason)
          send_server_message(
            connection,
            poker_protocol.ProtocolErrorMessage(code, message),
          )
          mist.continue(state)
        }
        // `Join` never yields any other event; kept for exhaustiveness since
        // `poker.PokerEvent` is shared across every room command.
        poker.ParticipantLeft(_)
        | poker.LeaveRejected(_, _)
        | poker.VoteRegistered(_)
        | poker.VoteRejected(_, _)
        | poker.RoundRevealed(_)
        | poker.RoundReset -> mist.continue(state)
      }
    }
  }
}

/// `websocket.gleam`'s `buzz_reject_code_and_message` と同じ理由・実装。
pub fn vote_reject_code_and_message(
  reason: poker.VoteRejectReason,
) -> #(String, String) {
  case reason {
    poker.VoterNotJoined -> #(
      "voter_not_joined",
      "This connection has not joined the room yet.",
    )
    poker.RoundAlreadyRevealed -> #(
      "round_already_revealed",
      "Voting is closed until the round is reset.",
    )
  }
}

fn handle_vote(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_card: poker_protocol.Card,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "vote")
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        poker.dispatch(
          handle.subject,
          poker.Vote(handle.participant_id, to_domain_card(wire_card)),
          handle.session,
        ),
      )
      case event {
        poker.VoteRegistered(id) -> {
          logging.log(
            logging.Info,
            "vote registered: room="
              <> poker_registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> poker.participant_id_to_string(id),
          )
          send_server_message(
            connection,
            poker_protocol.VoteRegistered(to_wire_participant_id(id)),
          )
        }
        poker.VoteRejected(id, reason) -> {
          logging.log(
            logging.Info,
            "vote rejected: room="
              <> poker_registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> poker.participant_id_to_string(id)
              <> ", reason="
              <> string.inspect(reason),
          )
          let #(code, message) = vote_reject_code_and_message(reason)
          send_server_message(
            connection,
            poker_protocol.ProtocolErrorMessage(code, message),
          )
        }
        // `Vote` never yields any other event; kept for exhaustiveness since
        // `poker.PokerEvent` is shared across every room command.
        poker.ParticipantJoined(_)
        | poker.JoinRejected(_, _)
        | poker.ParticipantLeft(_)
        | poker.LeaveRejected(_, _)
        | poker.RoundRevealed(_)
        | poker.RoundReset -> Nil
      }
      mist.continue(state)
    }
  }
}

fn handle_reveal(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "reveal")
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        poker.dispatch(handle.subject, poker.Reveal, handle.session),
      )
      case event {
        poker.RoundRevealed(votes) -> {
          logging.log(
            logging.Info,
            "round revealed: room="
              <> poker_registry.room_id_to_string(handle.room_id)
              <> ", by="
              <> poker.participant_id_to_string(handle.participant_id),
          )
          send_server_message(
            connection,
            poker_protocol.RoundRevealed(list.map(votes, to_wire_revealed_vote)),
          )
        }
        // `Reveal` never yields any other event; kept for exhaustiveness
        // since `poker.PokerEvent` is shared across every room command.
        poker.ParticipantJoined(_)
        | poker.JoinRejected(_, _)
        | poker.ParticipantLeft(_)
        | poker.LeaveRejected(_, _)
        | poker.VoteRegistered(_)
        | poker.VoteRejected(_, _)
        | poker.RoundReset -> Nil
      }
      mist.continue(state)
    }
  }
}

fn handle_reset(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "reset")
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        poker.dispatch(handle.subject, poker.ResetRound, handle.session),
      )
      case event {
        poker.RoundReset -> {
          logging.log(
            logging.Info,
            "poker round reset: room="
              <> poker_registry.room_id_to_string(handle.room_id)
              <> ", by="
              <> poker.participant_id_to_string(handle.participant_id),
          )
          send_server_message(connection, poker_protocol.RoundReset)
        }
        // `ResetRound` never yields any other event; kept for exhaustiveness
        // since `poker.PokerEvent` is shared across every room command.
        poker.ParticipantJoined(_)
        | poker.JoinRejected(_, _)
        | poker.ParticipantLeft(_)
        | poker.LeaveRejected(_, _)
        | poker.VoteRegistered(_)
        | poker.VoteRejected(_, _)
        | poker.RoundRevealed(_) -> Nil
      }
      mist.continue(state)
    }
  }
}

/// `websocket.gleam`'s `release_room` と同じ理由・実装（#116）。
pub fn release_room(
  registry_subject: Subject(poker_registry.Message),
  room_id: poker_registry.RoomId,
  room_subject: Subject(poker.Message),
) -> Nil {
  case process.subject_owner(registry_subject) {
    Ok(_pid) ->
      process.send(
        registry_subject,
        poker_registry.Release(room_id, room_subject),
      )
    Error(Nil) ->
      logging.log(
        logging.Warning,
        "poker registry unavailable, skipping release: room="
          <> poker_registry.room_id_to_string(room_id),
      )
  }
}

/// `websocket.gleam`'s `RoomUnavailableReason` と同じ理由・実装。
pub type RoomUnavailableReason {
  RoomLookupFailed
  JoinTimedOut
  ReplyTimedOut
}

/// `websocket.gleam`'s `room_unavailable_message` と同じ理由・実装。
pub fn room_unavailable_message(reason: RoomUnavailableReason) -> String {
  case reason {
    RoomLookupFailed -> "The room could not be started. Please try again."
    JoinTimedOut -> "The room did not respond in time. Reconnect to try again."
    ReplyTimedOut -> "The room did not respond in time. Please try again."
  }
}

/// `websocket.gleam`'s `with_room` と同じ理由・実装（#32）。
fn with_room(
  state: ConnectionState,
  connection: WebsocketConnection,
  room_id: poker_registry.RoomId,
  next: fn(Subject(poker.Message)) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case poker_registry.lookup(state.registry, room_id) {
    Ok(room_subject) -> next(room_subject)
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "poker room unavailable: room="
          <> poker_registry.room_id_to_string(room_id),
      )
      send_server_message(
        connection,
        poker_protocol.ProtocolErrorMessage(
          "room_unavailable",
          room_unavailable_message(RoomLookupFailed),
        ),
      )
      mist.continue(state)
    }
  }
}

/// `websocket.gleam`'s `with_join_reply` と同じ理由・実装（#33 / #56 / #69 / #168）。
fn with_join_reply(
  registry_subject: Subject(poker_registry.Message),
  room_id: poker_registry.RoomId,
  room_subject: Subject(poker.Message),
  connection: WebsocketConnection,
  reply: Result(poker.PokerEvent, Nil),
  next: fn(poker.PokerEvent) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case reply {
    Ok(event) -> next(event)
    Error(Nil) -> {
      release_room(registry_subject, room_id, room_subject)
      send_server_message(
        connection,
        poker_protocol.ProtocolErrorMessage(
          "room_unavailable",
          room_unavailable_message(JoinTimedOut),
        ),
      )
      mist.stop()
    }
  }
}

/// `websocket.gleam`'s `with_room_reply` と同じ理由・実装（#33 / #100）。
fn with_room_reply(
  state: ConnectionState,
  connection: WebsocketConnection,
  reply: Result(poker.PokerEvent, Nil),
  next: fn(poker.PokerEvent) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case reply {
    Ok(event) -> next(event)
    Error(Nil) -> {
      send_room_unavailable(connection)
      mist.continue(ConnectionState(..state, room: None))
    }
  }
}

fn send_room_unavailable(connection: WebsocketConnection) -> Nil {
  send_server_message(
    connection,
    poker_protocol.ProtocolErrorMessage(
      "room_unavailable",
      room_unavailable_message(ReplyTimedOut),
    ),
  )
}

/// `websocket.gleam`'s `not_joined_message` と同じ理由・値。
pub const not_joined_message = "Join a room before sending this command."

fn send_not_joined_error(
  connection: WebsocketConnection,
  command: String,
) -> Nil {
  logging.log(
    logging.Info,
    "not joined: command=" <> command <> ", " <> connection_tag(),
  )
  send_server_message(
    connection,
    poker_protocol.ProtocolErrorMessage("not_joined", not_joined_message),
  )
}

fn send_server_message(
  connection: WebsocketConnection,
  message: poker_protocol.ServerMessage,
) -> Nil {
  case
    mist.send_text_frame(
      connection,
      poker_protocol.encode_server_message(message),
    )
  {
    Ok(Nil) -> Nil
    Error(reason) ->
      logging.log(
        logging.Warning,
        "poker server message send failed: reason="
          <> string.inspect(reason)
          <> " "
          <> connection_tag(),
      )
  }
}

/// Translates a `PokerEvent` broadcast from the poker room actor into the
/// wire message to send to other clients, or `None` when the event is a
/// rejection meant only for the connection that issued the command.
/// Mirrors `websocket.gleam`'s `room_event_to_server_message` (#24).
pub fn room_event_to_server_message(
  event: poker.PokerEvent,
) -> Option(poker_protocol.ServerMessage) {
  case event {
    poker.ParticipantJoined(participant) ->
      Some(
        poker_protocol.ParticipantJoined(to_wire_participant_view(
          participant,
          False,
        )),
      )
    poker.ParticipantLeft(id) ->
      Some(poker_protocol.ParticipantLeft(to_wire_participant_id(id)))
    poker.VoteRegistered(id) ->
      Some(poker_protocol.VoteRegistered(to_wire_participant_id(id)))
    poker.RoundRevealed(votes) ->
      Some(poker_protocol.RoundRevealed(list.map(votes, to_wire_revealed_vote)))
    poker.RoundReset -> Some(poker_protocol.RoundReset)
    poker.JoinRejected(_, _) -> None
    poker.LeaveRejected(_, _) -> None
    poker.VoteRejected(_, _) -> None
  }
}

/// Converts a domain `Participant` to its wire representation, including
/// whether it has voted this round. Mirrors `websocket.gleam`'s
/// `to_wire_participant` (#24).
pub fn to_wire_participant_view(
  participant: poker.Participant,
  has_voted: Bool,
) -> poker_protocol.ParticipantView {
  poker_protocol.ParticipantView(
    id: to_wire_participant_id(participant.id),
    display_name: participant.display_name,
    has_voted: has_voted,
  )
}

/// Converts a domain `ParticipantId` to its wire representation. Mirrors
/// `websocket.gleam`'s `to_wire_participant_id` (#24).
pub fn to_wire_participant_id(
  id: poker.ParticipantId,
) -> poker_protocol.ParticipantId {
  poker_protocol.participant_id(poker.participant_id_to_string(id))
}

/// Converts a domain `RoundPhase` to its wire representation.
pub fn to_wire_round_phase(
  phase: poker.RoundPhase,
) -> poker_protocol.RoundPhase {
  case phase {
    poker.Voting -> poker_protocol.Voting
    poker.Revealed -> poker_protocol.Revealed
  }
}

/// Converts a domain `RevealedVote` to its wire representation.
pub fn to_wire_revealed_vote(
  vote: poker.RevealedVote,
) -> poker_protocol.RevealedVote {
  poker_protocol.RevealedVote(
    participant_id: to_wire_participant_id(vote.participant_id),
    display_name: vote.display_name,
    value: option.map(vote.value, to_wire_card),
  )
}

/// Converts a domain `Card` to its wire representation. `poker.gleam` and
/// `poker_protocol.gleam` intentionally define distinct `Card` types per
/// ADR 0009, so this boundary makes the conversion explicit.
pub fn to_wire_card(card: poker.Card) -> poker_protocol.Card {
  case card {
    poker.Zero -> poker_protocol.Zero
    poker.One -> poker_protocol.One
    poker.Two -> poker_protocol.Two
    poker.Three -> poker_protocol.Three
    poker.Five -> poker_protocol.Five
    poker.Eight -> poker_protocol.Eight
    poker.Thirteen -> poker_protocol.Thirteen
    poker.TwentyOne -> poker_protocol.TwentyOne
    poker.QuestionMark -> poker_protocol.QuestionMark
    poker.Coffee -> poker_protocol.Coffee
  }
}

/// Converts a wire `Card` to its domain representation.
pub fn to_domain_card(card: poker_protocol.Card) -> poker.Card {
  case card {
    poker_protocol.Zero -> poker.Zero
    poker_protocol.One -> poker.One
    poker_protocol.Two -> poker.Two
    poker_protocol.Three -> poker.Three
    poker_protocol.Five -> poker.Five
    poker_protocol.Eight -> poker.Eight
    poker_protocol.Thirteen -> poker.Thirteen
    poker_protocol.TwentyOne -> poker.TwentyOne
    poker_protocol.QuestionMark -> poker.QuestionMark
    poker_protocol.Coffee -> poker.Coffee
  }
}

/// `websocket.gleam`'s `connection_tag` と同じ理由・実装（#28）。
fn connection_tag() -> String {
  "pid=" <> string.inspect(process.self())
}

/// `websocket.gleam`'s `new_participant_id` と同じ理由・実装（#28）。
pub fn new_participant_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base64_url_encode(False)
}
