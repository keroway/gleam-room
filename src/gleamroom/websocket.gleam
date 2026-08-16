import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import gleamroom/protocol
import gleamroom/registry
import gleamroom/room
import logging
import mist.{
  type Connection, type Next, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}

/// Wires the WebSocket wire format to the Room registry and Room actors.
///
/// This module owns decoding/encoding and connection lifecycle only; it
/// resolves rooms through the registry, forwards typed commands to the
/// resolved Room actor, and translates Room events/snapshots back to wire
/// messages. It intentionally does not decide buzzer ordering or any other
/// room-domain rule.
type ConnectionState {
  ConnectionState(
    registry: Subject(registry.Message),
    room: Option(RoomHandle),
    heartbeat_subject: Subject(ConnectionEvent),
    // クライアントから何か受け取るたびに True へ戻す（#35）。ハートビート
    // tick 到達時に False のままなら、この tick 区間まるごと無音だったと
    // 判断して接続を閉じる。
    active_since_heartbeat: Bool,
  )
}

/// 接続プロセスが `Selector` 経由で受け取りうるメッセージ全体。room actor
/// からのブロードキャストと、アイドルタイムアウト検知用の自己送信タイマー
/// tick を同じ selector に載せるための wrapper（#35）。
pub type ConnectionEvent {
  RoomBroadcast(room.RoomEvent)
  HeartbeatTick
}

/// tick の間隔であり、かつ検知できる最短のアイドル時間でもある。前回の
/// tick 以降に一度もクライアントからフレームが届かなければ次の tick で
/// 閉じるため、実際に閉じるまでの猶予は 1〜2 回分(30〜60秒)になる。
const heartbeat_interval_ms = 30_000

type RoomHandle {
  RoomHandle(
    subject: Subject(room.Message),
    participant_id: room.ParticipantId,
    session: Subject(room.RoomEvent),
    // 切断時に registry へ Release を送るために保持する（#26）。
    // room_id が無いと「どの room を外すか」を registry へ伝えられない。
    room_id: registry.RoomId,
  )
}

