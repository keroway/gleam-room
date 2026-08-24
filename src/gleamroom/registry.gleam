import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleamroom/call
import gleamroom/room
import logging

/// Opaque so callers cannot construct a `RoomId` except through `room_id`,
/// keeping lookups keyed on a single explicit constructor.
pub opaque type RoomId {
  RoomId(String)
}

pub fn room_id(value: String) -> RoomId {
  RoomId(value)
}

/// websocket.gleam のライフサイクルログ（#25）が RoomId の中身を文字列化するのに使う。
pub fn room_id_to_string(id: RoomId) -> String {
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
  ///
  /// registry 自体の応答性だけでは、個々の room actor がハング/デッドロック
  /// していても検知できない（#138）。`stuck` には**前回の probe の結果**を
  /// 即座に返し、応答後に今の登録済み room 全件へ非同期の probe
  /// （`room.get_snapshot`）を仕掛けて次回の `Health` 用に更新する。
  /// registry のメールボックスを塞がないよう、probe 自体は
  /// `spawn_unlinked` した別プロセスから行う（`Release` と同じ方針）。
  Health(reply_to: Subject(HealthSnapshot))
  /// room 1 件分の probe（`room.get_snapshot`）の結果（#138）。
  ///
  /// `ok` が `False` なのはタイムアウトまたは応答不能（詰まっている/死んで
  /// いる）。死んだ room は別途 `RoomDown` で `rooms` から外れるので、
  /// ここでの `stuck_rooms` への追加は一時的（次の probe で消えるか、
  /// `RoomDown` で `rooms` ごと存在しなくなる）。
  RoomProbed(key: String, ok: Bool)
  /// `trap_exits(True)` はリンクされた**全て**の相手からの exit を拾うため、
  /// registry を起動した supervisor が shutdown で子を畳もうとした exit
  /// （reason: `shutdown`）も room のクラッシュと区別なく届いてしまう（#117）。
  ///
  /// これを `RoomDown` として無視すると、registry は shutdown 要求に一切
  /// 応答せず生き続け、supervisor は既定の shutdown タイムアウト（5秒）を
  /// 使い切ってから brutal kill するしかなくなる。reason が `shutdown` の
  /// 場合だけこの別メッセージにして、即座に `actor.stop()` する。
  ParentShutdown
  /// `Release` が投げた空判定（`room.shutdown_if_empty`）の結果（#71）。
  ///
  /// 判定自体は registry のメールボックスの外（別プロセス）で待ち、結果だけを
  /// メッセージとして返す。`Release` ハンドラで同期的に待つと、詰まった
  /// room 1 つのせいで registry 全体が最大 1 秒ブロックされ、無関係な他の
  /// room への `Lookup`/`Release` まで巻き添えで遅延する。
  RoomEmptyChecked(id: RoomId, subject: Subject(room.Message), empty: Bool)
}

/// `Health` の返答（#138）。`rooms` は登録数、`stuck` は前回の probe で
/// 応答が無かった room の数（前回 probe が無ければ 0）。
pub type HealthSnapshot {
  HealthSnapshot(rooms: Int, stuck: Int)
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
    /// 監視中の room actor の pid → 登録時の room 情報（#39）。
    /// Down メッセージは pid しか運ばないため、逆引きが要る。key だけでなく
    /// subject も保持し、遅れて届いた古い Down が同じ key の新しい room を
    /// 削除しないようにする（#160）。
    monitored: Dict(process.Pid, MonitoredRoom),
    start_room: fn() -> actor.StartResult(Subject(room.Message)),
    /// 新規 room actor（BEAMプロセス）を起動できる上限（#127）。
    /// 未知の room_id へ join するたびに無条件で起動すると、単一クライアントが
    /// room_id を変え続けるだけで無制限にプロセスを増やせてしまう。
    max_rooms: Int,
    /// registry 自身の subject（#71）。`Release` が空判定を別プロセスへ
    /// 投げるとき、結果（`RoomEmptyChecked`）の返送先として渡す。
    self: Subject(Message),
    /// 直近の `Health` probe で応答が無かった room の key（#138）。
    /// `Health` を受けるたびに全 room へ probe を再実行し置き換える
    /// 「前回の結果」であり、リアルタイムの状態ではない。
    stuck_rooms: Set(String),
    /// 前回発火した probe のうち、まだ `RoomProbed` が返っていない件数
    /// （#269）。`/health` は認証なしで公開されており、連打されるたびに
    /// 登録 room 全件へ probe を仕掛け直すと、直前の probe 群が結果を
    /// 返し終える前に次の probe 群が重ねて発火し、room actor のメールボックスが
    /// 際限なく積み上がる。0 のときだけ新しい probe 群を発火し、全件の
    /// `RoomProbed` が揃うまで次の `Health` では発火を見送るガードに使う。
    probe_in_flight: Int,
  )
}

