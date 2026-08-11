import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamroom/protocol
import gleamroom/registry
import gleamroom/room
import mist.{
  type Connection, type Next, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}

/// Wires the WebSocket wire format to the Room registry and Room actors.
///
/// This module owns decoding/encoding and connection lifecycle only; it
/// resolves rooms through the registry, forwards typed commands to the
/// resolved Room actor, and translates Room events/snapshots back to wire
/// messages. It intentionally does not decide buzzer ordering or any other
/// room-domain rule.
type ConnectionState {
  ConnectionState(registry: Subject(registry.Message), room: Option(RoomHandle))
}

type RoomHandle {
  RoomHandle(
    subject: Subject(room.Message),
    participant_id: room.ParticipantId,
    session: Subject(room.RoomEvent),
  )
}

pub fn upgrade(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
) -> Response(ResponseData) {
  mist.websocket(
    request: req,
    handler: handle_message,
    on_init: fn(_connection) { on_init(registry_subject) },
    on_close: on_close,
  )
}

fn on_init(
  registry_subject: Subject(registry.Message),
) -> #(ConnectionState, Option(Selector(room.RoomEvent))) {
  #(ConnectionState(registry: registry_subject, room: None), None)
}

fn on_close(state: ConnectionState) -> Nil {
  case state.room {
    None -> Nil
    Some(handle) -> {
      let _ =
        room.dispatch(
          handle.subject,
          room.Leave(handle.participant_id),
          handle.session,
        )
      Nil
    }
  }
}

fn handle_message(
  state: ConnectionState,
  message: WebsocketMessage(room.RoomEvent),
  connection: WebsocketConnection,
) -> Next(ConnectionState, room.RoomEvent) {
  case message {
    mist.Text(text) -> handle_text(state, text, connection)
    // Binary frames carry no protocol meaning yet; ignoring them keeps the
    // connection alive instead of crashing.
    mist.Binary(_data) -> mist.continue(state)
    mist.Custom(event) -> {
      case room_event_to_server_message(event) {
        Some(server_message) -> send_server_message(connection, server_message)
        None -> Nil
      }
      mist.continue(state)
    }
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
  }
}

fn handle_text(
  state: ConnectionState,
  text: String,
  connection: WebsocketConnection,
) -> Next(ConnectionState, room.RoomEvent) {
  case protocol.decode_client_message(text) {
    Error(error) -> {
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(error.code, error.message),
      )
      mist.continue(state)
    }
    Ok(protocol.Join(wire_room_id, display_name)) ->
      handle_join(state, connection, wire_room_id, display_name)
    Ok(protocol.Buzz) -> handle_buzz(state, connection)
    Ok(protocol.Reset) -> handle_reset(state, connection)
  }
}

fn handle_join(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_room_id: protocol.RoomId,
  display_name: String,
) -> Next(ConnectionState, room.RoomEvent) {
  case state.room {
    Some(_) -> {
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "already_joined",
          "This connection has already joined a room.",
        ),
      )
      mist.continue(state)
    }
    None -> {
      let room_subject =
        registry.lookup(
          state.registry,
          registry.room_id(protocol.room_id_to_string(wire_room_id)),
        )
      let participant_id = room.participant_id(new_participant_id())
      let session = process.new_subject()

      case
        room.dispatch(
          room_subject,
          room.Join(participant_id, display_name),
          session,
        )
      {
        room.ParticipantJoined(_participant) -> {
          let snapshot = room.get_snapshot(room_subject)
          let buzz_snapshot = room.get_buzz_snapshot(room_subject)
          send_server_message(
            connection,
            protocol.State(
              participants: list.map(snapshot, to_wire_participant),
              buzzes: list.map(buzz_snapshot, to_wire_buzz_result),
            ),
          )
          let next_state =
            ConnectionState(
              ..state,
              room: Some(RoomHandle(room_subject, participant_id, session)),
            )
          let selector = process.new_selector() |> process.select(session)
          mist.continue(next_state) |> mist.with_selector(selector)
        }
        room.JoinRejected(_, _) -> {
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(
              "join_rejected",
              "Unable to join the requested room.",
            ),
          )
          mist.continue(state)
        }
        // `Join` never yields any other event; kept for exhaustiveness since
        // `room.RoomEvent` is shared across every room command.
        room.ParticipantLeft(_)
        | room.LeaveRejected(_, _)
        | room.BuzzAccepted(_, _)
        | room.BuzzRejected(_, _)
        | room.RoundReset -> mist.continue(state)
      }
    }
  }
}