pub fn upgrade(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
) -> Response(ResponseData) {
  case origin_allowed(req) {
    True ->
      mist.websocket(
        request: req,
        handler: handle_message,
        on_init: fn(_connection) { on_init(registry_subject) },
        on_close: on_close,
      )
    False -> {
      logging.log(
        logging.Warning,
        "websocket upgrade rejected: origin not allowed, host=" <> req.host,
      )
      response.new(403)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

/// `Origin` ヘッダを検証する（#124）。Cross-Site WebSocket Hijacking を防ぐため、
/// ブラウザが送る `Origin` はリクエストの `Host` と一致する場合のみ許可する。
///
/// `Origin` ヘッダが無いリクエストは許可する。ブラウザは常に `Origin` を送るが、
/// CLI ツールや自作クライアントのような非ブラウザクライアントは送らないことが
/// あり、MVP は認証を持たないためこれらを区別して弾く根拠が無い（#124 の
/// 未確認事項として残した設計判断）。ここで防ぎたいのは「ブラウザ経由で、
/// 訪問者の意図しないオリジンから接続される」ことに限定する。
fn origin_allowed(req: Request(Connection)) -> Bool {
  origin_header_allowed(request.get_header(req, "origin"), req.host)
}

/// `origin_allowed` の本体。`Request(Connection)` に依存しない形へ切り出した
/// のは、ライブな接続なしでユニットテストできるようにするため（他の関数と
/// 同様の方針、このモジュールの他の "Pure and ... testable" 関数を参照）。
pub fn origin_header_allowed(
  origin_header: Result(String, Nil),
  host: String,
) -> Bool {
  case origin_header {
    Error(Nil) -> True
    Ok(origin) ->
      case uri.parse(origin) {
        Ok(parsed) -> parsed.host == Some(host)
        Error(Nil) -> False
      }
  }
}

fn on_init(
  registry_subject: Subject(registry.Message),
) -> #(ConnectionState, Option(Selector(ConnectionEvent))) {
  logging.log(logging.Info, "websocket connection opened: " <> connection_tag())
  let heartbeat_subject = process.new_subject()
  process.send_after(heartbeat_subject, heartbeat_interval_ms, HeartbeatTick)
  let selector = process.new_selector() |> process.select(heartbeat_subject)
  #(
    ConnectionState(
      registry: registry_subject,
      room: None,
      heartbeat_subject: heartbeat_subject,
      active_since_heartbeat: True,
    ),
    Some(selector),
  )
}

fn on_close(state: ConnectionState) -> Nil {
  case state.room {
    None -> {
      logging.log(
        logging.Info,
        "websocket connection closed (not joined): " <> connection_tag(),
      )
      Nil
    }
    Some(handle) -> {
      logging.log(
        logging.Info,
        "websocket connection closed: "
          <> connection_tag()
          <> ", room="
          <> registry.room_id_to_string(handle.room_id)
          <> ", participant="
          <> room.participant_id_to_string(handle.participant_id),
      )
      // 応答が無くても切断処理は続ける。room が死んでいれば #39 の経路で
      // registry から外れる。
      let _ =
        room.dispatch(
          handle.subject,
          room.Leave(handle.participant_id),
          handle.session,
        )
      // 最後の参加者が抜けたら registry から外す（#26）。外さないと、
      // 一度でも join された RoomId の Room actor と Dict エントリが
      // プロセス終了まで残り続ける。
      //
      // **ここで空かどうかを判定しない**（#36）。以前は get_snapshot で
      // 確かめてから Release を送っていたが、判定と停止が別プロセスに
      // またがるため、その隙に join した参加者ごと room が停止しうる。
      // 判定は room actor が自分のメールボックスの中で行う。
      //
      // 切断を知っているのはこの層なので、きっかけを送るのはここでよい。
      release_room(state.registry, handle.room_id, handle.subject)
      Nil
    }
  }
}

fn handle_message(
  state: ConnectionState,
  message: WebsocketMessage(ConnectionEvent),
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case message {
    mist.Text(text) -> handle_text(mark_active(state), text, connection)
    // Binary frames carry no protocol meaning yet. Unlike a silent ignore,
    // this responds the same way other unrecognized input does (#47), so a
    // client sending binary frames by mistake can tell it was rejected
    // rather than swallowed.
    mist.Binary(_data) -> {
      logging.log(logging.Info, "protocol message rejected: code=binary_frame")
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "binary_frame",
          "Binary frames are not supported.",
        ),
      )
      mist.continue(mark_active(state))
    }
    mist.Custom(RoomBroadcast(event)) -> {
      case room_event_to_server_message(event) {
        Some(server_message) -> send_server_message(connection, server_message)
        None -> Nil
      }
      mist.continue(state)
    }
    mist.Custom(HeartbeatTick) -> handle_heartbeat_tick(state)
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
  }
}

/// クライアントから届いたフレームを「生きている」印として記録する（#35）。
fn mark_active(state: ConnectionState) -> ConnectionState {
  ConnectionState(..state, active_since_heartbeat: True)
}

/// ハートビート tick 到達時の判定結果。
pub type HeartbeatOutcome {
  /// 前回の tick 以降、クライアントから何も届かなかった。接続を閉じる。
  HeartbeatTimedOut
  /// 生存を確認できた。次回判定に備えて `active_since_heartbeat` をリセットして続行する。
  HeartbeatContinues
}

/// アイドルタイムアウトの判定本体（#35）。`ConnectionState`/`WebsocketConnection`
/// に依存しない形へ切り出したのは、ライブな接続なしでユニットテストできる
/// ようにするため（このモジュールの他の "Pure and ... testable" 関数と同様の方針）。
pub fn heartbeat_outcome(active_since_heartbeat: Bool) -> HeartbeatOutcome {
  case active_since_heartbeat {
    False -> HeartbeatTimedOut
    True -> HeartbeatContinues
  }
}