/// `max_rooms` の既定値。運用上の実測に基づく値ではなく、単一プロセスが
/// 無制限に増えることを防ぐための保守的な上限（#127）。
const default_max_rooms = 1000

type MonitoredRoom {
  MonitoredRoom(key: String, subject: Subject(room.Message))
}

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors (ADR
/// 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  build(room.start, default_max_rooms)
  |> actor.start
}

/// 起動関数を差し替えて開始する。**テスト専用**（#32）。
///
/// room の起動失敗で registry がクラッシュしないことを検証するために使う。
pub fn start_with_room_starter(
  start_room: fn() -> actor.StartResult(Subject(room.Message)),
) -> actor.StartResult(Subject(Message)) {
  build(start_room, default_max_rooms)
  |> actor.start
}

/// room数の上限を差し替えて開始する。**テスト専用**（#127）。
///
/// 既定値（1000）まで実際に room を起動して上限到達を確かめるのは非現実的な
/// ため、テストから小さい上限を注入できるようにする。
pub fn start_with_max_rooms(
  max_rooms: Int,
) -> actor.StartResult(Subject(Message)) {
  build(room.start, max_rooms)
  |> actor.start
}

/// trapped exit を `RoomDown`（room のクラッシュ）と `ParentShutdown`
/// （親からの shutdown 要求）に振り分ける（#117）。
///
/// reason が `Abnormal` にラップされた atom `shutdown` のときだけ
/// `ParentShutdown` とみなす。room のクラッシュ理由は通常タプル
/// （`{badmatch, ...}` 等）で atom ではないため、`decode.run` で
/// atom へのデコードに失敗し `RoomDown` 側に安全に落ちる。
fn exit_to_message(exit: process.ExitMessage) -> Message {
  let shutdown = atom.create("shutdown")
  case exit.reason {
    process.Abnormal(reason) ->
      case decode.run(reason, atom.decoder()) {
        Ok(reason_atom) if reason_atom == shutdown -> ParentShutdown
        _ -> RoomDown(exit.pid)
      }
    process.Normal | process.Killed -> RoomDown(exit.pid)
  }
}

