//// `registry.gleam`（buzzer）と `poker_registry.gleam` が共有する registry 層の
//// 土台（#586, ADR 0009 の revisit 条件を満たした 1.1 節の抽出）。
////
//// room の message 型 `m` に対して generic で、room 固有の処理（起動関数・
//// 空判定・probe）は呼び出し側が関数値として渡す。registry actor の `Message`
//// 型は各アプリが持ち続ける（`Lookup`/`Release` などの返信型が room 型に
//// 依存するため）。ここが持つのは、dict と monitored 表の更新規則（ABA 対処を
//// 含む）と、trapped exit の分類。

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/string
import logging

/// Opaque so callers cannot construct a `RoomId` except through `room_id`,
/// keeping lookups keyed on a single explicit constructor.
pub opaque type RoomId {
  RoomId(String)
}

pub fn room_id(value: String) -> RoomId {
  RoomId(value)
}

/// websocket のライフサイクルログ（#25）が RoomId の中身を文字列化するのに使う。
pub fn room_id_to_string(id: RoomId) -> String {
  let RoomId(value) = id
  value
}

/// `lookup` が room を返せなかった理由（#569）。
///
/// クライアントへの案内が逆になるので区別する: `CapacityReached` は他の room が
/// 終了するまで再試行しても直らず、`Unavailable` は一時的でありうる。
pub type LookupError {
  /// `max_rooms` に達しており、新しい room を作れない（#127）。
  CapacityReached
  /// room actor の起動失敗、または registry が応答しなかった。
  Unavailable
}

/// trapped exit の分類結果（#117）。各 registry が自分の `Message` へ写す。
pub type ExitKind {
  /// room のクラッシュ（または通常終了・kill）。
  RoomExited(pid: process.Pid)
  /// 親（supervisor）からの shutdown 要求。
  ParentShutdownRequested
}

/// 監視中の room actor の pid → 登録時の room 情報（#39）。
/// Down メッセージは pid しか運ばないため逆引きが要る。key だけでなく subject も
/// 保持し、遅れて届いた古い Down が同じ key の新しい room を削除しないように
/// する（#160）。
pub type MonitoredRoom(m) {
  MonitoredRoom(key: String, subject: Subject(m))
}

/// registry の room 管理状態。registry 自身の subject（#71）は message 型が
/// アプリごとに違うため、各 registry の `State` 側が持つ。
pub type Core(m) {
  Core(
    rooms: Dict(String, Subject(m)),
    monitored: Dict(process.Pid, MonitoredRoom(m)),
    start_room: fn() -> actor.StartResult(Subject(m)),
    /// 新規 room actor（BEAMプロセス）を起動できる上限（#127）。
    max_rooms: Int,
    /// 直近の `Health` probe で応答が無かった room の key（#138）。
    stuck_rooms: Set(String),
    /// 前回発火した probe のうち、まだ結果が返っていない件数（#269）。
    probe_in_flight: Int,
  )
}

pub fn new(
  start_room: fn() -> actor.StartResult(Subject(m)),
  max_rooms: Int,
) -> Core(m) {
  Core(
    rooms: dict.new(),
    monitored: dict.new(),
    start_room:,
    max_rooms:,
    stuck_rooms: set.new(),
    probe_in_flight: 0,
  )
}

/// trapped exit を room のクラッシュと親からの shutdown 要求に振り分ける（#117）。
///
/// reason が `Abnormal` にラップされた atom `shutdown` のときだけ shutdown
/// 要求とみなす。room のクラッシュ理由は通常タプル（`{badmatch, ...}` 等）で
/// atom ではないため、`decode.run` が失敗して `RoomExited` 側に安全に落ちる。
pub fn classify_exit(exit: process.ExitMessage) -> ExitKind {
  let shutdown = atom.create("shutdown")
  case exit.reason {
    process.Abnormal(reason) ->
      case decode.run(reason, atom.decoder()) {
        Ok(reason_atom) if reason_atom == shutdown -> ParentShutdownRequested
        _ -> RoomExited(exit.pid)
      }
    process.Normal | process.Killed -> RoomExited(exit.pid)
  }
}

