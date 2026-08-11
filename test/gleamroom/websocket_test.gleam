import gleam/option.{None, Some}
import gleamroom/protocol
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
  let result = room.BuzzResult(room.participant_id("p1"), 3)

  assert websocket.to_wire_buzz_result(result)
    == protocol.BuzzResult(protocol.participant_id("p1"), 3)
}
