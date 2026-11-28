import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleamroom/protocol
import gleamroom/registry
import gleamroom/room
import gleamroom/room_registry
import gleamroom/wire
import gleamroom/ws_guard.{
  FrameSizeAccepted, FrameTooLarge, HeartbeatContinues, HeartbeatTimedOut,
  MessageRateAccepted, MessageRateLimited, PingCounted, PingFree,
  binary_frame_code_and_message, connection_tag, default_heartbeat_interval_ms,
  frame_size_outcome, frame_size_outcome_for_byte_size,
  frame_too_large_code_and_message, heartbeat_outcome, message_rate_outcome,
  new_participant_id, origin_allowed, ping_outcome,
  rate_limited_code_and_message,
}
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
    // tick の間隔。本番は常に `default_heartbeat_interval_ms`。`upgrade_with_heartbeat_interval`
    // 経由でのみ差し替えられる（テストが30秒待たずにハートビートを検証するため、#613）。
    heartbeat_interval_ms: Int,
    // クライアントから何か受け取るたびに True へ戻す（#35）。ハートビート
    // tick 到達時に False のままなら、この tick 区間まるごと無音だったと
    // 判断して接続を閉じる。
    active_since_heartbeat: Bool,
    // 直近のハートビート窓（`heartbeat_interval_ms`）で受理したテキスト
    // フレームの数（#156）。tick ごとに 0 へ戻す。専用のタイマーやウォール
    // クロック読み取りを新設せず、既存のハートビート窓をレート制限の
    // 単位としてそのまま流用する。
    messages_since_heartbeat: Int,
    // 直近のハートビート窓で受けた keepalive ping の数（#764）。上限までは
    // `messages_since_heartbeat` を消費しない。tick ごとに 0 へ戻す。
    pings_since_heartbeat: Int,
  )
}

/// 接続プロセスが `Selector` 経由で受け取りうるメッセージ全体。room actor
/// からのブロードキャストと、アイドルタイムアウト検知用の自己送信タイマー
/// tick を同じ selector に載せるための wrapper（#35）。
pub type ConnectionEvent {
  RoomBroadcast(room.RoomEvent)
  HeartbeatTick
}

type RoomHandle {
  RoomHandle(
    subject: Subject(room.Message),
    participant_id: room.ParticipantId,
    session: Subject(room.RoomEvent),
    // 切断時に registry へ Release を送るために保持する（#26）。
    // room_id が無いと「どの room を外すか」を registry へ伝えられない。
    room_id: registry.RoomId,
    // join 時のスナップショットにあった room の世代（#765）。この接続へ送る
    // 全ての状態通知に付け、クライアントが前の room の通知と区別できるようにする。
    instance_id: String,
    // 会場表示の接続か（#768）。会場表示は参加者ではないので、閉じるときは
    // `detach` ではなく `unwatch` を送る。`participant_id` はどの参加者とも
    // 一致しない値で、ここから送られたコマンドは room が拒否する。
    is_display: Bool,
  )
}

pub fn upgrade(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
) -> Response(ResponseData) {
  upgrade_with_heartbeat_interval(
    req,
    registry_subject,
    default_heartbeat_interval_ms,
  )
}

/// `upgrade` と同じだが、ハートビート間隔を差し替えられる。ハートビートの
/// 挙動（room配信による延命、#581）を、実時間30秒を待たずに統合テストする
/// ためだけの入口で、本番の配線は `upgrade` を使う（#613）。
pub fn upgrade_with_heartbeat_interval(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
  heartbeat_interval_ms: Int,
) -> Response(ResponseData) {
  case origin_allowed(req) {
    True ->
      mist.websocket(
        request: req,
        handler: handle_message,
        on_init: fn(_connection) {
          on_init(registry_subject, heartbeat_interval_ms)
        },
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

fn on_init(
  registry_subject: Subject(registry.Message),
  heartbeat_interval_ms: Int,
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
      heartbeat_interval_ms: heartbeat_interval_ms,
      active_since_heartbeat: True,
      messages_since_heartbeat: 0,
      pings_since_heartbeat: 0,
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
      // 切断は退出ではない（#766）。room は参加者を切断中にして猶予を始め、
      // 猶予内に同じ resume token で戻れば同じ参加者として扱う。退出は
      // 明示的な `leave` か猶予切れだけ。最後の参加者の猶予が切れたら room
      // 自身が止まり、registry は `RoomDown` で登録を外す（ADR 0006 / 0010）。
      //
      // 非同期に送る。閉じる接続は応答を待つ必要がなく、既に別の接続へ
      // 付け替わっていれば room が無視する。
      case handle.is_display {
        True -> room.unwatch(handle.subject, handle.session)
        False ->
          room.detach(handle.subject, handle.participant_id, handle.session)
      }
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
    // rather than swallowed. They still go through the same frame size
    // (#126) and message rate (#156) accounting as text frames, otherwise a
    // connection sending binary frames instead of text bypasses both limits
    // entirely (#500).
    mist.Binary(data) -> handle_binary(mark_active(state), data, connection)
    mist.Custom(RoomBroadcast(room.SessionReplaced)) -> {
      // 同じ参加者が新しい接続で復帰した（#766）。この接続はもう参加者の
      // ものではないので、理由を伝えて閉じる。room 側は既にこの接続を
      // 外しているので、on_close で Detach を送らないよう handle を消す。
      logging.log(
        logging.Info,
        "websocket session replaced by a resume: " <> connection_tag(),
      )
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "session_replaced",
          session_replaced_message,
        ),
      )
      mist.stop()
    }
    mist.Custom(RoomBroadcast(event)) -> {
      // 配信は join 成立後にしか届かないので handle は必ずある。
      case state.room {
        Some(handle) ->
          case room_event_to_server_message(event, handle.instance_id) {
            Some(server_message) ->
              send_server_message(connection, server_message)
            None -> Nil
          }
        None -> Nil
      }
      // room配信は「生きている」印にしない（#764）。#581 では他参加者の活動で
      // 延命していたが、それだと応答しない接続が他参加者の活動で永久に残る。
      // 生存の根拠はこの接続自身からのフレーム（keepalive ping を含む）のみ。
      mist.continue(state)
    }
    mist.Custom(HeartbeatTick) -> handle_heartbeat_tick(state)
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
  }
}