fn handle_buzz(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, room.RoomEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection)
      mist.continue(state)
    }
    Some(handle) -> {
      case
        room.dispatch(
          handle.subject,
          room.Buzz(handle.participant_id),
          handle.session,
        )
      {
        room.BuzzAccepted(id, position) ->
          send_server_message(
            connection,
            protocol.BuzzAccepted(to_wire_participant_id(id), position),
          )
        room.BuzzRejected(_, _) ->
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(
              "buzz_rejected",
              "Buzz was not accepted for the current round.",
            ),
          )
        // `Buzz` never yields any other event; kept for exhaustiveness since
        // `room.RoomEvent` is shared across every room command.
        room.ParticipantJoined(_)
        | room.JoinRejected(_, _)
        | room.ParticipantLeft(_)
        | room.LeaveRejected(_, _)
        | room.RoundReset -> Nil
      }
      mist.continue(state)
    }
  }
}

fn handle_reset(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, room.RoomEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection)
      mist.continue(state)
    }
    Some(handle) -> {
      case room.dispatch(handle.subject, room.ResetRound, handle.session) {
        room.RoundReset -> send_server_message(connection, protocol.RoundReset)
        // `ResetRound` never yields any other event; kept for exhaustiveness
        // since `room.RoomEvent` is shared across every room command.
        room.ParticipantJoined(_)
        | room.JoinRejected(_, _)
        | room.ParticipantLeft(_)
        | room.LeaveRejected(_, _)
        | room.BuzzAccepted(_, _)
        | room.BuzzRejected(_, _) -> Nil
      }
      mist.continue(state)
    }
  }
}

fn send_not_joined_error(connection: WebsocketConnection) -> Nil {
  send_server_message(
    connection,
    protocol.ProtocolErrorMessage(
      "not_joined",
      "Join a room before sending this command.",
    ),
  )
}

fn send_server_message(
  connection: WebsocketConnection,
  message: protocol.ServerMessage,
) -> Nil {
  let _ =
    mist.send_text_frame(connection, protocol.encode_server_message(message))
  Nil
}

fn room_event_to_server_message(
  event: room.RoomEvent,
) -> Option(protocol.ServerMessage) {
  case event {
    room.ParticipantJoined(participant) ->
      Some(protocol.ParticipantJoined(to_wire_participant(participant)))
    room.ParticipantLeft(id) ->
      Some(protocol.ParticipantLeft(to_wire_participant_id(id)))
    room.BuzzAccepted(id, position) ->
      Some(protocol.BuzzAccepted(to_wire_participant_id(id), position))
    room.RoundReset -> Some(protocol.RoundReset)
    room.JoinRejected(_, _) -> None
    room.LeaveRejected(_, _) -> None
    room.BuzzRejected(_, _) -> None
  }
}

fn to_wire_participant(participant: room.Participant) -> protocol.Participant {
  protocol.Participant(
    id: to_wire_participant_id(participant.id),
    display_name: participant.display_name,
  )
}

fn to_wire_participant_id(id: room.ParticipantId) -> protocol.ParticipantId {
  protocol.participant_id(room.participant_id_to_string(id))
}

fn to_wire_buzz_result(result: room.BuzzResult) -> protocol.BuzzResult {
  protocol.BuzzResult(
    participant_id: to_wire_participant_id(result.participant_id),
    position: result.position,
  )
}

/// Derives a participant id from this connection's own process identity.
/// Each WebSocket connection runs as its own process, so this is unique for
/// the lifetime of the connection without requiring client-supplied
/// identity or a shared counter.
fn new_participant_id() -> String {
  process.self() |> string.inspect
}
