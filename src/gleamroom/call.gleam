import exception
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import logging

/// アクターへの同期呼び出しの既定タイムアウト（ミリ秒）。
pub const default_timeout = 1000

/// `actor.call` をタイムアウトで**クラッシュさせずに**行う（#33）。
///
/// `actor.call` の実体である `process.call` は、応答が間に合わないと
/// **呼び出し元プロセスをクラッシュさせる**（gleam_erlang のドキュメントに
/// 明記されている）。WebSocket の接続プロセスがそのまま呼んでいたため、
/// room actor が GC 停止やメッセージ滞留で 1 秒応答できないだけで、
/// 接続が無言で落ちていた。クライアントには理由が届かず、ログにも残らない。
///
/// ここで拾って `Error(Nil)` に変え、呼び出し側がクライアントへ返すなり
/// 諦めるなりを選べるようにする。落ちた事実は警告として残す
/// （docs/mvp.md が求める「接続とルームのライフサイクルが追える」ログ）。
pub fn try_call(
  subject: Subject(message),
  timeout: Int,
  make_request: fn(Subject(reply)) -> message,
  label: String,
) -> Result(reply, Nil) {
  case exception.rescue(fn() { actor.call(subject, timeout, make_request) }) {
    Ok(reply) -> Ok(reply)
    Error(_) -> {
      logging.log(
        logging.Warning,
        label
          <> ": アクターが "
          <> int.to_string(timeout)
          <> "ms 以内に応答しませんでした。呼び出しを諦めます。",
      )
      Error(Nil)
    }
  }
}