/// クライアントから届いたフレームを「生きている」印として記録する（#35, #764）。
fn mark_active(state: ConnectionState) -> ConnectionState {
  ConnectionState(..state, active_since_heartbeat: True)
}

/// 直近のハートビート窓で受理したテキストフレーム数を1増やす（#156）。
fn record_message(state: ConnectionState) -> ConnectionState {
  ConnectionState(
    ..state,
    messages_since_heartbeat: state.messages_since_heartbeat + 1,
  )
}

/// `heartbeat_outcome` の判定を実行に反映する。`mist.stop_abnormal()` も
/// `mist.stop()` と同じく `on_close` を経由するので、room に参加済みなら通常の切断経路（`room.Leave` の dispatch
/// と registry への `Release`）がそのまま走る。
fn handle_heartbeat_tick(
  state: ConnectionState,
) -> Next(ConnectionState, ConnectionEvent) {
  case heartbeat_outcome(state.active_since_heartbeat) {
    HeartbeatTimedOut -> {
      logging.log(logging.Info, "websocket idle timeout: " <> connection_tag())
      mist.stop_abnormal("idle_timeout")
    }
    HeartbeatContinues -> {
      process.send_after(
        state.heartbeat_subject,
        state.heartbeat_interval_ms,
        HeartbeatTick,
      )
      mist.continue(
        ConnectionState(
          ..state,
          active_since_heartbeat: False,
          messages_since_heartbeat: 0,
          pings_since_heartbeat: 0,
        ),
      )
    }
  }
}

fn handle_text(
  state: ConnectionState,
  text: String,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  let state = record_message(state)
  // frame_size_outcome must be evaluated before message_rate_outcome: the
  // frame size limit's purpose is to cap the cost a single oversized frame
  // can force onto json.parse/broadcast regardless of connection state, so it
  // must not be short-circuited while a connection is already rate-limited
  // (#501).
  case frame_size_outcome(text) {
    FrameTooLarge -> {
      logging.log(
        logging.Info,
        "protocol message rejected: code=frame_too_large",
      )
      let #(code, message) = frame_too_large_code_and_message
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(code, message),
      )
      mist.stop_abnormal(code)
    }
    FrameSizeAccepted ->
      case message_rate_outcome(state.messages_since_heartbeat) {
        MessageRateLimited -> {
          logging.log(
            logging.Info,
            "protocol message rejected: code=rate_limited",
          )
          let #(code, message) = rate_limited_code_and_message
          // 拒否でも request_id を返し、クライアントが保留中の要求を
          // 解決できるようにする（#765）。
          send_server_message(
            connection,
            protocol.correlate(
              protocol.ProtocolErrorMessage(code, message),
              protocol.request_id(text),
            ),
          )
          mist.continue(state)
        }
        MessageRateAccepted ->
          case protocol.decode_client_message(text) {
            Error(error) -> {
              logging.log(
                logging.Info,
                "protocol message rejected: code=" <> error.code,
              )
              send_server_message(
                connection,
                protocol.correlate(
                  protocol.ProtocolErrorMessage(error.code, error.message),
                  protocol.request_id(text),
                ),
              )
              // 旧版のクライアントは以後の通知を正しく扱えないので、接続を
              // 残さずに閉じる（#765, ADR 0010）。
              case error == protocol.client_outdated_error {
                True -> mist.stop()
                False -> mist.continue(state)
              }
            }
            Ok(protocol.Join(wire_room_id, display_name)) ->
              handle_join(state, connection, wire_room_id, display_name)
            Ok(protocol.Create(display_name)) ->
              handle_create(state, connection, display_name)
            Ok(protocol.Watch(wire_room_id)) ->
              handle_watch(state, connection, wire_room_id)
            Ok(protocol.Buzz(round_id, request_id)) ->
              handle_buzz(state, connection, round_id, request_id)
            Ok(protocol.OpenAcceptance(round_id, request_id)) ->
              handle_host_command(state, connection, "open", request_id, fn(by) {
                room.OpenAcceptance(by, round_id)
              })
            Ok(protocol.CloseAcceptance(round_id, request_id)) ->
              handle_host_command(
                state,
                connection,
                "close",
                request_id,
                fn(by) { room.CloseAcceptance(by, round_id) },
              )
            Ok(protocol.Skip(round_id, request_id)) ->
              handle_host_command(state, connection, "skip", request_id, fn(by) {
                room.Skip(by, round_id)
              })
            Ok(protocol.NextQuestion(round_id, request_id)) ->
              handle_host_command(
                state,
                connection,
                "next_question",
                request_id,
                fn(by) { room.NextQuestion(by, round_id) },
              )
            Ok(protocol.TransferHost(to, request_id)) ->
              handle_host_command(
                state,
                connection,
                "transfer_host",
                request_id,
                fn(by) {
                  room.TransferHost(
                    by,
                    room.participant_id(wire.participant_id_to_string(to)),
                  )
                },
              )
            Ok(protocol.EndSession(request_id)) ->
              handle_host_command(
                state,
                connection,
                "end_session",
                request_id,
                fn(by) { room.EndSession(by) },
              )
            Ok(protocol.Resume(wire_room_id, instance_id, token, host_token)) ->
              handle_resume(
                state,
                connection,
                wire_room_id,
                instance_id,
                token,
                host_token,
              )
            Ok(protocol.Leave) -> handle_leave(state, connection)
            Ok(protocol.Sync) -> handle_sync(state, connection)
            Ok(protocol.Ping) -> handle_ping(state, connection)
          }
      }
  }
}

