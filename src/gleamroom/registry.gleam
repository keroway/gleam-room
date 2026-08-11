import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamroom/room

/// Opaque so callers cannot construct a `RoomId` except through `room_id`,
/// keeping lookups keyed on a single explicit constructor.
pub opaque type RoomId {
  RoomId(String)
}

pub fn room_id(value: String) -> RoomId {
  RoomId(value)
}

fn room_id_to_string(id: RoomId) -> String {
  let RoomId(value) = id
  value
}

pub type Message {
  Lookup(id: RoomId, reply_to: Subject(Subject(room.Message)))
  /// 最後の参加者が抜けた room を登録から外す（#26）。
  ///
  /// `subject` を一緒に受け取り、**登録中のものと一致するときだけ削除する**。
  /// 一致を見ないと、次のような取り違えが起きる:
  ///
  ///   1. room "ABCD" が空になり Release を送る
  ///   2. 届く前に別の参加者が同じ ID で `lookup` し、新しい actor が登録される
  ///   3. 遅れて届いた Release が、**その新しい actor** を消してしまう
  ///
  /// 消えたことは誰にも通知されないため、参加者は自分だけの room に閉じ込められる。
  Release(id: RoomId, subject: Subject(room.Message))
}

type State =
  Dict(String, Subject(room.Message))

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors (ADR
/// 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.start
}

/// 名前付きで起動する（#23）。
///
/// supervisor 配下では registry が再起動すると **subject が変わる**。
/// HTTP ハンドラが起動時の subject を握っていると、再起動後は死んだ
/// プロセスへ送り続けることになる（送信自体はエラーにならないため、
/// 「join しても何も起きない」という形でしか現れない）。
///
/// 名前を経由すれば、呼び出し側は `process.named_subject(name)` で
/// 常に現行のプロセスへ届く。
pub fn start_named(
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Lookup(id, reply_to) -> {
      let key = room_id_to_string(id)
      case dict.get(state, key) {
        Ok(subject) -> {
          process.send(reply_to, subject)
          actor.continue(state)
        }
        Error(Nil) -> {
          let assert Ok(started) = room.start()
          let subject = started.data
          process.send(reply_to, subject)
          actor.continue(dict.insert(state, key, subject))
        }
      }
    }
    Release(id, subject) -> {
      let key = room_id_to_string(id)
      case dict.get(state, key) {
        // 登録中のものと同一の actor のときだけ外す。ABA 問題への対処で、
        // 理由は `Release` のドキュメントコメントを参照。
        Ok(current) if current == subject -> {
          // Dict から外すだけでは actor プロセスが残る。エントリは消えても
          // BEAM プロセスは生き続けるため、両方やって初めてリークが塞がる。
          process.send(current, room.Shutdown)
          actor.continue(dict.delete(state, key))
        }
        _ -> actor.continue(state)
      }
    }
  }
}

/// Resolves `id` to its active room actor, lazily starting one if this is
/// the first lookup for that `RoomId`.
pub fn lookup(subject: Subject(Message), id: RoomId) -> Subject(room.Message) {
  actor.call(subject, waiting: 1000, sending: Lookup(id, _))
}