/// room の死を Down メッセージとして受け取れる形で actor を組み立てる（#39）。
///
/// `trap_exits(True)` + `select_trapped_exits` を使うのは、room の起動時に
/// 既存の link（`actor.start`）をそのまま使って死を検知できるため。room が
/// 増減するたびに個別の monitor を selector へ足し引きする必要がない
/// （ADR 0007）。
fn build(
  start_room: fn() -> actor.StartResult(Subject(room.Message)),
  max_rooms: Int,
) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_trapped_exits(exit_to_message)
    // link された room の死を signal ではなくメッセージとして受け取る。
    // これを外すと room のクラッシュが registry を道連れにする。
    process.trap_exits(True)
    let initial =
      State(
        rooms: dict.new(),
        monitored: dict.new(),
        start_room:,
        max_rooms:,
        // `subject` は初期化中の自分自身の subject（#71）。ここでしか
        // 手に入らないため、`State` へ持たせるのは `build` の中に限る。
        self: subject,
        stuck_rooms: set.new(),
        probe_in_flight: 0,
      )
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
  build(room.start, default_max_rooms)
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
      let room_count = dict.size(state.rooms)
      case dict.get(state.rooms, key) {
        Ok(subject) -> {
          process.send(reply_to, Ok(subject))
          actor.continue(state)
        }
        Error(Nil) if room_count >= state.max_rooms -> {
          // room 数の上限に達している（#127）。単一クライアントが room_id を
          // 変え続けるだけで BEAM プロセスを無制限に起動できてしまうのを防ぐ。
          // 既存 room の lookup はここを通らない（上の Ok 分岐で先に処理済み）。
          logging.log(
            logging.Warning,
            "room capacity reached, rejecting lookup: id="
              <> key
              <> ", rooms="
              <> string.inspect(room_count)
              <> ", max_rooms="
              <> string.inspect(state.max_rooms),
          )
          process.send(reply_to, Error(Nil))
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
              logging.log(logging.Info, "room created: id=" <> key)
              let subject = started.data
              process.send(reply_to, Ok(subject))
              // 監視しておかないと、クラッシュした room の subject が
              // Dict に残り続ける（#39）。
              // link は actor.start が張るので、ここでは pid → 登録時の
              // subject の逆引きを持つ。exit メッセージは pid しか運ばないため。
              let monitored = case process.subject_owner(subject) {
                Ok(pid) ->
                  dict.insert(
                    state.monitored,
                    pid,
                    MonitoredRoom(key:, subject:),
                  )
                // 持ち主が引けないのは想定外だが、追跡できないだけで
                // room 自体は使える。未登録のため #39 の RoomDown 逆引きが
                // 効かなくなるので、後から追えるようにログだけは残す。
                Error(Nil) -> {
                  logging.log(
                    logging.Warning,
                    "subject_owner failed for started room, room not monitored: id="
                      <> key,
                  )
                  state.monitored
                }
              }
              actor.continue(
                State(
                  ..state,
                  rooms: dict.insert(state.rooms, key, subject),
                  monitored:,
                ),
              )
            }
            Error(reason) -> {
              logging.log(
                logging.Warning,
                "room failed to start: id="
                  <> key
                  <> ", reason="
                  <> string.inspect(reason),
              )
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
        Ok(MonitoredRoom(key, subject)) -> {
          logging.log(logging.Warning, "room crashed: id=" <> key)
          let rooms = case dict.get(state.rooms, key) {
            // Release 後の subject_owner 失敗により古い監視記録だけが残り、
            // 同じ key に新しい room が登録済みでも、古い Down では消さない。
            Ok(current) if current == subject -> dict.delete(state.rooms, key)
            _ -> state.rooms
          }
          actor.continue(
            State(..state, rooms:, monitored: dict.delete(state.monitored, pid)),
          )
        }
        // 既に Release 済みなど、監視表に無い pid は無視する。
        Error(Nil) -> actor.continue(state)
      }
    Health(reply_to) -> {
      // 返事が来ること自体が「registry が詰まっていない」証拠。
      // `stuck` は前回の probe 結果を即座に返し、待たせない（#138）。
      process.send(
        reply_to,
        HealthSnapshot(
          rooms: dict.size(state.rooms),
          stuck: set.size(state.stuck_rooms),
        ),
      )
      // 次回の `Health` 用に、今の登録済み room 全件へ非同期で probe を
      // 仕掛け直す。registry のメールボックスをブロックしないよう、probe
      // 自体は `spawn_unlinked` した別プロセスで行い、結果だけ
      // `RoomProbed` として返してもらう（`Release` と同じ方針）。
      //
      // 前回の probe 群がまだ全件返り終えていなければ発火を見送る（#269）。
      // `/health` の連打で room actor のメールボックスへ probe が
      // 際限なく積み上がるのを防ぐ。
      case state.probe_in_flight {
        0 -> {
          dict.each(state.rooms, fn(key, subject) {
            process.spawn_unlinked(fn() {
              let ok = case room.get_snapshot(subject) {
                Ok(_) -> True
                Error(Nil) -> False
              }
              process.send(state.self, RoomProbed(key, ok))
            })
          })
          actor.continue(
            State(..state, probe_in_flight: dict.size(state.rooms)),
          )
        }
        _ -> actor.continue(state)
      }
    }
    RoomProbed(key, ok) -> {
      let stuck_rooms = case ok {
        True -> set.delete(state.stuck_rooms, key)
        False -> set.insert(state.stuck_rooms, key)
      }
      // 0 未満にはならない: probe_in_flight は発火時に room 数で設定され、
      // 各発火につき `RoomProbed` はちょうど1回だけ返る。
      let probe_in_flight = int.max(0, state.probe_in_flight - 1)
      actor.continue(State(..state, stuck_rooms:, probe_in_flight:))
    }
    ParentShutdown -> {
      // 親（supervisor）からの shutdown 要求。無視して生き続けると
      // supervisor は既定の shutdown タイムアウト（5秒）を待ってから
      // brutal kill するしかない（#117）。即座に止まって応答する。
      actor.stop()
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
          // 判定 (`room.shutdown_if_empty`) はここで同期的に待たない（#71）。
          // registry のメールボックス内で待つと、詰まった room 1 つが
          // 無関係な他 room への Lookup/Release まで最大 1 秒巻き込んで
          // 止める。判定は使い捨ての別プロセスに投げ、結果だけを
          // `RoomEmptyChecked` として非同期に受け取る。
          //
          // registry がこの結果を待つ間に他 room の Lookup を処理できる
          // のがねらいだが、同じ room id への同時 Lookup がこの短い窓の間に
          // 割り込むと、間もなく停止する room の subject を一瞬だけ
          // 返しうる（その場合は再送で room_unavailable エラーになる程度の
          // 影響に留まる）。
          process.spawn_unlinked(fn() {
            let empty = room.shutdown_if_empty(current)
            process.send(state.self, RoomEmptyChecked(id, current, empty))
          })
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    }
    RoomEmptyChecked(id, subject, empty) -> {
      let key = room_id_to_string(id)
      case empty, dict.get(state.rooms, key) {
        // 判定結果を待つ間に別の actor が同じ key で登録し直されていないか、
        // `Release` と同じガードで確かめる（#160 と同じ ABA 対処）。
        True, Ok(current) if current == subject -> {
          logging.log(logging.Info, "room closed (empty): id=" <> key)
          // subject_owner がまだ引ける場合だけ、その pid の記録を直接消す。
          // subject も一致を確かめるので、pid が再利用されても別 room の監視を
          // 消さない。既に終了して owner を引けない場合は、後続の RoomDown が
          // 古い記録を消す。その際も subject 一致ガードが新しい room を守る
          // （#160）。
          let monitored = case process.subject_owner(subject) {
            Ok(pid) ->
              case dict.get(state.monitored, pid) {
                Ok(MonitoredRoom(subject: monitored_subject, ..))
                  if monitored_subject == subject
                -> dict.delete(state.monitored, pid)
                _ -> state.monitored
              }
            Error(Nil) -> state.monitored
          }
          actor.continue(
            State(..state, rooms: dict.delete(state.rooms, key), monitored:),
          )
        }
        _, _ -> actor.continue(state)
      }
    }
  }
}

