import gleam/string
import gleamroom/ws_guard

/// Origin ヘッダが無い接続は許可する（非ブラウザクライアントを想定、#124）。
pub fn origin_header_allowed_missing_origin_is_allowed_test() {
  assert ws_guard.origin_header_allowed(Error(Nil), "example.com")
}

/// Origin が Host と一致する場合は許可する（同一オリジンのブラウザ接続）。
pub fn origin_header_allowed_matching_origin_is_allowed_test() {
  assert ws_guard.origin_header_allowed(
    Ok("https://example.com"),
    "example.com",
  )
}

/// ポートが付いていても host 部分だけを比較する。
pub fn origin_header_allowed_matching_origin_with_port_is_allowed_test() {
  assert ws_guard.origin_header_allowed(
    Ok("http://example.com:4000"),
    "example.com",
  )
}

/// Origin が Host と異なる場合は拒否する（Cross-Site WebSocket Hijacking、#124）。
pub fn origin_header_allowed_mismatched_origin_is_rejected_test() {
  assert !ws_guard.origin_header_allowed(
    Ok("https://evil.example"),
    "example.com",
  )
}

/// Origin が URI として解釈できない場合も拒否する。
pub fn origin_header_allowed_unparsable_origin_is_rejected_test() {
  assert !ws_guard.origin_header_allowed(Ok("not a uri"), "example.com")
}

/// 前回の tick 以降にクライアントから何も届いていなければタイムアウトと判定する（#35）。
pub fn heartbeat_outcome_idle_times_out_test() {
  assert ws_guard.heartbeat_outcome(False) == ws_guard.HeartbeatTimedOut
}

/// 前回の tick 以降にクライアントから何か届いていれば続行と判定する（#35）。
pub fn heartbeat_outcome_active_continues_test() {
  assert ws_guard.heartbeat_outcome(True) == ws_guard.HeartbeatContinues
}

/// 上限バイト数ちょうどなら受理する（#126）。
pub fn frame_size_outcome_at_the_limit_is_accepted_test() {
  let text = string.repeat("a", 2048)
  assert ws_guard.frame_size_outcome(text) == ws_guard.FrameSizeAccepted
}

/// 上限を1バイトでも超えたら拒否する（#126）。
pub fn frame_size_outcome_over_the_limit_is_rejected_test() {
  let text = string.repeat("a", 2049)
  assert ws_guard.frame_size_outcome(text) == ws_guard.FrameTooLarge
}

/// ハートビート窓内のメッセージ数が上限ちょうどなら受理する（#156）。
pub fn message_rate_outcome_at_the_limit_is_accepted_test() {
  assert ws_guard.message_rate_outcome(30) == ws_guard.MessageRateAccepted
}

/// ハートビート窓内のメッセージ数が上限を1件でも超えたら拒否する（#156）。
pub fn message_rate_outcome_over_the_limit_is_rejected_test() {
  assert ws_guard.message_rate_outcome(31) == ws_guard.MessageRateLimited
}

pub fn binary_frame_code_and_message_test() {
  assert ws_guard.binary_frame_code_and_message
    == #("binary_frame", "Binary frames are not supported.")
}

pub fn rate_limited_code_and_message_test() {
  assert ws_guard.rate_limited_code_and_message
    == #("rate_limited", "Too many messages. Please slow down.")
}

pub fn frame_too_large_code_and_message_test() {
  assert ws_guard.frame_too_large_code_and_message
    == #("frame_too_large", "Message exceeds the maximum allowed size.")
}
