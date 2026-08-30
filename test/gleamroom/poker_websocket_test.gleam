import gleam/erlang/process
import gleam/string
import gleamroom/poker_registry
import gleamroom/poker_websocket

pub fn release_room_sends_release_when_registry_is_reachable_test() {
  let registry_subject = process.new_subject()
  let room_subject = process.new_subject()
  let room_id = poker_registry.room_id("room-1")

  poker_websocket.release_room(registry_subject, room_id, room_subject)

  let assert Ok(received) = process.receive(registry_subject, 100)
  assert received == poker_registry.Release(room_id, room_subject)
}

/// registry の named subject が(再起動中などで)未登録でも panic しないこと（#116）。
pub fn release_room_does_not_panic_when_registry_is_unregistered_test() {
  let name = process.new_name("gleamroom_poker_release_room_test")
  let registry_subject = process.named_subject(name)
  let room_subject = process.new_subject()
  let room_id = poker_registry.room_id("room-2")

  poker_websocket.release_room(registry_subject, room_id, room_subject)
}

/// Origin ヘッダが無い接続は許可する（非ブラウザクライアントを想定、#124）。
pub fn origin_header_allowed_missing_origin_is_allowed_test() {
  assert poker_websocket.origin_header_allowed(Error(Nil), "example.com")
}

/// Origin が Host と一致する場合は許可する（同一オリジンのブラウザ接続）。
pub fn origin_header_allowed_matching_origin_is_allowed_test() {
  assert poker_websocket.origin_header_allowed(
    Ok("https://example.com"),
    "example.com",
  )
}

/// ポートが付いていても host 部分だけを比較する。
pub fn origin_header_allowed_matching_origin_with_port_is_allowed_test() {
  assert poker_websocket.origin_header_allowed(
    Ok("http://example.com:4000"),
    "example.com",
  )
}

/// Origin が Host と異なる場合は拒否する（Cross-Site WebSocket Hijacking、#124）。
pub fn origin_header_allowed_mismatched_origin_is_rejected_test() {
  assert !poker_websocket.origin_header_allowed(
    Ok("https://evil.example"),
    "example.com",
  )
}

/// Origin が URI として解釈できない場合も拒否する。
pub fn origin_header_allowed_unparsable_origin_is_rejected_test() {
  assert !poker_websocket.origin_header_allowed(Ok("not a uri"), "example.com")
}

/// 前回の tick 以降にクライアントから何も届いていなければタイムアウトと判定する（#35）。
pub fn heartbeat_outcome_idle_times_out_test() {
  assert poker_websocket.heartbeat_outcome(False)
    == poker_websocket.HeartbeatTimedOut
}

/// 前回の tick 以降にクライアントから何か届いていれば続行と判定する（#35）。
pub fn heartbeat_outcome_active_continues_test() {
  assert poker_websocket.heartbeat_outcome(True)
    == poker_websocket.HeartbeatContinues
}

/// 上限バイト数ちょうどなら受理する（#126）。
pub fn frame_size_outcome_at_the_limit_is_accepted_test() {
  let text = string.repeat("a", 2048)
  assert poker_websocket.frame_size_outcome(text)
    == poker_websocket.FrameSizeAccepted
}

/// 上限を1バイトでも超えたら拒否する（#126）。
pub fn frame_size_outcome_over_the_limit_is_rejected_test() {
  let text = string.repeat("a", 2049)
  assert poker_websocket.frame_size_outcome(text)
    == poker_websocket.FrameTooLarge
}

/// ハートビート窓内のメッセージ数が上限ちょうどなら受理する（#156）。
pub fn message_rate_outcome_at_the_limit_is_accepted_test() {
  assert poker_websocket.message_rate_outcome(30)
    == poker_websocket.MessageRateAccepted
}

/// ハートビート窓内のメッセージ数が上限を1件でも超えたら拒否する（#156）。
pub fn message_rate_outcome_over_the_limit_is_rejected_test() {
  assert poker_websocket.message_rate_outcome(31)
    == poker_websocket.MessageRateLimited
}
