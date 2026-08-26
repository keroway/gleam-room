import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleamroom/call
import gleamroom/poker
import logging

/// Opaque so callers cannot construct a `RoomId` except through `room_id`,
/// mirroring `registry.gleam`'s `RoomId` (ADR 0009: Planning Poker
/// duplicates rather than shares the buzzer's registry).
pub opaque type RoomId {
  RoomId(String)
}

pub fn room_id(value: String) -> RoomId {
  RoomId(value)
}

pub fn room_id_to_string(id: RoomId) -> String {
  let RoomId(value) = id
  value
}

pub type Message {
  Lookup(id: RoomId, reply_to: Subject(Result(Subject(poker.Message), Nil)))
  /// 最後の参加者が抜けた room を登録から外す。`registry.gleam`'s `Release`
  /// と同じ理由（#26）: 登録中のものと一致するときだけ削除する ABA ガード。
  Release(id: RoomId, subject: Subject(poker.Message))
  /// 起動した room actor が落ちたときに届く。`registry.gleam`'s `RoomDown`
  /// と同じ理由（#39）: room は registry が直接起動して link するため、
  /// クラッシュは trap_exits 経由でメッセージとして受ける必要がある。
  RoomDown(pid: process.Pid)
  /// `trap_exits(True)` は supervisor からの shutdown 要求も room のクラッシュ
  /// と区別なく届けるため、`registry.gleam`'s `ParentShutdown` と同じ理由
  /// （#117）で別扱いにし、即座に `actor.stop()` する。
  ParentShutdown
  /// `Release` が投げた空判定（`poker.shutdown_if_empty`）の結果。
  /// `registry.gleam`'s `RoomEmptyChecked` と同じ理由（#71）: registry の
  /// メールボックスを詰まった room 1つでブロックしないよう、判定は別プロセスへ
  /// 投げて結果だけを受け取る。
  RoomEmptyChecked(id: RoomId, subject: Subject(poker.Message), empty: Bool)
}

/// room を起動する関数と、起動済み room の対応表。
///
/// 起動関数を状態に持つのは**テストのため**、`registry.gleam`'s `State` と
/// 同じ理由（#32）。
type State {
  State(
    rooms: Dict(String, Subject(poker.Message)),
    /// 監視中の room actor の pid → 登録時の room 情報（#39 / #160 と同じ理由）。
    monitored: Dict(process.Pid, MonitoredRoom),
    start_room: fn() -> actor.StartResult(Subject(poker.Message)),
    /// 新規 room actor（BEAMプロセス）を起動できる上限（#127 と同じ理由）。
    max_rooms: Int,
    /// registry 自身の subject（#71 と同じ理由）。
    self: Subject(Message),
  )
}

/// `max_rooms` の既定値。`registry.gleam`'s `default_max_rooms` と同じ値。
const default_max_rooms = 1000

type MonitoredRoom {
  MonitoredRoom(key: String, subject: Subject(poker.Message))
}

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors
/// (mirrors `registry.gleam`'s `start`, ADR 0002 / ADR 0009).
pub fn start() -> actor.StartResult(Subject(Message)) {
  build(poker.start, default_max_rooms)
  |> actor.start
}

/// 起動関数を差し替えて開始する。**テスト専用**（#32 と同じ理由）。
pub fn start_with_room_starter(
  start_room: fn() -> actor.StartResult(Subject(poker.Message)),
) -> actor.StartResult(Subject(Message)) {
  build(start_room, default_max_rooms)
  |> actor.start
}

/// room数の上限を差し替えて開始する。**テスト専用**（#127 と同じ理由）。
pub fn start_with_max_rooms(
  max_rooms: Int,
) -> actor.StartResult(Subject(Message)) {
  build(poker.start, max_rooms)
  |> actor.start
}

/// trapped exit を `RoomDown`（room のクラッシュ）と `ParentShutdown`
/// （親からの shutdown 要求）に振り分ける。`registry.gleam`'s
/// `exit_to_message` と同じ理由・実装（#117）。
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

/// room の死を Down メッセージとして受け取れる形で actor を組み立てる。
/// `registry.gleam`'s `build` と同じ理由（#39, ADR 0007）。
fn build(
  start_room: fn() -> actor.StartResult(Subject(poker.Message)),
  max_rooms: Int,
) -> actor.Builder(State, Message, Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_trapped_exits(exit_to_message)
    process.trap_exits(True)
    let initial =
      State(
        rooms: dict.new(),
        monitored: dict.new(),
        start_room:,
        max_rooms:,
        self: subject,
      )
    actor.initialised(initial)
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
}

/// 名前付きで起動する。`registry.gleam`'s `start_named` と同じ理由（#23）:
/// supervisor 配下で再起動すると subject が変わるため、呼び出し側は名前
/// 経由で常に現行のプロセスへ届く必要がある。
pub fn start_named(
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  build(poker.start, default_max_rooms)
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
          logging.log(
            logging.Warning,
            "poker room capacity reached, rejecting lookup: id="
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
          case state.start_room() {
            Ok(started) -> {
              logging.log(logging.Info, "poker room created: id=" <> key)
              let subject = started.data
              process.send(reply_to, Ok(subject))
              let monitored = case process.subject_owner(subject) {
                Ok(pid) ->
                  dict.insert(
                    state.monitored,
                    pid,
                    MonitoredRoom(key:, subject:),
                  )
                Error(Nil) -> {
                  logging.log(
                    logging.Warning,
                    "subject_owner failed for started poker room, room not monitored: id="
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
                "poker room failed to start: id="
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
        Ok(MonitoredRoom(key, subject)) -> {
          logging.log(logging.Warning, "poker room crashed: id=" <> key)
          let rooms = case dict.get(state.rooms, key) {
            Ok(current) if current == subject -> dict.delete(state.rooms, key)
            _ -> state.rooms
          }
          actor.continue(
            State(..state, rooms:, monitored: dict.delete(state.monitored, pid)),
          )
        }
        Error(Nil) -> actor.continue(state)
      }
    ParentShutdown -> actor.stop()
    Release(id, subject) -> {
      let key = room_id_to_string(id)
      case dict.get(state.rooms, key) {
        Ok(current) if current == subject -> {
          process.spawn_unlinked(fn() {
            let empty = poker.shutdown_if_empty(current)
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
        True, Ok(current) if current == subject -> {
          logging.log(logging.Info, "poker room closed (empty): id=" <> key)
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

/// Resolves `id` to its active poker room actor, lazily starting one if
/// this is the first lookup for that `RoomId`. Mirrors `registry.gleam`'s
/// `lookup` (#58 / #32): failures never crash the calling process.
pub fn lookup(
  subject: Subject(Message),
  id: RoomId,
) -> Result(Subject(poker.Message), Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    Lookup(id, _),
    "poker_registry.lookup",
  )
  |> result.flatten
}