/// keepalive ping に `pong` を返す（#764）。生存の根拠はこのフレームを
/// 受信したことだけで（`handle_message` の `mark_active`）、room 配信や送信
/// 成功は根拠にしない。上限までの ping は `record_message` で数えた分を
/// 取り消し、通常操作のレート枠を使い切らせない。上限超過分は通常の
/// メッセージとして数え、ping の大量送信も `rate_limited` に行き着く。
fn handle_ping(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  let pings = state.pings_since_heartbeat + 1
  let state = ConnectionState(..state, pings_since_heartbeat: pings)
  let state = case ping_outcome(pings) {
    PingFree ->
      ConnectionState(
        ..state,
        messages_since_heartbeat: state.messages_since_heartbeat - 1,
      )
    PingCounted -> state
  }
  send_server_message(connection, protocol.Pong)
  mist.continue(state)
}

/// Applies the same frame size (#126) and message rate (#156) accounting as
/// `handle_text` to a binary frame, then rejects it as `binary_frame` once
/// both checks pass. Mirrors `handle_text`'s structure and evaluation order
/// (frame size before message rate, #501) so a connection cannot dodge either
/// limit by sending binary frames instead of text (#500).
fn handle_binary(
  state: ConnectionState,
  data: BitArray,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  let state = record_message(state)
  case frame_size_outcome_for_byte_size(bit_array.byte_size(data)) {
    FrameTooLarge -> {
      logging.log(
        logging.Info,
        "protocol message rejected: code=frame_too_large",
      )
      let #(code, message) = frame_too_large_code_and_message
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(code, message),
      )
      mist.stop_abnormal(code)
    }
    FrameSizeAccepted ->
      case message_rate_outcome(state.messages_since_heartbeat) {
        MessageRateLimited -> {
          logging.log(
            logging.Info,
            "protocol message rejected: code=rate_limited",
          )
          let #(code, message) = rate_limited_code_and_message
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(code, message),
          )
          mist.continue(state)
        }
        MessageRateAccepted -> {
          logging.log(
            logging.Info,
            "protocol message rejected: code=binary_frame",
          )
          let #(code, message) = binary_frame_code_and_message
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(code, message),
          )
          mist.continue(state)
        }
      }
  }
}

/// Maps a `room.JoinRejectReason` to the `code`/`message` pair sent to the
/// client. Pure and thus testable without a live `WebsocketConnection`, like
/// `frame_size_outcome` above.
pub fn join_reject_code_and_message(
  reason: room.JoinRejectReason,
) -> #(String, String) {
  case reason {
    room.RoomFull -> #(
      "room_full",
      "This room has reached its maximum number of participants.",
    )
    room.InvalidDisplayName -> #(
      "invalid_display_name",
      "The provided display name is not valid.",
    )
    room.AlreadyJoined -> #(
      "already_joined",
      "This connection has already joined a room.",
    )
    room.JoinSessionFinished -> session_finished_error
  }
}

/// The answer to joining, buzzing or running the host's commands after the
/// host ended the session (#768).
pub const session_finished_error = #(
  "session_finished",
  "This session has ended.",
)

fn handle_join(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_room_id: wire.RoomId,
  display_name: String,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    Some(handle) -> reject_already_joined(state, connection, handle)
    None -> {
      let room_id = registry.room_id(wire.room_id_to_string(wire_room_id))
      // 無いコードの部屋は作らない（#767）。期限切れの招待や打ち間違いから
      // 無断で同じコードの部屋ができると、別の集まりと取り違える。
      use room_subject <- with_existing_room(
        state,
        connection,
        room_id,
        room_not_found_error,
      )
      complete_join(
        state,
        connection,
        room_id,
        room_subject,
        display_name,
        False,
      )
    }
  }
}

/// 新しい部屋を作り、作った本人として参加する（#767）。部屋コードは
/// registry が発行し、司会 token と一緒にこの接続にだけ返す。
fn handle_create(
  state: ConnectionState,
  connection: WebsocketConnection,
  display_name: String,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    Some(handle) -> reject_already_joined(state, connection, handle)
    None ->
      case registry.create(state.registry) {
        Ok(#(room_id, room_subject)) ->
          complete_join(
            state,
            connection,
            room_id,
            room_subject,
            display_name,
            True,
          )
        Error(create_error) -> {
          let reason = case create_error {
            room_registry.CapacityReached -> RoomCapacityReached
            room_registry.Unavailable -> RoomLookupFailed
          }
          logging.log(
            logging.Warning,
            "room create failed: reason=" <> string.inspect(reason),
          )
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(
              "room_unavailable",
              room_unavailable_message(reason),
            ),
          )
          mist.continue(state)
        }
      }
  }
}

