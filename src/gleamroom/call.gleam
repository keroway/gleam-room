import exception
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/string
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
  try_call_classified(subject, timeout, make_request, label)
  |> result.replace_error(Nil)
}

/// `try_call` と同じだが、**失敗理由を呼び出し元へ渡す**（#92）。
///
/// 既定は `try_call` のまま。理由を受け取っても対処が変わらない呼び出し元
/// （room / registry の大半）にまで `Failure` を配ると、全員が
/// 「使わない値」を捨てる記述を書くことになる。
///
/// 使うのは **区別が実際に外へ出る場所**だけ。今のところ `/health` で、
/// 「registry が落ちている」と「registry が詰まっている」を運用者に
/// 分けて伝えるために使っている。
pub fn try_call_classified(
  subject: Subject(message),
  timeout: Int,
  make_request: fn(Subject(reply)) -> message,
  label: String,
) -> Result(reply, Failure) {
  case exception.rescue(fn() { actor.call(subject, timeout, make_request) }) {
    Ok(reply) -> Ok(reply)
    Error(reason) -> {
      logging.log(logging.Warning, describe_failure(label, timeout, reason))
      Error(classify(reason))
    }
  }
}

/// 呼び出しが失敗した理由（#70）。
///
/// **どこで消費されるか**: 常に警告ログの文言（`describe_failure`）。加えて
/// `try_call_classified` を使う呼び出し元は値として受け取れる（#92）。
/// 現在の利用者は `/health` だけで、運用者に「落ちている」と「詰まっている」を
/// 分けて伝えるために使っている。
///
/// 呼び出し側から見た結果はどれも「返事が得られなかった」で同じだが、
/// **運用上の対処はまるで違う**。詰まっているならタイムアウトの見直しや
/// 負荷の調査、死んでいるなら再起動や登録の掃除になる。
pub type Failure {
  /// 相手は生きているが時間内に返信しなかった。
  Timeout
  /// 相手のプロセスが既に死んでいる。
  ActorDown
  /// どちらとも判定できなかった。**原因を断定せず**例外の内容をそのまま運ぶ。
  Unknown(detail: String)
}

/// `exception.rescue` が返した例外を `Failure` に分類する（#70）。
///
/// `gleam_erlang` の `process.call` は失敗時に `let assert` で落ちるため、
/// 例外の中身に理由の文字列が入る。実測した形:
///
///   - タイムアウト: `Message: "callee did not send reply before timeout"`
///   - 相手が死亡:   `Message: "callee exited: ProcessDown(...)"`
///   - 相手が named subject 経由で既に死んでいる（呼び出し開始時点で
///     名前解決テーブルに載っていない）:
///     `Message: "Callee subject had no owner"`（#115）。`perform_call` は
///     `subject_owner` を呼び出しの最初に `let assert` しており、
///     `"callee exited"` を経由しないためこの分岐が別に必要。
///
/// 文字列一致は依存先の文言変更で壊れうるので、**外れたら `Timeout` に
/// 倒さず `Unknown` にする**。誤った断定より、生の情報を渡すほうが調査に効く。
pub fn classify(reason: exception.Exception) -> Failure {
  let detail = string.inspect(reason)
  case string.contains(detail, "did not send reply before timeout") {
    True -> Timeout
    False ->
      case
        string.contains(detail, "callee exited")
        || string.contains(detail, "Callee subject had no owner")
      {
        True -> ActorDown
        False -> Unknown(detail)
      }
  }
}

/// 失敗理由を人が読める形にする（#70）。
///
/// 以前はどの失敗も「N ms 以内に応答しませんでした」と報告していたが、
/// **アクターが死んでいる場合と詰まっている場合では対処がまるで違う**。
/// 死んでいるなら再起動や登録の掃除、詰まっているならタイムアウトの見直しや
/// 負荷の調査になる。同じ文言だと切り分けができない。
///
/// `gleam_erlang` の `process.call` は失敗時に `let assert` で落ちるため、
/// 例外の中身に理由の文字列が入る。実測した形:
///
///   - タイムアウト: `Message: "callee did not send reply before timeout"`
///   - 相手が死亡:   `Message: "callee exited: ProcessDown(...)"`
///
/// 文字列一致に頼るのは脆いので、**どちらとも判定できない場合は原因を
/// 断定せず、例外の内容をそのまま出す**。断定して誤った案内をするより、
/// 生の情報を渡すほうが調査の役に立つ。
fn describe_failure(
  label: String,
  timeout: Int,
  reason: exception.Exception,
) -> String {
  case classify(reason) {
    Timeout ->
      label
      <> ": アクターが "
      <> int.to_string(timeout)
      <> "ms 以内に応答しませんでした。呼び出しを諦めます。"
    ActorDown -> label <> ": アクターが停止しているため呼び出せませんでした。"
    Unknown(detail) -> label <> ": 呼び出しに失敗しました: " <> detail
  }
}