/// `heartbeat_outcome` の判定を実行に反映する。`mist.stop()` は `on_close` を
/// 経由するので、room に参加済みなら通常の切断経路（`room.Leave` の dispatch
/// と registry への `Release`）がそのまま走る。
fn handle_heartbeat_tick(
  state: ConnectionState,
) -> Next(ConnectionState, ConnectionEvent) {
  case heartbeat_outcome(state.active_since_heartbeat) {
    HeartbeatTimedOut -> {
      logging.log(logging.Info, "websocket idle timeout: " <> connection_tag())
      mist.stop()
    }
    HeartbeatContinues -> {
      process.send_after(
        state.heartbeat_subject,
        heartbeat_interval_ms,
        HeartbeatTick,
      )
      mist.continue(ConnectionState(..state, active_since_heartbeat: False))
    }
  }
}

fn handle_text(
  state: ConnectionState,
  text: String,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case protocol.decode_client_message(text) {
    Error(error) -> {
      logging.log(
        logging.Info,
        "protocol message rejected: code=" <> error.code,
      )
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(error.code, error.message),
      )
      mist.continue(state)
    }
    Ok(protocol.Join(wire_room_id, display_name)) ->
      handle_join(state, connection, wire_room_id, display_name)
    Ok(protocol.Buzz) -> handle_buzz(state, connection)
    Ok(protocol.Reset) -> handle_reset(state, connection)
  }
}

fn handle_join(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_room_id: protocol.RoomId,
  display_name: String,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    Some(handle) -> {
      logging.log(
        logging.Info,
        "already joined: room="
          <> registry.room_id_to_string(handle.room_id)
          <> ", participant="
          <> room.participant_id_to_string(handle.participant_id),
      )
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "already_joined",
          "This connection has already joined a room.",
        ),
      )
      mist.continue(state)
    }
    None -> {
      let room_id = registry.room_id(protocol.room_id_to_string(wire_room_id))
      // room の起動に失敗したら、その旨を返して接続は生かす（#32）。
      // 以前は registry が `let assert` でクラッシュしており、1 ルームの
      // 起動失敗が無関係な全ルームの lookup を巻き添えにしていた。
      use room_subject <- with_room(state, connection, room_id)
      let participant_id = room.participant_id(new_participant_id())
      let session = process.new_subject()

      // room が応答しなければ join を諦め、理由をクライアントへ返す（#33）。
      // 以前は actor.call のタイムアウトで**この接続プロセスごとクラッシュ**し、
      // クライアントには何も届かなかった。
      use event <- with_join_reply(
        state.registry,
        room_id,
        room_subject,
        connection,
        room.dispatch(
          room_subject,
          room.Join(participant_id, display_name),
          session,
        ),
      )
      case event {
        room.ParticipantJoined(participant) -> {
          logging.log(
            logging.Info,
            "join accepted: room="
              <> registry.room_id_to_string(room_id)
              <> ", participant="
              <> room.participant_id_to_string(participant.id),
          )
          // snapshot が取れないときは空として扱う。join 自体は成立して
          // いるので、接続を落とすより「まだ誰も見えない」状態で続けるほうがよい。
          // ただし無警告だと「本当に room が空」なのか「取得だけタイムアウトした」
          // のか区別できなくなるため、フォールバック時は必ず warning を残す（#65）。
          // participants と buzzes は 1 回の `get_state` で取得する。2 回の
          // 独立した call だと、その間に他接続の Join/Leave/Buzz/Reset が
          // 割り込み、取得時点がずれたスナップショットの組み合わせになりうる
          // （#121）。
          let #(snapshot, buzz_snapshot) = case room.get_state(room_subject) {
            Ok(state) -> state
            Error(Nil) -> {
              logging.log(
                logging.Warning,
                "get_state timed out after join, returning empty participants/buzzes: room="
                  <> registry.room_id_to_string(room_id)
                  <> ", participant="
                  <> room.participant_id_to_string(participant.id),
              )
              #([], [])
            }
          }
          send_server_message(
            connection,
            protocol.State(
              participants: list.map(snapshot, to_wire_participant),
              buzzes: list.map(buzz_snapshot, to_wire_buzz_result),
            ),
          )
          let next_state =
            ConnectionState(
              ..state,
              room: Some(RoomHandle(
                room_subject,
                participant_id,
                session,
                room_id,
              )),
            )
          let selector =
            process.new_selector()
            |> process.select(state.heartbeat_subject)
            |> process.select_map(session, RoomBroadcast)
          mist.continue(next_state) |> mist.with_selector(selector)
        }
        room.JoinRejected(_, reason) -> {
          logging.log(
            logging.Info,
            "join rejected: room="
              <> registry.room_id_to_string(room_id)
              <> ", reason="
              <> string.inspect(reason),
          )
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(
              "join_rejected",
              "Unable to join the requested room.",
            ),
          )
          mist.continue(state)
        }
        // `Join` never yields any other event; kept for exhaustiveness since
        // `room.RoomEvent` is shared across every room command.
        room.ParticipantLeft(_)
        | room.LeaveRejected(_, _)
        | room.BuzzAccepted(_, _, _)
        | room.BuzzRejected(_, _)
        | room.RoundReset -> mist.continue(state)
      }
    }
  }
}