fn reject_already_joined(
  state: ConnectionState,
  connection: WebsocketConnection,
  handle: RoomHandle,
) -> Next(ConnectionState, ConnectionEvent) {
  logging.log(
    logging.Info,
    "already joined: room="
      <> registry.room_id_to_string(handle.room_id)
      <> ", participant="
      <> room.participant_id_to_string(handle.participant_id),
  )
  let #(code, message) = join_reject_code_and_message(room.AlreadyJoined)
  send_server_message(connection, protocol.ProtocolErrorMessage(code, message))
  mist.continue(state)
}

/// join（`created` が False）と作成直後の join（True）の共通部分。
fn complete_join(
  state: ConnectionState,
  connection: WebsocketConnection,
  room_id: registry.RoomId,
  room_subject: Subject(room.Message),
  display_name: String,
  created: Bool,
) -> Next(ConnectionState, ConnectionEvent) {
  let participant_id = room.participant_id(new_participant_id())
  let session = process.new_subject()
  let join = case created {
    True -> room.join_as_creator
    False -> room.join
  }

  // room が応答しなければ join を諦め、理由をクライアントへ返す（#33）。
  // 以前は actor.call のタイムアウトで**この接続プロセスごとクラッシュ**し、
  // クライアントには何も届かなかった。
  use reply <- with_join_reply(
    state.registry,
    room_id,
    room_subject,
    connection,
    join(room_subject, participant_id, display_name, session),
  )
  case reply {
    room.JoinReply(
      room.ParticipantJoined(participant, _),
      snapshot,
      resume_token,
      host_token,
    ) -> {
      logging.log(
        logging.Info,
        case created {
          True -> "room created and joined: room="
          False -> "join accepted: room="
        }
          <> registry.room_id_to_string(room_id)
          <> ", participant="
          <> room.participant_id_to_string(participant.id),
      )
      // スナップショットは join と同じ room メッセージの中で取られている
      // （`room.join`、#765）。以後この接続に届く配信は必ずこの revision
      // より新しく、取得時点のずれ（#121）や二重適用（#43）は起きない。
      // resume token（#766）と司会 token（#767）はこの応答でだけ本人に渡す。
      // 配信にもログにも出さない。
      let created_room_id = case created {
        True -> Some(registry.room_id_to_string(room_id))
        False -> None
      }
      send_server_message(
        connection,
        snapshot_message(
          snapshot,
          Some(participant.id),
          resume_token,
          created_room_id,
          host_token,
        ),
      )
      attached(
        state,
        room_subject,
        participant_id,
        session,
        room_id,
        snapshot,
        False,
      )
    }
    room.JoinReply(room.JoinRejected(_, reason), _, _, _) -> {
      logging.log(
        logging.Info,
        "join rejected: room="
          <> registry.room_id_to_string(room_id)
          <> ", reason="
          <> string.inspect(reason),
      )
      // 作ったばかりで誰もいない部屋は残さない。room 自身が空かを判定する。
      case created {
        True -> release_room(state.registry, room_id, room_subject)
        False -> Nil
      }
      let #(code, message) = join_reject_code_and_message(reason)
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(code, message),
      )
      mist.continue(state)
    }
    // `Join` never yields any other event; kept for exhaustiveness since
    // `room.RoomEvent` is shared across every room command.
    _ -> mist.continue(state)
  }
}

/// Records the room this connection is now attached to and starts receiving
/// its broadcasts (join and resume, #766).
fn attached(
  state: ConnectionState,
  room_subject: Subject(room.Message),
  participant_id: room.ParticipantId,
  session: Subject(room.RoomEvent),
  room_id: registry.RoomId,
  snapshot: room.Snapshot,
  is_display: Bool,
) -> Next(ConnectionState, ConnectionEvent) {
  let next_state =
    ConnectionState(
      ..state,
      room: Some(RoomHandle(
        room_subject,
        participant_id,
        session,
        room_id,
        snapshot.instance_id,
        is_display,
      )),
    )
  let selector =
    process.new_selector()
    |> process.select(state.heartbeat_subject)
    |> process.select_map(session, RoomBroadcast)
  mist.continue(next_state) |> mist.with_selector(selector)
}

/// Maps a `room.ResumeRejectReason` to the `code`/`message` pair sent to the
/// client (#766). Every reason leads the client to offer joining as a new
/// participant.
pub fn resume_reject_code_and_message(
  reason: room.ResumeRejectReason,
) -> #(String, String) {
  case reason {
    room.RoomGone -> #(
      "room_gone",
      "The room you were in has ended. Join as a new participant.",
    )
    room.ResumeExpired -> #(
      "resume_expired",
      "You were away too long and have left the room. Join as a new participant.",
    )
    room.InvalidToken -> #(
      protocol.invalid_token_error.code,
      protocol.invalid_token_error.message,
    )
  }
}

/// Sent before closing a connection whose participant resumed on another
/// connection (#766).
pub const session_replaced_message =
  "You reconnected from another tab or device, so this one was disconnected."

