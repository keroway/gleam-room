import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/option.{Some}
import gleam/string
import gleam/uri
import mist.{type Connection}

/// アプリ（buzzer / poker）に依存しない WebSocket transport guard 群
/// （duplication-inventory.md 1.5, #588）。`ConnectionState` や room 固有の
/// 型には触れず、ライブな接続なしでユニットテストできる純粋関数と定数だけを
/// 置く。ConnectionState の更新と mist への反映は各 websocket モジュールに残す。
/// tick の間隔であり、かつ検知できる最短のアイドル時間でもある。前回の
/// tick 以降に一度もクライアントからフレームが届かなければ次の tick で
/// 閉じるため、実際に閉じるまでの猶予は 1〜2 回分(30〜60秒)になる。
pub const default_heartbeat_interval_ms = 30_000

/// `Origin` ヘッダを検証する（#124）。Cross-Site WebSocket Hijacking を防ぐため、
/// ブラウザが送る `Origin` はリクエストの `Host` と一致する場合のみ許可する。
///
/// `Origin` ヘッダが無いリクエストは許可する。ブラウザは常に `Origin` を送るが、
/// CLI ツールや自作クライアントのような非ブラウザクライアントは送らないことが
/// あり、MVP は認証を持たないためこれらを区別して弾く根拠が無い（#124 の
/// 未確認事項として残した設計判断）。ここで防ぎたいのは「ブラウザ経由で、
/// 訪問者の意図しないオリジンから接続される」ことに限定する。
pub fn origin_allowed(req: Request(Connection)) -> Bool {
  origin_header_allowed(request.get_header(req, "origin"), req.host)
}

/// `origin_allowed` の本体。`Request(Connection)` に依存しない形へ切り出した
/// のは、ライブな接続なしでユニットテストできるようにするため。
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

/// ハートビート tick 到達時の判定結果。
pub type HeartbeatOutcome {
  /// 前回の tick 以降、クライアントから何も届かなかった。接続を閉じる。
  HeartbeatTimedOut
  /// 生存を確認できた。次回判定に備えて `active_since_heartbeat` をリセットして続行する。
  HeartbeatContinues
}

/// アイドルタイムアウトの判定本体（#35）。
pub fn heartbeat_outcome(active_since_heartbeat: Bool) -> HeartbeatOutcome {
  case active_since_heartbeat {
    False -> HeartbeatTimedOut
    True -> HeartbeatContinues
  }
}

/// The maximum accepted byte size for a single incoming text frame. `join`'s
/// `room_id`/`display_name` are each capped at 64 bytes
/// (`wire.max_field_length`), so a well-formed message never approaches
/// this; it exists to bound the memory/bandwidth a single malicious or
/// misbehaving client can force onto `json.parse` and the subsequent
/// broadcast (#126).
const max_text_frame_bytes = 2048

/// Whether an incoming text frame's byte size is within `max_text_frame_bytes`.
pub type FrameSizeOutcome {
  FrameSizeAccepted
  FrameTooLarge
}

/// Pure and thus testable without a live `WebsocketConnection`, like
/// `heartbeat_outcome` above.
pub fn frame_size_outcome(text: String) -> FrameSizeOutcome {
  frame_size_outcome_for_byte_size(string.byte_size(text))
}

/// `frame_size_outcome`'s byte-size check, shared with the binary-frame path
/// which has no `String` to measure via `string.byte_size` (#500).
pub fn frame_size_outcome_for_byte_size(size: Int) -> FrameSizeOutcome {
  case size > max_text_frame_bytes {
    True -> FrameTooLarge
    False -> FrameSizeAccepted
  }
}

/// The `code`/`message` pair sent when a binary frame arrives.
pub const binary_frame_code_and_message = #(
  "binary_frame",
  "Binary frames are not supported.",
)

/// The `code`/`message` pair sent when `frame_size_outcome` returns
/// `FrameTooLarge`.
pub const frame_too_large_code_and_message = #(
  "frame_too_large",
  "Message exceeds the maximum allowed size.",
)

/// The maximum number of text frames accepted from a single connection
/// within one heartbeat window (`default_heartbeat_interval_ms`, 30s). Bounds
/// how often one connection can force dispatches (and thus mailbox turns) onto
/// the shared room actor; without it a single connection looping frames could
/// starve every other participant in the same room (#156). Reuses the
/// existing heartbeat window as the rate-limit window instead of introducing
/// a dedicated timer or wall-clock read.
const max_messages_per_heartbeat_window = 30

/// Whether a connection has exceeded `max_messages_per_heartbeat_window`
/// text frames within the current heartbeat window.
pub type MessageRateOutcome {
  MessageRateAccepted
  MessageRateLimited
}

/// The `code`/`message` pair sent when `message_rate_outcome` returns
/// `MessageRateLimited`.
pub const rate_limited_code_and_message = #(
  "rate_limited",
  "Too many messages. Please slow down.",
)

/// Pure and thus testable without a live `WebsocketConnection`, like
/// `frame_size_outcome` above. `count_after_this_message` is the message
/// count including the frame currently being evaluated.
pub fn message_rate_outcome(
  count_after_this_message: Int,
) -> MessageRateOutcome {
  case count_after_this_message > max_messages_per_heartbeat_window {
    True -> MessageRateLimited
    False -> MessageRateAccepted
  }
}

/// ログの中で同一 WebSocket 接続の open/close を突き合わせるための識別子。
///
/// クライアントへは出さない内部ログ専用の値なので、接続プロセスの PID を
/// そのまま使ってよい（#28 が禁じているのはワイヤープロトコルへ PID を
/// 漏らすことで、ログはそれとは別の面）。display_name のような個人情報は
/// ここにもライフサイクルログ全体にも含めない。
pub fn connection_tag() -> String {
  "pid=" <> string.inspect(process.self())
}

/// 参加者 ID を生成する。
///
/// 以前は `process.self() |> string.inspect` で **BEAM の PID 文字列表現**
/// (`<0.612.0>` 形式) をそのまま使っており、それが `state` /
/// `participant_joined` / `buzz_accepted` を通じて**全クライアントへ**配信されていた
/// (#28)。実サーバーで `{"id":"//erl(<0.132.0>)"}` を観測している。
///
/// PID を外に出すと次の問題がある:
///
///   - サーバー内部のプロセス構造(採番の連番性・ノード番号)がそのまま漏れる
///   - PID は**プロセス終了後に再利用される**。再接続で別人に同じ ID が
///     割り当たると、前の参加者のブザー結果と混ざる
///   - 公開プロトコルの識別子が実装詳細に固定され、内部を変えられなくなる
///
/// 暗号論的乱数から作った不透明な値にする。16 バイトあれば衝突は実用上
/// 起きない。base64 は URL/JSON でそのまま扱えるよう padding なし。
pub fn new_participant_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base64_url_encode(False)
}
