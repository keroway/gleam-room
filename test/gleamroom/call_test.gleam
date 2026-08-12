import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamroom/call

/// `try_call` は #33 の核心（`actor.call` のタイムアウトで**呼び出し元プロセスが
/// クラッシュする**のを `exception.rescue` で拾い `Error(Nil)` に変える）を担うが、
/// この分岐を踏むテストが無かった（#60）。
///
/// 検証には「応答しないアクター」が要る。実運用の詰まり（GC 停止・メッセージ滞留）は
/// 再現できないので、**受け取っても返信しないアクター**を立てて同じ状況を作る。
type Probe {
  Answer(reply_to: Subject(String))
  Ignore(reply_to: Subject(String))
}

fn start_probe() -> Subject(Probe) {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message) {
      case message {
        Answer(reply_to) -> {
          process.send(reply_to, "pong")
          actor.continue(state)
        }
        // わざと返信しない。呼び出し側はタイムアウトする。
        Ignore(_) -> actor.continue(state)
      }
    })
    |> actor.start
  started.data
}

pub fn try_call_returns_the_reply_when_the_actor_answers_test() {
  let subject = start_probe()

  assert call.try_call(subject, 1000, Answer, "probe") == Ok("pong")
}

/// 応答が無くても **呼び出し元が生き残る**こと。ここが #33 の要点。
pub fn try_call_returns_error_instead_of_crashing_the_caller_test() {
  let subject = start_probe()

  // 素の actor.call ならここで呼び出し元（このテストプロセス）が死ぬ。
  assert call.try_call(subject, 100, Ignore, "probe") == Error(Nil)

  // 生きているので後続の検証ができる。
  assert call.try_call(subject, 1000, Answer, "probe") == Ok("pong")
}

/// 死んだアクターへの呼び出しも Error に変える（クラッシュしない）。
///
/// registry が死んだ room を返す経路（#39 で塞いだが、塞ぎ漏れがあっても
/// 接続プロセスは巻き添えにしない）で効く。
pub fn try_call_returns_error_for_a_dead_actor_test() {
  // **別プロセスから起動する。** `actor.start` は呼び出し元と link するため、
  // テストプロセスから起動した actor を kill するとテスト自体が
  // Exit(Killed) で死ぬ（前サイクルの #69 でも同じ落とし穴を踏んだ）。
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(ready, start_probe())
    process.sleep(3000)
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  let assert Ok(pid) = process.subject_owner(subject)

  process.kill(pid)
  process.sleep(50)

  assert call.try_call(subject, 100, Answer, "probe") == Error(Nil)
}

/// 既定のタイムアウト値が公開されていること。
///
/// 呼び出し側（room / registry）はこれを使う。値そのものより
/// 「1 箇所で決まっている」ことが要点。
pub fn default_timeout_is_exposed_test() {
  assert call.default_timeout == 1000
}