/// 保存済みの resume token で、同じ参加者として付け直す（#766）。
///
/// 部屋が無ければ作らずに `room_gone` を返す（#767）。
fn handle_resume(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_room_id: wire.RoomId,
  instance_id: String,
  token: String,
  host_token: Option(String),
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    Some(_) -> {
      let #(code, message) = join_reject_code_and_message(room.AlreadyJoined)
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(code, message),
      )
      mist.continue(state)
    }
    None -> {
      let room_id = registry.room_id(wire.room_id_to_string(wire_room_id))
      use room_subject <- with_existing_room(
        state,
        connection,
        room_id,
        resume_reject_code_and_message(room.RoomGone),
      )
      let session = process.new_subject()
      use reply <- with_join_reply(
        state.registry,
        room_id,
        room_subject,
        connection,
        room.resume_session(
          room_subject,
          token,
          host_token,
          instance_id,
          session,
        ),
      )
      case reply {
        room.Resumed(participant_id, snapshot) -> {
          logging.log(
            logging.Info,
            "resume accepted: room="
              <> registry.room_id_to_string(room_id)
              <> ", participant="
              <> room.participant_id_to_string(participant_id),
          )
          send_server_message(
            connection,
            snapshot_message(snapshot, Some(participant_id), None, None, None),
          )
          attached(
            state,
            room_subject,
            participant_id,
            session,
            room_id,
            snapshot,
            False,
          )
        }
        room.ResumeRejected(reason) -> {
          logging.log(
            logging.Info,
            "resume rejected: room="
              <> registry.room_id_to_string(room_id)
              <> ", reason="
              <> string.inspect(reason),
          )
          let #(code, message) = resume_reject_code_and_message(reason)
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(code, message),
          )
          mist.continue(state)
        }
      }
    }
  }
}

/// 会場表示として部屋を見る（#768）。参加者にはならず、token も無い。
/// 切れたら同じ `watch` で付け直せばよい。`participant_id` にはどの参加者
/// とも一致しない値を入れ、この接続から送られたコマンドは room が拒否する。
fn handle_watch(
  state: ConnectionState,
  connection: WebsocketConnection,
  wire_room_id: wire.RoomId,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    Some(handle) -> reject_already_joined(state, connection, handle)
    None -> {
      let room_id = registry.room_id(wire.room_id_to_string(wire_room_id))
      use room_subject <- with_existing_room(
        state,
        connection,
        room_id,
        room_not_found_error,
      )
      let session = process.new_subject()
      use reply <- with_join_reply(
        state.registry,
        room_id,
        room_subject,
        connection,
        room.watch(room_subject, session),
      )
      case reply {
        room.Watching(snapshot) -> {
          logging.log(
            logging.Info,
            "display attached: room=" <> registry.room_id_to_string(room_id),
          )
          send_server_message(
            connection,
            snapshot_message(snapshot, None, None, None, None),
          )
          attached(
            state,
            room_subject,
            room.participant_id(new_participant_id()),
            session,
            room_id,
            snapshot,
            True,
          )
        }
        room.DisplaysFull -> {
          logging.log(
            logging.Info,
            "display rejected: room="
              <> registry.room_id_to_string(room_id)
              <> ", reason=displays_full",
          )
          send_server_message(
            connection,
            protocol.ProtocolErrorMessage(
              "displays_full",
              "This room already has the maximum number of displays.",
            ),
          )
          mist.continue(state)
        }
      }
    }
  }
}

/// 明示的な退出（#766）。参加者をすぐに外し、resume token を無効にする。
/// 退出した接続には用が無いので閉じる。最後の参加者なら room も止まる。
fn handle_leave(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "leave", None)
      mist.continue(state)
    }
    Some(RoomHandle(is_display: True, ..) as handle) -> {
      room.unwatch(handle.subject, handle.session)
      mist.stop()
    }
    Some(handle) -> {
      case
        room.dispatch(
          handle.subject,
          room.Leave(handle.participant_id),
          handle.session,
        )
      {
        Ok(_) -> Nil
        Error(Nil) ->
          logging.log(
            logging.Warning,
            "leave dispatch failed: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> room.participant_id_to_string(handle.participant_id),
          )
      }
      // 空になったかどうかは room が自分のメールボックスの中で判定する（#36）。
      release_room(state.registry, handle.room_id, handle.subject)
      mist.stop()
    }
  }
}

/// The `state` message for a snapshot, seen from participant `self_id`, or
/// from a display when `self_id` is `None` (#768). `resume_token` is set only
/// when answering that participant's own join; `created_room_id` and
/// `host_token` only when answering the creator (#767).
fn snapshot_message(
  snapshot: room.Snapshot,
  self_id: Option(room.ParticipantId),
  resume_token: Option(String),
  created_room_id: Option(String),
  host_token: Option(String),
) -> protocol.ServerMessage {
  let self_role = case self_id {
    None -> protocol.DisplayRole
    Some(id) ->
      case list.find(snapshot.participants, fn(p) { p.id == id }) {
        Ok(room.Participant(role: room.Host, ..)) -> protocol.HostRole
        _ -> protocol.PlayerRole
      }
  }
  protocol.State(
    instance_id: snapshot.instance_id,
    self_id: option.map(self_id, to_wire_participant_id),
    self_role:,
    round_id: snapshot.round_id,
    revision: snapshot.revision,
    phase: to_wire_phase(snapshot.phase),
    participants: list.map(snapshot.participants, to_wire_participant),
    buzzes: list.map(snapshot.buzzes, to_wire_buzz_result),
    resume_token:,
    created_room_id:,
    host_token:,
  )
}