/// actor の初期化の共通部分（#39, ADR 0007）。`trap_exits(True)` により link
/// された room の死を signal ではなくメッセージとして受け取る。これを外すと
/// room のクラッシュが registry を道連れにする。
pub fn build(
  core: Core(m),
  to_message: fn(ExitKind) -> message,
  handle_message: fn(state, message) -> actor.Next(state, message),
  make_state: fn(Core(m), Subject(message)) -> state,
) -> actor.Builder(state, message, Subject(message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_trapped_exits(fn(exit) {
        to_message(classify_exit(exit))
      })
    process.trap_exits(True)
    actor.initialised(make_state(core, subject))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
}

/// `Lookup` の処理。`label` はログの room 種別（`"room"` / `"poker room"`）。
/// 返信すべき結果と更新後の `Core` を返す。
pub fn lookup(
  core: Core(m),
  key: String,
  label: String,
) -> #(Result(Subject(m), LookupError), Core(m)) {
  let room_count = dict.size(core.rooms)
  case dict.get(core.rooms, key) {
    Ok(subject) -> #(Ok(subject), core)
    Error(Nil) if room_count >= core.max_rooms -> {
      // room 数の上限に達している（#127）。単一クライアントが room_id を
      // 変え続けるだけで BEAM プロセスを無制限に起動できてしまうのを防ぐ。
      // 既存 room の lookup はここを通らない（上の Ok 分岐で先に処理済み）。
      logging.log(
        logging.Warning,
        label
          <> " capacity reached, rejecting lookup: id="
          <> key
          <> ", rooms="
          <> string.inspect(room_count)
          <> ", max_rooms="
          <> string.inspect(core.max_rooms),
      )
      #(Error(CapacityReached), core)
    }
    // `let assert` で受けると room 1 つの起動失敗が registry ごとクラッシュ
    // させる（#32）。registry は全ルーム共通の単一プロセスで、無関係な既存
    // ルームの lookup まで巻き添えになる。失敗は呼び出し側へ返し、registry は
    // 動き続ける。
    Error(Nil) ->
      case core.start_room() {
        Ok(started) -> {
          let subject = started.data
          // subject_owner が引けない場合、room を登録すると監視表に載らない
          // ままクラッシュしたときに RoomDown で回収できず、その room_id が
          // 永久に使用不能になる（#467）。想定外の事態（BEAM の実装上通常は
          // 起きない）なので、追跡できない room は起動失敗として扱い registry
          // には一切残さない。
          case process.subject_owner(subject) {
            Ok(pid) -> {
              logging.log(logging.Info, label <> " created: id=" <> key)
              #(
                Ok(subject),
                Core(
                  ..core,
                  rooms: dict.insert(core.rooms, key, subject),
                  monitored: dict.insert(
                    core.monitored,
                    pid,
                    MonitoredRoom(key:, subject:),
                  ),
                ),
              )
            }
            Error(Nil) -> {
              logging.log(
                logging.Warning,
                "subject_owner failed for started "
                  <> label
                  <> ", treating as start failure: id="
                  <> key,
              )
              #(Error(Unavailable), core)
            }
          }
        }
        Error(reason) -> {
          logging.log(
            logging.Warning,
            label
              <> " failed to start: id="
              <> key
              <> ", reason="
              <> string.inspect(reason),
          )
          #(Error(Unavailable), core)
        }
      }
  }
}