fn handle_buzz(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "buzz")
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        room.dispatch(
          handle.subject,
          room.Buzz(handle.participant_id),
          handle.session,
        ),
      )
      case event {
        room.BuzzAccepted(id, display_name, position) -> {
          logging.log(
            logging.Info,
            "buzz accepted: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> room.participant_id_to_string(id)
              <> ", position="
              <> int.to_string(position),
          )
          send_server_message(
            connection,
            protocol.BuzzAccepted(
              to_wire_participant_id(id),
              display_name,
              position,
            ),
          )
        }
        room.BuzzRejected(id, reason) -> {
          logging.log(
            logging.Info,
            "buzz rejected: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> room.participant_id_to_string(id)
              <> ", reason="
              <> string.inspect(reason),
          )
          let #(code, message) = case reason {
            room.AlreadyBuzzed -> #(
              "already_buzzed",
              "This participant already buzzed for the current round.",
            )
            room.BuzzerNotJoined -> #(
              "buzzer_not_joined",
              "This connection has not joined the room yet.",
            )
          }
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(code, message),
          )
        }
        // `Buzz` never yields any other event; kept for exhaustiveness since
        // `room.RoomEvent` is shared across every room command.
        room.ParticipantJoined(_)
        | room.JoinRejected(_, _)
        | room.ParticipantLeft(_)
        | room.LeaveRejected(_, _)
        | room.RoundReset -> Nil
      }
      mist.continue(state)
    }
  }
}

fn handle_reset(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "reset")
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        room.dispatch(handle.subject, room.ResetRound, handle.session),
      )
      case event {
        room.RoundReset -> {
          logging.log(
            logging.Info,
            "round reset: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", by="
              <> room.participant_id_to_string(handle.participant_id),
          )
          send_server_message(connection, protocol.RoundReset)
        }
        // `ResetRound` never yields any other event; kept for exhaustiveness
        // since `room.RoomEvent` is shared across every room command.
        room.ParticipantJoined(_)
        | room.JoinRejected(_, _)
        | room.ParticipantLeft(_)
        | room.LeaveRejected(_, _)
        | room.BuzzAccepted(_, _, _)
        | room.BuzzRejected(_, _) -> Nil
      }
      mist.continue(state)
    }
  }
}

/// registry へ `Release` を送る。送信前に named subject の登録先を
/// `process.subject_owner` で確認し、registry が(再起動中などで)不在なら
/// パニックせずログだけ残して送信をスキップする（#116）。
///
/// `process.send` は named subject が未登録だと `let assert` で panic する
/// (`gleam_erlang` のドキュメントとは矛盾するが実装はそう)。registry は
/// `RestForOne` の supervisor 配下にあり再起動中は一時的に名前が外れうるため、
/// 無guardで呼ぶとその窓に閉じた接続が mist の接続プロセスごとクラッシュする。
pub fn release_room(
  registry_subject: Subject(registry.Message),
  room_id: registry.RoomId,
  room_subject: Subject(room.Message),
) -> Nil {
  case process.subject_owner(registry_subject) {
    Ok(_pid) ->
      process.send(registry_subject, registry.Release(room_id, room_subject))
    Error(Nil) ->
      logging.log(
        logging.Warning,
        "registry unavailable, skipping release: room="
          <> registry.room_id_to_string(room_id),
      )
  }
}