/// Sends a fresh `state` to a client that detected a missing revision
/// (#765). It is an ordinary message for rate limiting, so a client cannot
/// force unbounded snapshot work.
fn handle_sync(
  state: ConnectionState,
  connection: WebsocketConnection,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "sync", None)
      mist.continue(state)
    }
    Some(handle) ->
      case room.get_state(handle.subject) {
        Ok(snapshot) -> {
          // state を先に送る。溜まっている配信は state 以前のもの（重複として
          // 捨てられる）か、取得後に受理された新しいもの（state の次として
          // 適用される）なので、後から送れば表示が巻き戻らない。
          let self_id = case handle.is_display {
            True -> None
            False -> Some(handle.participant_id)
          }
          send_server_message(
            connection,
            snapshot_message(snapshot, self_id, None, None, None),
          )
          flush_queued_broadcasts(connection, handle)
          mist.continue(state)
        }
        Error(Nil) -> {
          logging.log(
            logging.Warning,
            "room unavailable: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", reason=sync_timed_out",
          )
          send_room_busy(connection, None)
          // 会場表示は接続を残したまま handle を捨てると、同じ接続から watch
          // し直すたびに購読が増えて8枠を使い切る。捨てる前に外す（#768）。
          case handle.is_display {
            True -> room.unwatch(handle.subject, handle.session)
            False -> Nil
          }
          mist.continue(ConnectionState(..state, room: None))
        }
      }
  }
}

/// Maps a `room.BuzzRejectReason` to the `code`/`message` pair sent to the
/// client. Pure and thus testable without a live `WebsocketConnection`, like
/// `join_reject_code_and_message` above.
pub fn buzz_reject_code_and_message(
  reason: room.BuzzRejectReason,
) -> #(String, String) {
  case reason {
    room.AlreadyBuzzed -> #(
      "already_buzzed",
      "This participant already buzzed for the current round.",
    )
    room.RoundFull -> #(
      "round_full",
      "This round has reached its buzz limit. Reset the round to continue.",
    )
    room.BuzzerNotJoined -> #(
      "buzzer_not_joined",
      "This connection has not joined the room yet.",
    )
    room.BuzzStaleRound -> #("stale_round", stale_round_message)
    room.NotAccepting -> #(
      "not_accepting",
      "Buzzes are not being accepted right now. Wait for the host to open.",
    )
    room.BuzzSessionFinished -> session_finished_error
    room.HostCannotBuzz -> #("forbidden", forbidden_message)
  }
}

/// Maps a `room.CommandRejectReason` (#768) to the `code`/`message` pair
/// sent to the client.
pub fn command_reject_code_and_message(
  reason: room.CommandRejectReason,
) -> #(String, String) {
  case reason {
    room.Forbidden -> #("forbidden", forbidden_message)
    room.StaleRound -> #("stale_round", stale_round_message)
    room.InvalidPhase -> #(
      "invalid_phase",
      "That is not possible at this stage of the question.",
    )
    room.SessionFinished -> session_finished_error
    room.SessionFull -> #(
      "session_full",
      "This session has reached its question limit.",
    )
    room.InvalidTarget -> #(
      "invalid_target",
      "The host role can only be given to a connected player.",
    )
    room.CommandNotJoined -> #("not_joined", not_joined_message)
  }
}

/// Sent when a command comes from someone whose role does not allow it
/// (#768): a player or a display running a host command, or the host
/// buzzing.
pub const forbidden_message = "Your role in this room cannot do that."

fn handle_buzz(
  state: ConnectionState,
  connection: WebsocketConnection,
  round_id: Int,
  request_id: Option(String),
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, "buzz", request_id)
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        request_id,
        room.dispatch(
          handle.subject,
          room.Buzz(handle.participant_id, round_id),
          handle.session,
        ),
      )
      case event {
        room.BuzzAccepted(id:, position:, ..) ->
          logging.log(
            logging.Info,
            "buzz accepted: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> room.participant_id_to_string(id)
              <> ", position="
              <> int.to_string(position),
          )
        room.BuzzRejected(id, reason) ->
          logging.log(
            logging.Info,
            "buzz rejected: room="
              <> registry.room_id_to_string(handle.room_id)
              <> ", participant="
              <> room.participant_id_to_string(id)
              <> ", reason="
              <> string.inspect(reason),
          )
        _ -> Nil
      }
      flush_queued_broadcasts(connection, handle)
      send_direct_reply(connection, handle.instance_id, event, request_id)
      mist.continue(state)
    }
  }
}

/// 司会の操作（#768）を room へ送る。司会かどうか・段階・ラウンドの判定は
/// すべて room が行い、ここは送られた接続の参加者を `by` として渡すだけ。
fn handle_host_command(
  state: ConnectionState,
  connection: WebsocketConnection,
  label: String,
  request_id: Option(String),
  make: fn(room.ParticipantId) -> room.RoomCommand,
) -> Next(ConnectionState, ConnectionEvent) {
  case state.room {
    None -> {
      send_not_joined_error(connection, label, request_id)
      mist.continue(state)
    }
    Some(handle) -> {
      use event <- with_room_reply(
        state,
        connection,
        request_id,
        room.dispatch(
          handle.subject,
          make(handle.participant_id),
          handle.session,
        ),
      )
      logging.log(
        logging.Info,
        "host command "
          <> label
          <> " "
          <> case event {
          room.CommandRejected(reason) ->
            "rejected (" <> string.inspect(reason) <> ")"
          _ -> "accepted"
        }
          <> ": room="
          <> registry.room_id_to_string(handle.room_id)
          <> ", by="
          <> room.participant_id_to_string(handle.participant_id),
      )
      flush_queued_broadcasts(connection, handle)
      send_direct_reply(connection, handle.instance_id, event, request_id)
      mist.continue(state)
    }
  }
}

