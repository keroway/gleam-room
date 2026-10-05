import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set
import gleamroom/call
import gleamroom/room
import gleamroom/room_registry.{type Core}

/// 実体は `room_registry` が持つ（#586）。`poker_registry.RoomId` と同じ型。
pub type RoomId =
  room_registry.RoomId

pub fn room_id(value: String) -> RoomId {
  room_registry.room_id(value)
}

/// websocket.gleam のライフサイクルログ（#25）が RoomId の中身を文字列化するのに使う。
pub fn room_id_to_string(id: RoomId) -> String {
  room_registry.room_id_to_string(id)
}

pub type Message {
  Lookup(
    id: RoomId,
    reply_to: Subject(Result(Subject(room.Message), room_registry.LookupError)),
  )
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
  /// いる）。死んだ room は別途 `RoomDown` で `rooms`・`stuck_rooms` の両方
  /// から外れるので、ここでの `stuck_rooms` への追加は一時的（次の probe で
  /// 消えるか、`RoomDown` で `rooms` ごと存在しなくなる）。
  ///
  /// probe 発火時点の `subject` を運び、応答時に `dict.get(state.rooms, key)`
  /// の現在値と一致するかを確かめる（#471）。一致確認が無いと、probe 発火後に
  /// 同じ key で room が入れ替わった場合（room 破棄→再登録）、遅れて届いた
  /// probe 結果が無関係な新しい room の `stuck_rooms` を誤って書き換える。
  /// `RoomDown`/`Release`/`RoomEmptyChecked` と同じ ABA 対処（#160）。
  RoomProbed(key: String, subject: Subject(room.Message), ok: Bool)
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

/// room 管理状態（`core`、`room_registry` 参照）と registry 自身の subject。
///
/// 起動関数を `core` に持つのは**テストのため**（#32）。BEAM のプロセス生成は
/// 資源が尽きない限り成功するので、失敗経路は注入しないと踏めない。
/// 「失敗しても registry がクラッシュしない」ことは型では保証できず、
/// 実際に失敗させて確かめる必要がある。
type State {
  State(
    core: Core(room.Message),
    /// registry 自身の subject（#71）。`Release` が空判定を別プロセスへ
    /// 投げるとき、結果（`RoomEmptyChecked`）の返送先として渡す。
    self: Subject(Message),
  )
}

/// `max_rooms` の既定値。運用上の実測に基づく値ではなく、単一プロセスが
/// 無制限に増えることを防ぐための保守的な上限（#127）。
const default_max_rooms = 1000

/// `default_max_rooms` を呼び出し元へ公開する（#352）。
///
/// `gleamroom.gleam` の起動経路が「`MAX_ROOMS` 環境変数が未設定のときの
/// 既定値」としてこの値を必要とするが、`const` は private のため直接参照
/// できない。
pub fn get_default_max_rooms() -> Int {
  default_max_rooms
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

/// `room_registry` の exit 分類を、この registry の `Message` へ写す（#117）。
fn exit_to_message(kind: room_registry.ExitKind) -> Message {
  case kind {
    room_registry.RoomExited(pid) -> RoomDown(pid)
    room_registry.ParentShutdownRequested -> ParentShutdown
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
  room_registry.build(
    room_registry.new(start_room, max_rooms),
    exit_to_message,
    handle_message,
    // `subject` は初期化中の自分自身の subject（#71）。ここでしか
    // 手に入らないため、`State` へ持たせるのは `build` の中に限る。
    fn(core, subject) { State(core:, self: subject) },
  )
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
  start_named_with_max_rooms(name, default_max_rooms)
}

/// `start_named` の、room数上限を差し替えられる版（#352）。
///
/// 本番の起動経路（`gleamroom.gleam`）が `MAX_ROOMS` 環境変数の値を
/// 反映できるように、`default_max_rooms` 固定だった `start_named` から
/// 上限を引数として切り出す。`start_named` はこれを既定値で呼ぶだけの薄い
/// 委譲になる。
pub fn start_named_with_max_rooms(
  name: process.Name(Message),
  max_rooms: Int,
) -> actor.StartResult(Subject(Message)) {
  build(room.start, max_rooms)
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
        room_registry.lookup(state.core, room_id_to_string(id), "room")
      process.send(reply_to, result)
      actor.continue(State(..state, core:))
    }
    RoomDown(pid) ->
      actor.continue(
        State(..state, core: room_registry.room_down(state.core, pid, "room")),
      )
    Health(reply_to) -> {
      // 返事が来ること自体が「registry が詰まっていない」証拠。
      // `stuck` は前回の probe 結果を即座に返し、待たせない（#138）。
      process.send(
        reply_to,
        HealthSnapshot(
          rooms: dict.size(state.core.rooms),
          stuck: set.size(state.core.stuck_rooms),
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
      let #(targets, core) = room_registry.begin_probes(state.core)
      list.each(targets, fn(target) {
        let #(key, subject) = target
        process.spawn_unlinked(fn() {
          let ok = case room.get_snapshot(subject) {
            Ok(_) -> True
            Error(Nil) -> False
          }
          process.send(state.self, RoomProbed(key, subject, ok))
        })
      })
      actor.continue(State(..state, core:))
    }
    RoomProbed(key, subject, ok) ->
      // probe 発火後に同じ key で room が入れ替わっていないか確かめる（#471）。
      // 一致しなければ stuck_rooms は書き換えず、probe_in_flight の
      // カウントダウンだけ行う。
      actor.continue(
        State(
          ..state,
          core: room_registry.record_probe(state.core, key, subject, ok),
        ),
      )
    ParentShutdown -> {
      // 親（supervisor）からの shutdown 要求。無視して生き続けると
      // supervisor は既定の shutdown タイムアウト（5秒）を待ってから
      // brutal kill するしかない（#117）。即座に止まって応答する。
      actor.stop()
    }
    Release(id, subject) -> {
      let key = room_id_to_string(id)
      // 登録中のものと同一の actor のときだけ対象にする。ABA 問題への対処で、
      // 理由は `Release` のドキュメントコメントを参照。
      case room_registry.is_registered(state.core, key, subject) {
        True -> {
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
            let empty = room.shutdown_if_empty(subject)
            process.send(state.self, RoomEmptyChecked(id, subject, empty))
          })
          actor.continue(state)
        }
        False -> actor.continue(state)
      }
    }
    RoomEmptyChecked(id, subject, empty) ->
      // 判定結果を待つ間に別の actor が同じ key で登録し直されていないか、
      // `Release` と同じガードで確かめる（#160 と同じ ABA 対処）。
      actor.continue(
        State(
          ..state,
          core: room_registry.close_if_empty(
            state.core,
            room_id_to_string(id),
            subject,
            empty,
            "room",
          ),
        ),
      )
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
) -> Result(Subject(room.Message), room_registry.LookupError) {
  call.try_call(subject, call.default_timeout, Lookup(id, _), "registry.lookup")
  |> result.replace_error(room_registry.Unavailable)
  |> result.flatten
}