/// `RoomDown` の処理（ABA-safe）。死んだ room を dict から外す。残すと以後の
/// lookup が死んだ subject を返し続け、その RoomId は再起動まで使用不能になる。
pub fn room_down(core: Core(m), pid: process.Pid, label: String) -> Core(m) {
  case dict.get(core.monitored, pid) {
    Ok(MonitoredRoom(key, subject)) -> {
      logging.log(logging.Warning, label <> " crashed: id=" <> key)
      let rooms = case dict.get(core.rooms, key) {
        // Release 後の subject_owner 失敗により古い監視記録だけが残り、
        // 同じ key に新しい room が登録済みでも、古い Down では消さない。
        Ok(current) if current == subject -> dict.delete(core.rooms, key)
        _ -> core.rooms
      }
      Core(
        ..core,
        rooms:,
        monitored: dict.delete(core.monitored, pid),
        stuck_rooms: set.delete(core.stuck_rooms, key),
      )
    }
    // 既に Release 済みなど、監視表に無い pid は無視する。
    Error(Nil) -> core
  }
}

/// `subject` が `key` に登録中のものと同一か。`Release` と同じ ABA 対処で、
/// 取り違えの経緯は `registry.Release` のドキュメントコメントを参照（#26）。
pub fn is_registered(core: Core(m), key: String, subject: Subject(m)) -> Bool {
  case dict.get(core.rooms, key) {
    Ok(current) -> current == subject
    Error(Nil) -> False
  }
}

/// `RoomEmptyChecked` の処理。空と判定され、かつ判定を待つ間に同じ key へ
/// 別 actor が登録し直されていない場合だけ room を外す（#160 と同じ ABA 対処）。
pub fn close_if_empty(
  core: Core(m),
  key: String,
  subject: Subject(m),
  empty: Bool,
  label: String,
) -> Core(m) {
  case empty && is_registered(core, key, subject) {
    False -> core
    True -> {
      logging.log(logging.Info, label <> " closed (empty): id=" <> key)
      // subject_owner がまだ引ける場合だけ、その pid の記録を直接消す。
      // subject も一致を確かめるので、pid が再利用されても別 room の監視を
      // 消さない。既に終了して owner を引けない場合は、後続の RoomDown が
      // 古い記録を消す。その際も subject 一致ガードが新しい room を守る（#160）。
      let monitored = case process.subject_owner(subject) {
        Ok(pid) ->
          case dict.get(core.monitored, pid) {
            Ok(MonitoredRoom(subject: monitored_subject, ..))
              if monitored_subject == subject
            -> dict.delete(core.monitored, pid)
            _ -> core.monitored
          }
        Error(Nil) -> core.monitored
      }
      Core(..core, rooms: dict.delete(core.rooms, key), monitored:)
    }
  }
}

/// `Health` の probe を発火すべきか決め、発火するなら対象 room 全件を返す。
/// 前回の probe 群がまだ全件返り終えていなければ見送る（#269）。
pub fn begin_probes(core: Core(m)) -> #(List(#(String, Subject(m))), Core(m)) {
  case core.probe_in_flight {
    0 -> #(
      dict.to_list(core.rooms),
      Core(..core, probe_in_flight: dict.size(core.rooms)),
    )
    _ -> #([], core)
  }
}

/// probe 1 件の結果を反映する。probe 発火後に同じ key で room が入れ替わって
/// いれば `stuck_rooms` は書き換えない（#471）。`probe_in_flight` は常に減らす。
pub fn record_probe(
  core: Core(m),
  key: String,
  subject: Subject(m),
  ok: Bool,
) -> Core(m) {
  let stuck_rooms = case dict.get(core.rooms, key) {
    Ok(current) if current == subject ->
      case ok {
        True -> set.delete(core.stuck_rooms, key)
        False -> set.insert(core.stuck_rooms, key)
      }
    _ -> core.stuck_rooms
  }
  // 0 未満にはならない: probe_in_flight は発火時に room 数で設定され、各発火に
  // つき結果はちょうど1回だけ返る。
  let probe_in_flight = int.max(0, core.probe_in_flight - 1)
  Core(..core, stuck_rooms:, probe_in_flight:)
}