/// Forwards room broadcasts that are already in this connection's mailbox
/// before a direct reply is sent (#765).
///
/// The room actor broadcasts a change before it replies, and messages from
/// one process arrive in order, so every broadcast older than the reply is
/// already queued here. Without this, the reply (revision N) would overtake a
/// queued broadcast (revision N-1) and the client would see a gap and resync
/// for nothing.
fn flush_queued_broadcasts(
  connection: WebsocketConnection,
  handle: RoomHandle,
) -> Nil {
  case process.receive(handle.session, 0) {
    Ok(event) -> {
      case room_event_to_server_message(event, handle.instance_id) {
        Some(message) -> send_server_message(connection, message)
        None -> Nil
      }
      flush_queued_broadcasts(connection, handle)
    }
    Error(Nil) -> Nil
  }
}

/// Sends the direct answer to a buzz/reset: the accepted change (which the
/// broadcast also delivers with the same revision) or the rejection, which
/// only the requester ever sees (#765).
fn send_direct_reply(
  connection: WebsocketConnection,
  instance_id: String,
  event: room.RoomEvent,
  request_id: Option(String),
) -> Nil {
  let message = case room_event_to_server_message(event, instance_id) {
    Some(message) -> Some(message)
    None ->
      case event {
        room.BuzzRejected(_, reason) -> {
          let #(code, text) = buzz_reject_code_and_message(reason)
          Some(protocol.ProtocolErrorMessage(code, text))
        }
        room.CommandRejected(reason) -> {
          let #(code, text) = command_reject_code_and_message(reason)
          Some(protocol.ProtocolErrorMessage(code, text))
        }
        _ -> None
      }
  }
  case message {
    Some(message) ->
      send_server_message(connection, protocol.correlate(message, request_id))
    None -> Nil
  }
}

/// Sent when a buzz or reset names a round that is no longer current
/// (#765). The client already has (or will receive) the newer round.
pub const stale_round_message =
  "That round has already ended. The screen shows the current round."

/// registry へ `Release` を送る。送信前に named subject の登録先を
/// `process.subject_owner` で確認し、registry が(再起動中などで)不在なら
/// パニックせずログだけ残して送信をスキップする（#116）。
///
/// `process.send` は named subject が未登録だと `let assert` で panic する
/// (`gleam_erlang` のドキュメントとは矛盾するが実装はそう)。registry は
/// supervisor 配下にあり再起動中は一時的に名前が外れうるため、無guardで
/// 呼ぶとその窓に閉じた接続が mist の接続プロセスごとクラッシュする。
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

/// Why a `room_unavailable`/`room_busy` error is being sent. Each call site
/// fails for a different reason and thus owes the client a different
/// explanation.
pub type RoomUnavailableReason {
  /// `registry.lookup` could not resolve or start the room actor.
  RoomLookupFailed
  /// `registry.lookup` rejected a new room because `max_rooms` was reached
  /// (#569). Retrying cannot help until another room ends.
  RoomCapacityReached
  /// `Join` was dispatched but no reply arrived in time.
  JoinTimedOut
  /// `Buzz`/`ResetRound` was dispatched but no reply arrived in time.
  ReplyTimedOut
}

/// Maps a `RoomUnavailableReason` to the message sent to the client. Pure
/// and thus testable without a live `WebsocketConnection`, like
/// `join_reject_code_and_message` above.
pub fn room_unavailable_message(reason: RoomUnavailableReason) -> String {
  case reason {
    RoomLookupFailed -> "The room could not be started. Please try again."
    RoomCapacityReached ->
      "The server is at room capacity. Try an existing room or wait until another room ends."
    JoinTimedOut -> "The room did not respond in time. Reconnect to try again."
    ReplyTimedOut -> "The room did not respond in time. Please try again."
  }
}

/// The answer to a join for a code that names no room (#767).
pub const room_not_found_error = #(
  "room_not_found",
  "No room has this code. It may have ended, or the code may be wrong.",
)

