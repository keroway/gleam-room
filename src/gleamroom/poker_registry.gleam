import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set
import gleamroom/call
import gleamroom/poker
import gleamroom/registry
import gleamroom/room_registry.{type Core}

/// 実体は `room_registry` が持つ（#586）。`registry.RoomId` と同じ型。
pub type RoomId =
  room_registry.RoomId

pub fn room_id(value: String) -> RoomId {
  room_registry.room_id(value)
}

pub fn room_id_to_string(id: RoomId) -> String {
  room_registry.room_id_to_string(id)
}

pub type Message {
  Lookup(
    id: RoomId,
    reply_to: Subject(Result(Subject(poker.Message), room_registry.LookupError)),
  )
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
  /// registry が生きていて応答することを確かめる。`registry.gleam`'s
  /// `Health` と同じ理由（#93, #138, #285）: `/health` が poker registry
  /// の停止・詰まりを検知できていなかった穴を塞ぐ。
  Health(reply_to: Subject(HealthSnapshot))
  /// room 1 件分の probe（`poker.get_snapshot`）の結果。`registry.gleam`'s
  /// `RoomProbed` と同じ理由（#138）。probe 発火時点の `subject` を運び、
  /// 応答時に登録中の値と一致するかを確かめる（#471）。一致確認が無いと、
  /// probe 発火後に同じ key で room が入れ替わった場合、遅れて届いた結果が
  /// 無関係な新しい room の `stuck_rooms` を誤って書き換える。
  RoomProbed(key: String, subject: Subject(poker.Message), ok: Bool)
}

/// `Health` の返答。`registry.gleam`'s `HealthSnapshot` と同じ理由（#138）:
/// `rooms` は登録数、`stuck` は前回の probe で応答が無かった room の数。
pub type HealthSnapshot {
  HealthSnapshot(rooms: Int, stuck: Int)
}

/// room 管理状態（`core`、`room_registry` 参照）と registry 自身の subject。
/// 起動関数を `core` に持つのは**テストのため**、`registry.gleam`'s `State` と
/// 同じ理由（#32）。
type State {
  State(
    core: Core(poker.Message),
    /// registry 自身の subject（#71 と同じ理由）。
    self: Subject(Message),
  )
}

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors
/// (mirrors `registry.gleam`'s `start`, ADR 0002 / ADR 0009).
pub fn start() -> actor.StartResult(Subject(Message)) {
  build(poker.start, registry.get_default_max_rooms())
  |> actor.start
}

/// 起動関数を差し替えて開始する。**テスト専用**（#32 と同じ理由）。
pub fn start_with_room_starter(
  start_room: fn() -> actor.StartResult(Subject(poker.Message)),
) -> actor.StartResult(Subject(Message)) {
  build(start_room, registry.get_default_max_rooms())
  |> actor.start
}

/// room数の上限を差し替えて開始する。**テスト専用**（#127 と同じ理由）。
pub fn start_with_max_rooms(
  max_rooms: Int,
) -> actor.StartResult(Subject(Message)) {
  build(poker.start, max_rooms)
  |> actor.start
}

/// `room_registry` の exit 分類を、この registry の `Message` へ写す（#117）。
fn exit_to_message(kind: room_registry.ExitKind) -> Message {
  case kind {
    room_registry.RoomExited(pid) -> RoomDown(pid)
    room_registry.ParentShutdownRequested -> ParentShutdown
  }
}

/// room の死を Down メッセージとして受け取れる形で actor を組み立てる。
/// `registry.gleam`'s `build` と同じ理由（#39, ADR 0007）。
fn build(
  start_room: fn() -> actor.StartResult(Subject(poker.Message)),
  max_rooms: Int,
) -> actor.Builder(State, Message, Subject(Message)) {
  room_registry.build(
    room_registry.new(start_room, max_rooms),
    exit_to_message,
    handle_message,
    fn(core, subject) { State(core:, self: subject) },
  )
}