/// registry が応答することを確かめ、登録中の room 数と、直近の probe で
/// 応答が無かった room の数を返す（#93, #138）。
///
/// 応答しない場合は失敗理由を返す。`/health` はこれを見て 503 の本文を
/// 「落ちている」「詰まっている」で書き分ける（#92）。
///
/// 運用上の対処が違うため区別する。死んでいるなら supervisor の再起動を
/// 待つか調べる、詰まっているなら負荷やタイムアウト値を見る。`stuck` は
/// 個々の room actor 側の詰まりを指し、registry 自体の生死とは別軸
/// （#138）。
pub fn health(
  subject: Subject(Message),
) -> Result(HealthSnapshot, call.Failure) {
  call.try_call_classified(
    subject,
    call.default_timeout,
    Health,
    "registry.health",
  )
}

/// Resolves `id` to its active room actor, lazily starting one if this is
/// the first lookup for that `RoomId`.
///
/// registry が応答しない場合は `Error(Nil)`（#58）。ここだけ生の `actor.call`
/// が残っており、**#33 で room 側を塞いだ穴が registry 側に開いたままだった**。
/// registry の Lookup は room の起動を挟むため詰まりやすく（`Release` の
/// 空判定はもう registry のメールボックスをブロックしない、#71）、詰まると
/// WebSocket の接続プロセスが理由不明のまま落ちる（クライアントには何も
/// 届かない）。
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
