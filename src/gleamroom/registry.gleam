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
  Lookup(id: RoomId, reply_to: Subject(Result(Subject(room.Message), Nil)))
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

/// room を起動する関数と、起動済み room の対応表。
///
/// 起動関数を状態に持つのは**テストのため**（#32）。BEAM のプロセス生成は
/// 資源が尽きない限り成功するので、失敗経路は注入しないと踏めない。
/// 「失敗しても registry がクラッシュしない」ことは型では保証できず、
/// 実際に失敗させて確かめる必要がある。
type State {
  State(
    rooms: Dict(String, Subject(room.Message)),
    start_room: fn() -> actor.StartResult(Subject(room.Message)),
  )
}

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors (ADR
/// 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new(State(rooms: dict.new(), start_room: room.start))
  |> actor.on_message(handle_message)
  |> actor.start
}

/// 起動関数を差し替えて開始する。**テスト専用**（#32）。
///
/// room の起動失敗で registry がクラッシュしないことを検証するために使う。
pub fn start_with_room_starter(
  start_room: fn() -> actor.StartResult(Subject(room.Message)),
) -> actor.StartResult(Subject(Message)) {
  actor.new(State(rooms: dict.new(), start_room:))
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
  actor.new(State(rooms: dict.new(), start_room: room.start))
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
      case dict.get(state.rooms, key) {
        Ok(subject) -> {
          process.send(reply_to, Ok(subject))
          actor.continue(state)
        }
        Error(Nil) ->
          // `let assert` で受けると room 1 つの起動失敗が registry ごと
          // クラッシュさせる（#32）。registry は全ルーム共通の単一プロセスで
          // すべての Lookup を直列に処理するため、無関係な既存ルームの
          // lookup まで巻き添えになる。docs/architecture.md の
          // "One room should be isolated from failures/state in other rooms."
          // に真っ向から反する。
          //
          // 失敗は呼び出し側へ返し、registry は動き続ける。
          case state.start_room() {
            Ok(started) -> {
              let subject = started.data
              process.send(reply_to, Ok(subject))
              actor.continue(
                State(..state, rooms: dict.insert(state.rooms, key, subject)),
              )
            }
            Error(_) -> {
              process.send(reply_to, Error(Nil))
              actor.continue(state)
            }
          }
      }
    }
    Release(id, subject) -> {
      let key = room_id_to_string(id)
      case dict.get(state.rooms, key) {
        // 登録中のものと同一の actor のときだけ対象にする。ABA 問題への対処で、
        // 理由は `Release` のドキュメントコメントを参照。
        Ok(current) if current == subject -> {
          // **空かどうかの判定は room 自身に任せる**（#36）。
          // ここで get_snapshot して空を確かめてから止めると、その隙に
          // join した参加者ごと停止させてしまう。room のメールボックスは
          // 直列なので、自分で見て自分で止めれば隙間が生まれない。
          //
          // Dict から外すのは**実際に停止したときだけ**。停止しなかった room を
          // 外すと、以降の lookup が別の actor を作って参加者が分断される。
          case room.shutdown_if_empty(current) {
            True ->
              actor.continue(
                State(..state, rooms: dict.delete(state.rooms, key)),
              )
            False -> actor.continue(state)
          }
        }
        _ -> actor.continue(state)
      }
    }
  }
}

/// Resolves `id` to its active room actor, lazily starting one if this is
/// the first lookup for that `RoomId`.
pub fn lookup(
  subject: Subject(Message),
  id: RoomId,
) -> Result(Subject(room.Message), Nil) {
  actor.call(subject, waiting: 1000, sending: Lookup(id, _))
}