/// 名前付きで起動する。`registry.gleam`'s `start_named` と同じ理由（#23）:
/// supervisor 配下で再起動すると subject が変わるため、呼び出し側は名前
/// 経由で常に現行のプロセスへ届く必要がある。
pub fn start_named(
  name: process.Name(Message),
) -> actor.StartResult(Subject(Message)) {
  start_named_with_max_rooms(name, registry.get_default_max_rooms())
}

/// `start_named` の、room数上限を差し替えられる版（#352）。
///
/// `registry.gleam`'s `start_named_with_max_rooms` と同じ理由: 本番の起動
/// 経路が `MAX_ROOMS` 環境変数の値を反映できるようにする。
pub fn start_named_with_max_rooms(
  name: process.Name(Message),
  max_rooms: Int,
) -> actor.StartResult(Subject(Message)) {
  build(poker.start, max_rooms)
  |> actor.named(name)
  |> actor.start
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Lookup(id, reply_to) -> {
      let #(result, core) =
        room_registry.lookup(state.core, room_id_to_string(id), "poker room")
      process.send(reply_to, result)
      actor.continue(State(..state, core:))
    }
    RoomDown(pid) ->
      actor.continue(
        State(
          ..state,
          core: room_registry.room_down(state.core, pid, "poker room"),
        ),
      )
    ParentShutdown -> actor.stop()
    Release(id, subject) -> {
      case
        room_registry.is_registered(state.core, room_id_to_string(id), subject)
      {
        True -> {
          process.spawn_unlinked(fn() {
            let empty = poker.shutdown_if_empty(subject)
            process.send(state.self, RoomEmptyChecked(id, subject, empty))
          })
          actor.continue(state)
        }
        False -> actor.continue(state)
      }
    }
    RoomEmptyChecked(id, subject, empty) ->
      actor.continue(
        State(
          ..state,
          core: room_registry.close_if_empty(
            state.core,
            room_id_to_string(id),
            subject,
            empty,
            "poker room",
          ),
        ),
      )
    Health(reply_to) -> {
      // `registry.gleam`'s `Health` と同じ理由（#138）: 返事が来ること自体が
      // 「registry が詰まっていない」証拠。`stuck` は前回の probe 結果を
      // 即座に返し、待たせない。
      process.send(
        reply_to,
        HealthSnapshot(
          rooms: dict.size(state.core.rooms),
          stuck: set.size(state.core.stuck_rooms),
        ),
      )
      // 前回の probe 群がまだ全件返り終えていなければ発火を見送る
      // （#269 と同じガード）。
      let #(targets, core) = room_registry.begin_probes(state.core)
      list.each(targets, fn(target) {
        let #(key, subject) = target
        process.spawn_unlinked(fn() {
          let ok = case poker.get_snapshot(subject) {
            Ok(_) -> True
            Error(Nil) -> False
          }
          process.send(state.self, RoomProbed(key, subject, ok))
        })
      })
      actor.continue(State(..state, core:))
    }
    RoomProbed(key, subject, ok) ->
      // `registry.gleam`'s `RoomProbed` と同じ理由（#471）。
      actor.continue(
        State(
          ..state,
          core: room_registry.record_probe(state.core, key, subject, ok),
        ),
      )
  }
}

/// registry が応答することを確かめ、登録中の room 数と、直近の probe で
/// 応答が無かった room の数を返す。`registry.gleam`'s `health` と同じ理由
/// （#93, #138, #285）: `/health` はこれを見て poker 側の 503 本文を
/// 「落ちている」「詰まっている」で書き分ける。
pub fn health(
  subject: Subject(Message),
) -> Result(HealthSnapshot, call.Failure) {
  call.try_call_classified(
    subject,
    call.default_timeout,
    Health,
    "poker_registry.health",
  )
}

/// Resolves `id` to its active poker room actor, lazily starting one if
/// this is the first lookup for that `RoomId`. Mirrors `registry.gleam`'s
/// `lookup` (#58 / #32): failures never crash the calling process.
pub fn lookup(
  subject: Subject(Message),
  id: RoomId,
) -> Result(Subject(poker.Message), room_registry.LookupError) {
  call.try_call(
    subject,
    call.default_timeout,
    Lookup(id, _),
    "poker_registry.lookup",
  )
  |> result.replace_error(room_registry.Unavailable)
  |> result.flatten
}