/// 既存の room を引けたときだけ `next` を実行する（#767）。部屋が無ければ
/// `not_found`（code, message）を返し、registry が応答しなければ
/// `room_unavailable` を返す。どちらも接続は維持する（#32）。
fn with_existing_room(
  state: ConnectionState,
  connection: WebsocketConnection,
  room_id: registry.RoomId,
  not_found: #(String, String),
  next: fn(Subject(room.Message)) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case registry.find(state.registry, room_id) {
    Ok(room_subject) -> next(room_subject)
    Error(registry.RoomNotFound) -> {
      logging.log(
        logging.Info,
        "room not found: room=" <> registry.room_id_to_string(room_id),
      )
      let #(code, message) = not_found
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(code, message),
      )
      mist.continue(state)
    }
    Error(registry.RegistryUnavailable) -> {
      logging.log(
        logging.Warning,
        "room unavailable: room=" <> registry.room_id_to_string(room_id),
      )
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "room_unavailable",
          room_unavailable_message(RoomLookupFailed),
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
  reply: Result(a, Nil),
  next: fn(a) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case reply {
    Ok(event) -> next(event)
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "room unavailable: room="
          <> registry.room_id_to_string(room_id)
          <> ", reason=join_timed_out",
      )
      // `lookup` がこの room を作った直後でも、ConnectionState にはまだ
      // RoomHandle が無い。そのまま接続を止めると on_close から Release されず、
      // 空の room actor が registry に残り続ける（#168）。room 自身が空かを
      // 判定するので、遅延した Join が先に成立していても停止させない。
      release_room(registry_subject, room_id, room_subject)
      send_server_message(
        connection,
        protocol.ProtocolErrorMessage(
          "room_unavailable",
          room_unavailable_message(JoinTimedOut),
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
///
/// `state.room` を `None` へ戻す（#100）。room actor が本当に死んでいた場合、
/// 戻さずにいると `handle_join` が生きているものと誤認して以後ずっと
/// `already_joined` を返し、接続は再 join も buzz/reset の再試行もできず
/// 永久にスタックする。room actor が単に詰まっているだけ（クラッシュして
/// いない）場合は、この後の再 join で新しい room 状態に参加し直す形に
/// なるが、応答不能を検知した時点でクライアントに再接続を促す方が、
/// 詰まったままの handle を握り続けるより安全側に倒れる。
///
/// クライアントへは `room_unavailable` ではなく専用の `room_busy` コードを
/// 送る（#570）。`room_unavailable` は join 前後どちらでも起こりうる
/// `RoomLookupFailed`/`JoinTimedOut` と共有されており、クライアント側は
/// code だけでは「まだ join していない」のか「join 済みの接続が一時的に
/// 詰まった」のかを区別できなかった（README.md/docs/mvp.md 参照）。
/// 後者専用の `room_busy` にすることで、クライアントは join 済みセッションの
/// 情報（`lastJoin` 相当）を保持したまま自動再接続できる。
fn with_room_reply(
  state: ConnectionState,
  connection: WebsocketConnection,
  request_id: Option(String),
  reply: Result(room.RoomEvent, Nil),
  next: fn(room.RoomEvent) -> Next(ConnectionState, ConnectionEvent),
) -> Next(ConnectionState, ConnectionEvent) {
  case reply {
    Ok(event) -> next(event)
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "room unavailable: room="
          <> case state.room {
          Some(handle) -> registry.room_id_to_string(handle.room_id)
          None -> "unknown"
        }
          <> ", reason=reply_timed_out",
      )
      send_room_busy(connection, request_id)
      mist.continue(ConnectionState(..state, room: None))
    }
  }
}

fn send_room_busy(
  connection: WebsocketConnection,
  request_id: Option(String),
) -> Nil {
  send_server_message(
    connection,
    protocol.correlate(
      protocol.ProtocolErrorMessage(
        "room_busy",
        room_unavailable_message(ReplyTimedOut),
      ),
      request_id,
    ),
  )
}

/// The message sent when a command arrives on a connection that has not
/// joined a room yet. Pure and thus testable without a live
/// `WebsocketConnection`, like `join_reject_code_and_message` above.
pub const not_joined_message = "Join a room before sending this command."

fn send_not_joined_error(
  connection: WebsocketConnection,
  command: String,
  request_id: Option(String),
) -> Nil {
  logging.log(
    logging.Info,
    "not joined: command=" <> command <> ", " <> connection_tag(),
  )
  send_server_message(
    connection,
    protocol.correlate(
      protocol.ProtocolErrorMessage("not_joined", not_joined_message),
      request_id,
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
  instance_id: String,
) -> Option(protocol.ServerMessage) {
  case event {
    room.ParticipantJoined(participant, revision) ->
      Some(protocol.ParticipantJoined(
        instance_id,
        revision,
        to_wire_participant(participant),
      ))
    room.ParticipantLeft(id, revision) ->
      Some(protocol.ParticipantLeft(
        instance_id,
        revision,
        to_wire_participant_id(id),
      ))
    room.BuzzAccepted(id, display_name, position, round_id, phase, revision) ->
      Some(protocol.BuzzAccepted(
        instance_id,
        revision,
        round_id,
        to_wire_participant_id(id),
        display_name,
        position,
        to_wire_phase(phase),
      ))
    room.RoundReset(round_id, revision) ->
      Some(protocol.RoundReset(instance_id, revision, round_id))
    room.PhaseChanged(phase, round_id, revision) ->
      Some(protocol.PhaseChanged(
        instance_id,
        revision,
        round_id,
        to_wire_phase(phase),
      ))
    room.HostTransferred(from, to, revision) ->
      Some(protocol.HostTransferred(
        instance_id,
        revision,
        to_wire_participant_id(from),
        to_wire_participant_id(to),
      ))
    // 新しい司会本人にだけ届く（room がその接続にだけ送る）。token なので
    // ログには出さない。
    room.HostAssigned(token) -> Some(protocol.HostAssigned(token))
    room.ParticipantDisconnected(id, revision) ->
      Some(protocol.ParticipantDisconnected(
        instance_id,
        revision,
        to_wire_participant_id(id),
      ))
    room.ParticipantReconnected(id, revision) ->
      Some(protocol.ParticipantReconnected(
        instance_id,
        revision,
        to_wire_participant_id(id),
      ))
    room.PresenceRejected(_) -> None
    // `handle_message` が配信を受けた時点で接続を閉じる。ワイヤには載せない。
    room.SessionReplaced -> None
    room.JoinRejected(_, _) -> None
    room.LeaveRejected(_, _) -> None
    room.BuzzRejected(_, _) -> None
    room.CommandRejected(_) -> None
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
    connected: participant.connected,
    role: case participant.role {
      room.Host -> protocol.HostRole
      room.Player -> protocol.PlayerRole
    },
  )
}

/// Converts a domain `Phase` to its wire representation (#768).
pub fn to_wire_phase(phase: room.Phase) -> protocol.Phase {
  case phase {
    room.Waiting -> protocol.Waiting
    room.Open -> protocol.Open
    room.Locked -> protocol.Locked
    room.Finished -> protocol.Finished
  }
}

/// Converts a domain `ParticipantId` to its wire representation. Pure and
/// unit-testable without a live connection (#24).
pub fn to_wire_participant_id(id: room.ParticipantId) -> wire.ParticipantId {
  wire.participant_id(room.participant_id_to_string(id))
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