/// room を引けたときだけ `next` を実行する。引けなければクライアントへ
/// `room_unavailable` を返し、接続はそのまま維持する（#32）。
fn with_room(
  state: ConnectionState,
  connection: WebsocketConnection,
  room_id: registry.RoomId,
  next: fn(Subject(room.Message)) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case registry.lookup(state.registry, room_id) {
    Ok(room_subject) -> next(room_subject)
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "room unavailable: room=" <> registry.room_id_to_string(room_id),
      )
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "room_unavailable",
          "The room could not be started. Please try again.",
        ),
      )
      mist.continue(state)
    }
  }
}

/// join の応答が得られたときだけ `next` を実行する（#33）。
///
/// **タイムアウトは「実行されなかった」ではなく「結果不明」**。`exception.rescue`
/// は要求を取り消さないので、`Join` は room のメールボックスに残り、後から
/// 実行されうる。そこで再試行を促すと、遅れて成立した参加者と再試行ぶんの
/// **二重参加**になり、切断時には最後の `RoomHandle` しか Leave しないため
/// 前者が room に残り続ける。
///
/// そのため join のタイムアウトでは再試行を促さず、**接続を閉じる**。
/// クライアントは新しい接続からやり直す。
///
/// 遅れて成立した参加者が room に残り続ける問題自体は #56 で解消済み。room
/// 側が `process.monitor` で接続プロセスを監視しており（#69）、この
/// `mist.stop()` で接続プロセスが終了すれば `SessionDown` 経由で自動的に
/// 後始末される（room.gleam の `update_sessions` を参照）。
fn with_join_reply(
  registry_subject: Subject(registry.Message),
  room_id: registry.RoomId,
  room_subject: Subject(room.Message),
  connection: WebsocketConnection,
  reply: Result(room.RoomEvent, Nil),
  next: fn(room.RoomEvent) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case reply {
    Ok(event) -> next(event)
    Error(Nil) -> {
      // `lookup` がこの room を作った直後でも、ConnectionState にはまだ
      // RoomHandle が無い。そのまま接続を止めると on_close から Release されず、
      // 空の room actor が registry に残り続ける（#168）。room 自身が空かを
      // 判定するので、遅延した Join が先に成立していても停止させない。
      release_room(registry_subject, room_id, room_subject)
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "room_unavailable",
          "The room did not respond in time. Reconnect to try again.",
        ),
      )
      mist.stop()
    }
  }
}

/// room からの応答が得られたときだけ `next` を実行する（#33）。
///
/// join 以外（buzz / reset）に使う。これらは結果不明のまま再試行しても
/// 破綻しない — buzz は同一参加者の重複を room が `AlreadyBuzzed` で弾き、
/// reset は冪等。
///
/// 応答が無いのは room actor が詰まっている（あるいは死んだ）とき。
/// 以前は `actor.call` のタイムアウトで**この接続プロセスごとクラッシュ**し、
/// クライアントには理由が届かなかった。
fn with_room_reply(
  state: ConnectionState,
  connection: WebsocketConnection,
  reply: Result(room.RoomEvent, Nil),
  next: fn(room.RoomEvent) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case reply {
    Ok(event) -> next(event)
    Error(Nil) -> {
      send_room_unavailable(connection)
      mist.continue(state)
    }
  }
}

fn send_room_unavailable(connection: WebsocketConnection) -> Nil {
  send_server_message(
    connection,
    protocol.ProtocolErrorMessage(
      "room_unavailable",
      "The room did not respond in time. Please try again.",
    ),
  )
}

fn send_not_joined_error(
  connection: WebsocketConnection,
  command: String,
) -> Nil {
  logging.log(
    logging.Info,
    "not joined: command=" <> command <> ", " <> connection_tag(),
  )
  send_server_message(
    connection,
    protocol.ProtocolErrorMessage(
      "not_joined",
      "Join a room before sending this command.",
    ),
  )
}

