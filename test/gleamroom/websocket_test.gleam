import gleam/erlang/process
import gleam/option.{None, Some}
import gleamroom/protocol
import gleamroom/registry
import gleamroom/room
import gleamroom/websocket

pub fn room_event_to_server_message_participant_joined_test() {
  let participant = room.Participant(room.participant_id("p1"), "Alice")

  assert websocket.room_event_to_server_message(room.ParticipantJoined(
      participant,
    ))
    == Some(
      protocol.ParticipantJoined(protocol.Participant(
        protocol.participant_id("p1"),
        "Alice",
      )),
    )
}

pub fn room_event_to_server_message_participant_left_test() {
  assert websocket.room_event_to_server_message(
      room.ParticipantLeft(room.participant_id("p1")),
    )
    == Some(protocol.ParticipantLeft(protocol.participant_id("p1")))
}

pub fn room_event_to_server_message_buzz_accepted_test() {
  assert websocket.room_event_to_server_message(room.BuzzAccepted(
      room.participant_id("p1"),
      1,
    ))
    == Some(protocol.BuzzAccepted(protocol.participant_id("p1"), 1))
}

pub fn room_event_to_server_message_round_reset_test() {
  assert websocket.room_event_to_server_message(room.RoundReset)
    == Some(protocol.RoundReset)
}

pub fn room_event_to_server_message_join_rejected_is_not_broadcast_test() {
  assert websocket.room_event_to_server_message(room.JoinRejected(
      room.participant_id("p1"),
      room.AlreadyJoined,
    ))
    == None
}

pub fn room_event_to_server_message_leave_rejected_is_not_broadcast_test() {
  assert websocket.room_event_to_server_message(room.LeaveRejected(
      room.participant_id("p1"),
      room.NotJoined,
    ))
    == None
}

pub fn room_event_to_server_message_buzz_rejected_is_not_broadcast_test() {
  assert websocket.room_event_to_server_message(room.BuzzRejected(
      room.participant_id("p1"),
      room.BuzzerNotJoined,
    ))
    == None
}

pub fn to_wire_participant_test() {
  let participant = room.Participant(room.participant_id("p1"), "Alice")

  assert websocket.to_wire_participant(participant)
    == protocol.Participant(protocol.participant_id("p1"), "Alice")
}

pub fn to_wire_participant_id_test() {
  assert websocket.to_wire_participant_id(room.participant_id("p1"))
    == protocol.participant_id("p1")
}

pub fn to_wire_buzz_result_test() {
  let result = room.BuzzResult(room.participant_id("p1"), "Alice", 3)

  assert websocket.to_wire_buzz_result(result)
    == protocol.BuzzResult(protocol.participant_id("p1"), "Alice", 3)
}

pub fn release_room_sends_release_when_registry_is_reachable_test() {
  let registry_subject = process.new_subject()
  let room_subject = process.new_subject()
  let room_id = registry.room_id("room-1")

  websocket.release_room(registry_subject, room_id, room_subject)

  let assert Ok(received) = process.receive(registry_subject, 100)
  assert received == registry.Release(room_id, room_subject)
}

/// registry の named subject が(再起動中などで)未登録でも panic しないこと（#116）。
/// 以前は `process.send` を無guardで呼んでおり、named subject 未登録時に
/// `let assert` で panic して mist の接続プロセスごとクラッシュしていた。
pub fn release_room_does_not_panic_when_registry_is_unregistered_test() {
  let name = process.new_name("gleamroom_release_room_test")
  let registry_subject = process.named_subject(name)
  let room_subject = process.new_subject()
  let room_id = registry.room_id("room-2")

  websocket.release_room(registry_subject, room_id, room_subject)
}
