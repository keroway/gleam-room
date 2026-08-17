import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
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
      "Alice",
      1,
    ))
    == Some(protocol.BuzzAccepted(protocol.participant_id("p1"), "Alice", 1))
}

pub fn room_event_to_server_message_round_reset_test() {
  assert websocket.room_event_to_server_message(room.RoundReset)
    == Some(protocol.RoundReset)
}

// `JoinRejected` is never actually delivered to `room_event_to_server_message`:
// `broadcast`/`broadcast_all` never emit it (see room.gleam's "Rejections are
// not broadcast" comment), and `apply_join`'s `JoinRejected` result only ever
// reaches the caller's direct `actor.call` reply channel, not the `session`
// subject that feeds this function. This test exercises the exhaustive `case`
// arm directly rather than a reachable code path (#153).
pub fn join_reject_code_and_message_room_full_test() {
  assert websocket.join_reject_code_and_message(room.RoomFull)
    == #(
      "room_full",
      "This room has reached its maximum number of participants.",
    )
}

pub fn join_reject_code_and_message_invalid_display_name_test() {
  assert websocket.join_reject_code_and_message(room.InvalidDisplayName)
    == #("invalid_display_name", "The provided display name is not valid.")
}

pub fn join_reject_code_and_message_already_joined_test() {
  assert websocket.join_reject_code_and_message(room.AlreadyJoined)
    == #("already_joined", "This connection has already joined a room.")
}

pub fn room_event_to_server_message_join_rejected_unreachable_branch_test() {
  assert websocket.room_event_to_server_message(room.JoinRejected(
      room.participant_id("p1"),
      room.AlreadyJoined,
    ))
    == None
}

// Unlike `JoinRejected`/`BuzzRejected`, `LeaveRejected` is reachable: it can
// be produced by `apply_command(state.room, Leave(id))` inside the
// `SessionDown` handler and delivered via `broadcast_all`.
pub fn room_event_to_server_message_leave_rejected_is_not_broadcast_test() {
  assert websocket.room_event_to_server_message(room.LeaveRejected(
      room.participant_id("p1"),
      room.NotJoined,
    ))
    == None
}

// See the comment on the `JoinRejected` test above: `BuzzRejected` is
// likewise never delivered to `room_event_to_server_message` in practice
// (#153).
pub fn room_event_to_server_message_buzz_rejected_unreachable_branch_test() {
  assert websocket.room_event_to_server_message(room.BuzzRejected(
      room.participant_id("p1"),
      room.BuzzerNotJoined,
    ))
    == None
}

pub fn buzz_reject_code_and_message_already_buzzed_test() {
  assert websocket.buzz_reject_code_and_message(room.AlreadyBuzzed)
    == #(
      "already_buzzed",
      "This participant already buzzed for the current round.",
    )
}

pub fn buzz_reject_code_and_message_buzzer_not_joined_test() {
  assert websocket.buzz_reject_code_and_message(room.BuzzerNotJoined)
    == #("buzzer_not_joined", "This connection has not joined the room yet.")
}

/// `registry.lookup` が room actor を引けなかった場合のメッセージ（#32）。
pub fn room_unavailable_message_lookup_failed_test() {
  assert websocket.room_unavailable_message(websocket.RoomLookupFailed)
    == "The room could not be started. Please try again."
}

/// `Join` の応答がタイムアウトした場合のメッセージ。再試行ではなく再接続を
/// 促す（#33 のコメント参照: 再試行は二重参加を招くため）。
pub fn room_unavailable_message_join_timed_out_test() {
  assert websocket.room_unavailable_message(websocket.JoinTimedOut)
    == "The room did not respond in time. Reconnect to try again."
}

/// `Buzz`/`ResetRound` の応答がタイムアウトした場合のメッセージ（#33）。
pub fn room_unavailable_message_reply_timed_out_test() {
  assert websocket.room_unavailable_message(websocket.ReplyTimedOut)
    == "The room did not respond in time. Please try again."
}

pub fn not_joined_message_test() {
  assert websocket.not_joined_message
    == "Join a room before sending this command."
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

/// Origin ヘッダが無い接続は許可する（非ブラウザクライアントを想定、#124）。
pub fn origin_header_allowed_missing_origin_is_allowed_test() {
  assert websocket.origin_header_allowed(Error(Nil), "example.com")
}

/// Origin が Host と一致する場合は許可する（同一オリジンのブラウザ接続）。
pub fn origin_header_allowed_matching_origin_is_allowed_test() {
  assert websocket.origin_header_allowed(
    Ok("https://example.com"),
    "example.com",
  )
}

/// ポートが付いていても host 部分だけを比較する。
pub fn origin_header_allowed_matching_origin_with_port_is_allowed_test() {
  assert websocket.origin_header_allowed(
    Ok("http://example.com:4000"),
    "example.com",
  )
}

/// Origin が Host と異なる場合は拒否する（Cross-Site WebSocket Hijacking、#124）。
pub fn origin_header_allowed_mismatched_origin_is_rejected_test() {
  assert !websocket.origin_header_allowed(
    Ok("https://evil.example"),
    "example.com",
  )
}

/// Origin が URI として解釈できない場合も拒否する。
pub fn origin_header_allowed_unparsable_origin_is_rejected_test() {
  assert !websocket.origin_header_allowed(Ok("not a uri"), "example.com")
}

/// 前回の tick 以降にクライアントから何も届いていなければタイムアウトと判定する（#35）。
pub fn heartbeat_outcome_idle_times_out_test() {
  assert websocket.heartbeat_outcome(False) == websocket.HeartbeatTimedOut
}

/// 前回の tick 以降にクライアントから何か届いていれば続行と判定する（#35）。
pub fn heartbeat_outcome_active_continues_test() {
  assert websocket.heartbeat_outcome(True) == websocket.HeartbeatContinues
}

/// 上限バイト数ちょうどなら受理する（#126）。
pub fn frame_size_outcome_at_the_limit_is_accepted_test() {
  let text = string.repeat("a", 2048)
  assert websocket.frame_size_outcome(text) == websocket.FrameSizeAccepted
}

/// 上限を1バイトでも超えたら拒否する（#126）。
pub fn frame_size_outcome_over_the_limit_is_rejected_test() {
  let text = string.repeat("a", 2049)
  assert websocket.frame_size_outcome(text) == websocket.FrameTooLarge
}