fn send_server_message(
  connection: WebsocketConnection,
  message: protocol.ServerMessage,
) -> Nil {
  case
    mist.send_text_frame(connection, protocol.encode_server_message(message))
  {
    Ok(Nil) -> Nil
    Error(reason) ->
      logging.log(
        logging.Warning,
        "server message send failed: reason="
          <> string.inspect(reason)
          <> " "
          <> connection_tag(),
      )
  }
}

/// Translates a `RoomEvent` broadcast from the Room actor into the wire
/// message to send to other clients, or `None` when the event is a
/// rejection meant only for the connection that issued the command (already
/// answered directly by `handle_join`/`handle_buzz`, so re-broadcasting it
/// would leak another participant's failed attempt).
///
/// Pure and `WebsocketConnection`-free so it is unit-testable without a live
/// connection (#24).
pub fn room_event_to_server_message(
  event: room.RoomEvent,
) -> Option(protocol.ServerMessage) {
  case event {
    room.ParticipantJoined(participant) ->
      Some(protocol.ParticipantJoined(to_wire_participant(participant)))
    room.ParticipantLeft(id) ->
      Some(protocol.ParticipantLeft(to_wire_participant_id(id)))
    room.BuzzAccepted(id, display_name, position) ->
      Some(protocol.BuzzAccepted(
        to_wire_participant_id(id),
        display_name,
        position,
      ))
    room.RoundReset -> Some(protocol.RoundReset)
    room.JoinRejected(_, _) -> None
    room.LeaveRejected(_, _) -> None
    room.BuzzRejected(_, _) -> None
  }
}

/// Converts a domain `Participant` to its wire representation. Pure and
/// unit-testable without a live connection (#24).
pub fn to_wire_participant(
  participant: room.Participant,
) -> protocol.Participant {
  protocol.Participant(
    id: to_wire_participant_id(participant.id),
    display_name: participant.display_name,
  )
}

/// Converts a domain `ParticipantId` to its wire representation. Pure and
/// unit-testable without a live connection (#24).
pub fn to_wire_participant_id(
  id: room.ParticipantId,
) -> protocol.ParticipantId {
  protocol.participant_id(room.participant_id_to_string(id))
}

/// Converts a domain `BuzzResult` to its wire representation. Pure and
/// unit-testable without a live connection (#24).
pub fn to_wire_buzz_result(result: room.BuzzResult) -> protocol.BuzzResult {
  protocol.BuzzResult(
    participant_id: to_wire_participant_id(result.participant_id),
    display_name: result.display_name,
    position: result.position,
  )
}

/// ログの中で同一 WebSocket 接続の open/close を突き合わせるための識別子。
///
/// クライアントへは出さない内部ログ専用の値なので、接続プロセスの PID を
/// そのまま使ってよい（#28 が禁じているのはワイヤープロトコルへ PID を
/// 漏らすことで、ログはそれとは別の面）。display_name のような個人情報は
/// ここにもライフサイクルログ全体にも含めない。
fn connection_tag() -> String {
  "pid=" <> string.inspect(process.self())
}

/// 参加者 ID を生成する。
///
/// 以前は `process.self() |> string.inspect` で **BEAM の PID 文字列表現**
/// (`<0.612.0>` 形式) をそのまま使っており、それが `state` /
/// `participant_joined` / `buzz_accepted` を通じて**全クライアントへ**配信されていた
/// (#28)。実サーバーで `{"id":"//erl(<0.132.0>)"}` を観測している。
///
/// PID を外に出すと次の問題がある:
///
///   - サーバー内部のプロセス構造(採番の連番性・ノード番号)がそのまま漏れる
///   - PID は**プロセス終了後に再利用される**。再接続で別人に同じ ID が
///     割り当たると、前の参加者のブザー結果と混ざる
///   - 公開プロトコルの識別子が実装詳細に固定され、内部を変えられなくなる
///
/// 暗号論的乱数から作った不透明な値にする。16 バイトあれば衝突は実用上
/// 起きない。base64 は URL/JSON でそのまま扱えるよう padding なし。
pub fn new_participant_id() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base64_url_encode(False)
}
