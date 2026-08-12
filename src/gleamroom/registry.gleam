import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleamroom/call
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
  /// 起動した room actor が落ちたときに届く（#39）。
  ///
  /// room は supervisor の子ではなく registry が直接起動する。
  /// `actor.start` は **link** するため、room がクラッシュすると exit signal が
  /// registry へ伝播し、**registry ごと道連れになる**（監視だけでは防げない。
  /// テストで実際に registry が死に、テストプロセスまで巻き込まれた）。
  ///
  /// registry で `trap_exits` を有効にし、exit を signal ではなく
  /// **メッセージとして**受ける。これで registry は生き延び、死んだ room を
  /// Dict から外せる。放置すると死んだ subject が残り続け、以後その RoomId の
  /// lookup は毎回タイムアウトして再起動まで使用不能になる。
  RoomDown(pid: process.Pid)
  /// registry が生きていて応答することを確かめる（#93）。
  ///
  /// 登録中の room 数を返すが、**値より「返事が来ること」が本体**。
  /// `Lookup` を健全性確認に流用すると room を作ってしまうので、
  /// 副作用の無い読み取り専用の口を分けている。
  Health(reply_to: Subject(Int))
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
    /// 監視中の room actor の pid → RoomId のキー（#39）。
    /// Down メッセージは pid しか運ばないため、逆引きが要る。
    monitored: Dict(process.Pid, String),
    start_room: fn() -> actor.StartResult(Subject(room.Message)),
  )
}

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors (ADR
/// 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  build(State(rooms: dict.new(), monitored: dict.new(), start_room: room.start))
  |> actor.start
}

/// 起動関数を差し替えて開始する。**テスト専用**（#32）。
///
/// room の起動失敗で registry がクラッシュしないことを検証するために使う。
pub fn start_with_room_starter(
  start_room: fn() -> actor.StartResult(Subject(room.Message)),
) -> actor.StartResult(Subject(Message)) {
  build(State(rooms: dict.new(), monitored: dict.new(), start_room:))
  |> actor.start
}

/// monitor の Down メッセージを受け取れる形で actor を組み立てる（#39）。
///
/// `select_monitors` を使うのは、監視対象が動的に増減するため。
/// 個別の monitor を都度 selector へ足す形だと、room が増えるたびに
/// selector を組み直す必要がある。
fn build(initial: State) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_trapped_exits(fn(exit) { RoomDown(exit.pid) })
    // link された room の死を signal ではなくメッセージとして受け取る。
    // これを外すと room のクラッシュが registry を道連れにする。
    process.trap_exits(True)
    actor.initialised(initial)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
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
  build(State(rooms: dict.new(), monitored: dict.new(), start_room: room.start))
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
              // 監視しておかないと、クラッシュした room の subject が
              // Dict に残り続ける（#39）。
              // link は actor.start が張るので、ここでは pid → key の
              // 逆引きだけ持つ。exit メッセージは pid しか運ばないため。
              let monitored = case process.subject_owner(subject) {
                Ok(pid) -> dict.insert(state.monitored, pid, key)
                // 持ち主が引けないのは想定外だが、追跡できないだけで
                // room 自体は使えるので登録は続ける。
                Error(Nil) -> state.monitored
              }
              actor.continue(
                State(
                  ..state,
                  rooms: dict.insert(state.rooms, key, subject),
                  monitored:,
                ),
              )
            }
            Error(_) -> {
              process.send(reply_to, Error(Nil))
              actor.continue(state)
            }
          }
      }
    }
    RoomDown(pid) ->
      case dict.get(state.monitored, pid) {
        // 死んだ room を Dict から外す。残すと以後の lookup が死んだ
        // subject を返し続け、その RoomId は再起動まで使用不能になる。
        Ok(key) ->
          actor.continue(
            State(
              ..state,
              rooms: dict.delete(state.rooms, key),
              monitored: dict.delete(state.monitored, pid),
            ),
          )
        // 既に Release 済みなど、監視表に無い pid は無視する。
        Error(Nil) -> actor.continue(state)
      }
    Health(reply_to) -> {
      // 副作用なし。返事が来ること自体が「registry が詰まっていない」証拠。
      process.send(reply_to, dict.size(state.rooms))
      actor.continue(state)
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
            True -> {
              let monitored = case process.subject_owner(current) {
                Ok(pid) -> dict.delete(state.monitored, pid)
                Error(Nil) -> state.monitored
              }
              actor.continue(
                State(..state, rooms: dict.delete(state.rooms, key), monitored:),
              )
            }
            False -> actor.continue(state)
          }
        }
        _ -> actor.continue(state)
      }
    }
  }
}

/// registry が応答することを確かめ、登録中の room 数を返す（#93）。
///
/// 応答しない場合は `Error(Nil)`。`/health` はこれを見て 503 を返す。
/// **プロセスが死んでいる場合と詰まっている場合の両方**を拾う
/// （`call.try_call` が理由を分類して警告に残す。#70）。
pub fn health(subject: Subject(Message)) -> Result(Int, Nil) {
  call.try_call(subject, call.default_timeout, Health, "registry.health")
}

/// Resolves `id` to its active room actor, lazily starting one if this is
/// the first lookup for that `RoomId`.
///
/// registry が応答しない場合は `Error(Nil)`（#58）。ここだけ生の `actor.call`
/// が残っており、**#33 で room 側を塞いだ穴が registry 側に開いたままだった**。
/// registry の Lookup は room の起動と `shutdown_if_empty` の同期呼び出しを
/// 挟むため詰まりやすく、詰まると WebSocket の接続プロセスが理由不明のまま
/// 落ちる（クライアントには何も届かない）。
///
/// 失敗は 2 段ある。**registry が応答しないこと**（ここで拾う）と、
/// **registry が「room を起動できなかった」と返すこと**（#32 で導入）。
/// 呼び出し側から見ればどちらも「room が得られなかった」なので平坦化するが、
/// 前者は警告ログに残る（`call.try_call` が理由を分類して出す。#70）。
pub fn lookup(
  subject: Subject(Message),
  id: RoomId,
) -> Result(Subject(room.Message), Nil) {
  call.try_call(subject, call.default_timeout, Lookup(id, _), "registry.lookup")
  |> result.flatten
}
