import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleamroom
import gleamroom/poker_registry
import gleamroom/registry
import gleamroom/wait
import gleamroom/websocket
import gramps/websocket as ws
import mist.{type Connection}

/// `/ws` を実際に生ソケットでハンドシェイクし、join → buzz → reset を1往復
/// させる統合テスト（#158）。
///
/// これまでの `/ws` のテストは、素の GET が 400 を返すこと
/// (`routing_test.gleam`) と `room.dispatch`/`registry.lookup` を直接呼ぶ
/// こと(`integration_test.gleam`) だけを検証しており、実際の RFC 6455
/// ハンドシェイクと `protocol.decode_client_message` → `websocket.handle_text`
/// → `mist.send_text_frame` というワイヤー経路そのものを通したテストが
/// 無かった。`mist` の推移的依存である `gramps`（フレームの符号化・復号と
/// `Sec-WebSocket-Accept` の計算を既に提供）を直接依存として使い、新規の
/// WebSocket クライアント依存は増やさない。
///
/// `gleam_erlang` は生ソケットを公開していないため、`gen_tcp` を薄く包む
/// `test/gleamroom_ws_test_tcp.erl` を経由する。
pub type TcpSocket

@external(erlang, "gleamroom_ws_test_tcp", "connect")
fn tcp_connect(port: Int) -> Result(TcpSocket, String)

@external(erlang, "gleamroom_ws_test_tcp", "send")
fn tcp_send(socket: TcpSocket, data: BitArray) -> Result(Nil, String)

@external(erlang, "gleamroom_ws_test_tcp", "recv")
fn tcp_recv(socket: TcpSocket, timeout_ms: Int) -> Result(BitArray, String)

@external(erlang, "gleamroom_ws_test_tcp", "close")
fn tcp_close(socket: TcpSocket) -> Nil

/// room actor を生かしたまま応答不能にする（#532）。詳細は
/// `gleamroom_room_test_ffi.erl` を参照。
@external(erlang, "gleamroom_room_test_ffi", "suspend")
fn suspend_process(pid: process.Pid) -> Nil

@external(erlang, "gleamroom_room_test_ffi", "resume")
fn resume_process(pid: process.Pid) -> Nil

pub fn ws_roundtrip_join_buzz_reset_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  send_client_message(
    socket,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("ROOM1")),
      #("display_name", json.string("Alice")),
    ]),
  )
  let #(join_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(join_reply, "\"type\":\"state\"")
  assert string.contains(join_reply, "\"display_name\":\"Alice\"")

  send_client_message(socket, json.object([#("type", json.string("buzz"))]))
  let #(buzz_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(buzz_reply, "\"type\":\"buzz_accepted\"")
  assert string.contains(buzz_reply, "\"display_name\":\"Alice\"")
  assert string.contains(buzz_reply, "\"position\":1")
  // The room actor also broadcasts `buzz_accepted` back to the buzzer's own
  // session (#143: this is what lets a late reply after a `dispatch`
  // timeout still reach the client), so a second, identical copy of the
  // frame above follows on the wire. The client already treats this as
  // idempotent (dedup by buzz position); drain it here so it does not
  // shadow the `round_reset` assertion below.
  let #(buzz_echo, buffer) = recv_text_message(socket, buffer)
  assert buzz_echo == buzz_reply

  send_client_message(socket, json.object([#("type", json.string("reset"))]))
  let #(reset_reply, buffer) = recv_text_message(socket, buffer)
  assert reset_reply == "{\"type\":\"round_reset\"}"
  // `RoundReset` is on the same issuer-inclusive `broadcast_all` branch as
  // `Buzz` (#143, #465), so it also echoes back a second, identical copy;
  // pin that the same way `buzz_echo` above already is.
  let #(reset_echo, _buffer) = recv_text_message(socket, buffer)
  assert reset_echo == reset_reply

  tcp_close(socket)
}

/// room actor が join 後に死ぬと、接続は再 join できるようになる（#100）。
///
/// 以前は `state.room` を死んだ handle に固定したまま更新せず、以後の
/// buzz/reset は `room_unavailable` を返し続け、再 join も
/// `already_joined` で拒否され続けて接続が永久にスタックしていた。
/// 修正後は `room.dispatch` の失敗時に `state.room` を `None` へ戻すため、
/// 同じ接続からの再 join が新しい room に参加できる。エラーコードは #570 で
/// `room_unavailable` から専用の `room_busy` へ変更された。
pub fn ws_rejoins_after_room_actor_dies_test() {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data
  let assert Ok(poker_registry_started) = poker_registry.start()
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(
      registry_subject,
      poker_registry_started.data,
    )
  let #(socket, buffer) = handshake(port, 50)

  send_client_message(
    socket,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("ROOM1")),
      #("display_name", json.string("Alice")),
    ]),
  )
  let #(join_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(join_reply, "\"type\":\"state\"")

  let assert Ok(room_subject) =
    registry.lookup(registry_subject, registry.room_id("ROOM1"))
  let assert Ok(room_pid) = process.subject_owner(room_subject)
  process.kill(room_pid)
  // room actor の死が registry/接続双方に伝播するのを待つ。
  process.sleep(50)

  send_client_message(socket, json.object([#("type", json.string("buzz"))]))
  let #(buzz_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(buzz_reply, "\"type\":\"error\"")
  assert string.contains(buzz_reply, "\"code\":\"room_busy\"")

  send_client_message(
    socket,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("ROOM1")),
      #("display_name", json.string("Alice")),
    ]),
  )
  let #(rejoin_reply, _buffer) = recv_text_message(socket, buffer)
  assert string.contains(rejoin_reply, "\"type\":\"state\"")
  assert !string.contains(rejoin_reply, "already_joined")

  tcp_close(socket)
}

/// room を引けない（MAX_ROOMS 到達で `registry.lookup` が `CapacityReached`）join は
/// `room_unavailable` を返すが、接続は切らない（`with_room`、#32 / #572）。
///
/// `with_join_reply` の `JoinTimedOut` は `mist.stop()` で接続を切るのと正反対の
/// 挙動で、両者が入れ替わっても他のテストでは検知できなかった。上限1の
/// registry で ROOM1 を埋め、同じ接続で ROOM2 に join して拒否された後、
/// ROOM1 へ join し直せる（= 接続が生きている）ことを確かめる。
pub fn ws_keeps_connection_after_room_lookup_failed_test() {
  let assert Ok(registry_started) = registry.start_with_max_rooms(1)
  let assert Ok(poker_registry_started) = poker_registry.start()
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(
      registry_started.data,
      poker_registry_started.data,
    )
  let #(alice, alice_buffer) = handshake(port, 50)
  let #(bob, bob_buffer) = handshake(port, 50)

  // Alice が ROOM1 を作り、上限（1）に達する。
  send_client_message(
    alice,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("ROOM1")),
      #("display_name", json.string("Alice")),
    ]),
  )
  let #(alice_reply, _alice_buffer) = recv_text_message(alice, alice_buffer)
  assert string.contains(alice_reply, "\"type\":\"state\"")

  send_client_message(
    bob,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("ROOM2")),
      #("display_name", json.string("Bob")),
    ]),
  )
  let #(rejected, bob_buffer) = recv_text_message(bob, bob_buffer)
  assert string.contains(rejected, "\"type\":\"error\"")
  assert string.contains(rejected, "\"code\":\"room_unavailable\"")
  assert string.contains(rejected, "The server is at room capacity.")

  // 接続は維持されている: 既存の ROOM1 へは同じ接続から join できる。
  send_client_message(
    bob,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("ROOM1")),
      #("display_name", json.string("Bob")),
    ]),
  )
  let #(joined, _bob_buffer) = recv_text_message(bob, bob_buffer)
  assert string.contains(joined, "\"type\":\"state\"")

  tcp_close(alice)
  tcp_close(bob)
}

/// buzz/reset のタイムアウトで `state.room` が `None` に戻った後、再joinせず
/// 切断しても、room actor 自身の `SessionDown` 経由で参加者が正しく片付く
/// こと（#532）。
///
/// `with_room_reply`（websocket.gleam）は room actor が `call.default_timeout`
/// （1000ms）以内に応答しないと `state.room` を `None` へ戻す（#100）。この
/// 状態のまま接続が閉じると `on_close` は `state.room == None` の枝に入り、
/// `Leave` dispatch も `release_room` も呼ばない —— 後始末は room actor
/// 自身が接続プロセスの死を検知する `SessionDown` だけに委ねられる。この
/// 組み合わせを実サーバー越しに駆動する統合テストが無かった（#532 の指摘）。
///
/// `process.kill` で room actor を殺すと `ActorDown`（#100 と同じ経路だが
/// 相手が死んでいる）になり、その room actor自体が居なくなるので後段の
/// `SessionDown` を発火させる相手がいなくなる
/// （`ws_rejoins_after_room_actor_dies_test` はその経路）。ここでは
/// `erlang:suspend_process/1` で room actor のスケジューリングだけを止め、
/// **生きたまま**応答不能にする —— `ReplyTimedOut` が実際に起こる状況
/// （GC やメッセージ滞留で詰まっているだけで死んではいない）により近い。
pub fn ws_cleans_up_via_session_down_after_reply_timeout_test() {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data
  let assert Ok(poker_registry_started) = poker_registry.start()
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(
      registry_subject,
      poker_registry_started.data,
    )
  let #(socket, buffer) = handshake(port, 50)

  send_client_message(
    socket,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("STUCK1")),
      #("display_name", json.string("Alice")),
    ]),
  )
  let #(join_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(join_reply, "\"type\":\"state\"")

  let room_id = registry.room_id("STUCK1")
  let assert Ok(room_subject) = registry.lookup(registry_subject, room_id)
  let assert Ok(room_pid) = process.subject_owner(room_subject)

  // room actor を生かしたまま応答不能にする。
  suspend_process(room_pid)

  send_client_message(socket, json.object([#("type", json.string("buzz"))]))
  // `recv_text_message` は必要ならフレームが揃うまで `tcp_recv` を繰り返す
  // ので、1000ms のタイムアウトが経過して `room_busy` が届くまで待てる。
  let #(buzz_reply, _buffer) = recv_text_message(socket, buffer)
  assert string.contains(buzz_reply, "\"type\":\"error\"")
  assert string.contains(buzz_reply, "\"code\":\"room_busy\"")

  // 再joinせずにここで切断する。on_close は state.room == None の枝に入り
  // Leave dispatch も release_room も呼ばない。
  tcp_close(socket)

  // room actor を再開させ、キューに溜まっていた接続プロセスの `ProcessDown`
  // （`SessionDown` へ変換される）を処理させる。無人になれば room actor は
  // 自己停止し、registry からも外れる（room.gleam の `SessionDown` 分岐）。
  resume_process(room_pid)

  wait.until(
    fn() { !process.is_alive(room_pid) },
    "無人になった room actor が SessionDown 経由で自己停止する",
  )
  // `registry.lookup` は cache miss だと room を新規に起動してしまう
  // （get-or-create）ため、片付いたことの確認には使えない。実数を返す
  // `registry.health` で見る。
  wait.until(
    fn() {
      case registry.health(registry_subject) {
        Ok(registry.HealthSnapshot(rooms: 0, ..)) -> True
        _ -> False
      }
    },
    "room actor の自己停止後、registry からも外れる",
  )
}

/// join のディスパッチがタイムアウトした場合（`with_join_reply` の
/// `Error(Nil)` 分岐、#571）のクライアント可視の契約を実ソケットで検証する。
/// `room_unavailable` を返して**接続を閉じ**、遅れて成立した Join の参加者が
/// 残っても room actor は registry から外れる。
///
/// 事前に `registry.lookup` で room を作って suspend しておき、join が応答
/// 不能な room へ向かうようにする。`release_room` の呼び出し自体は
/// `SessionDown` による自己停止と結果が重なるため、ここでは分離して検証
/// できない（room が詰まっている間は `shutdown_if_empty` も応答しない）。
/// 検証しているのは、この経路の終端状態（エラー・切断・registry の空き）である。
pub fn ws_closes_and_cleans_up_after_join_timeout_test() {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data
  let assert Ok(poker_registry_started) = poker_registry.start()
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(
      registry_subject,
      poker_registry_started.data,
    )

  let room_id = registry.room_id("JSTUCK1")
  let assert Ok(room_subject) = registry.lookup(registry_subject, room_id)
  let assert Ok(room_pid) = process.subject_owner(room_subject)
  suspend_process(room_pid)

  let #(socket, buffer) = handshake(port, 50)
  send_client_message(
    socket,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("JSTUCK1")),
      #("display_name", json.string("Alice")),
    ]),
  )
  let #(error_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(error_reply, "\"type\":\"error\"")
  assert string.contains(error_reply, "\"code\":\"room_unavailable\"")

  // 結果不明のタイムアウトでは再試行を促さず、接続を閉じる。
  let assert <<>> = recv_close_frame(socket, buffer)
  let assert Error(_) = tcp_recv(socket, 2000)
  tcp_close(socket)

  // 遅れて成立する Join と、その接続プロセスの `SessionDown` を処理させる。
  resume_process(room_pid)

  wait.until(
    fn() { !process.is_alive(room_pid) },
    "join タイムアウト後、無人の room actor が自己停止する",
  )
  wait.until(
    fn() {
      case registry.health(registry_subject) {
        Ok(registry.HealthSnapshot(rooms: 0, ..)) -> True
        _ -> False
      }
    },
    "room actor の自己停止後、registry からも外れる",
  )
}

/// `docs/mvp.md`・`docs/planning-poker.md` が明示的に約束している
/// 「`frame_too_large` の後は接続が閉じる」というクライアント可視の契約を、
/// 実ソケットで検証する（#445）。これまでは `frame_too_large_code_and_message`
/// という定数値だけが `websocket_test.gleam` で assert されており、
/// 実装が `mist.stop()` の代わりに `mist.continue()` を返す一行の変更でも
/// 検知できなかった。
pub fn ws_closes_after_frame_too_large_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  send_raw_text_frame(socket, string.repeat("a", 2049))
  let #(error_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(error_reply, "\"type\":\"error\"")
  assert string.contains(error_reply, "\"code\":\"frame_too_large\"")

  // `mist.stop_abnormal(code)` makes mist send a close frame (RFC 6455
  // §5.5.1) with code 4000 and the error code as the reason (#567) before it
  // actually closes the underlying TCP socket; the close frame and the TCP
  // close may or may not land in the same `recv` depending on scheduling, so
  // consume the close frame explicitly before asserting the socket itself is
  // closed.
  let #(reason, rest) = recv_close_reason(socket, buffer)
  assert reason
    == ws.CustomCloseReason(4000, bit_array.from_string("frame_too_large"))
  assert rest == <<>>
  let assert Error(_) = tcp_recv(socket, 2000)

  tcp_close(socket)
}

/// `docs/mvp.md`・`docs/planning-poker.md` が明示的に約束している
/// 「`rate_limited` の後も接続は継続する」というクライアント可視の契約を、
/// 実ソケットで検証する（#449）。`frame_too_large` とは異なり `handle_text`
/// は `MessageRateLimited` に対して `mist.stop()` ではなく `mist.continue()`
/// を返すため、上限超過後もソケットは生きたままで応答し続けなければならない。
/// これまでは `message_rate_outcome` の閾値判定だけが純粋関数として
/// テストされており、`handle_text` がこの結果を `mist.continue()` に
/// 正しくつなぐことは検証されていなかった。
pub fn ws_continues_after_rate_limited_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  // `max_messages_per_heartbeat_window` (30) に達するまで送って応答を捨てる。
  let buffer = send_and_drain_buzz(socket, buffer, 30)

  // 31件目は上限超過なので rate_limited を受け取る。
  send_client_message(socket, json.object([#("type", json.string("buzz"))]))
  let #(rate_limited_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(rate_limited_reply, "\"type\":\"error\"")
  assert string.contains(rate_limited_reply, "\"code\":\"rate_limited\"")

  // 接続はまだ生きている: もう1通送っても close frame ではなく応答が返る。
  send_client_message(socket, json.object([#("type", json.string("buzz"))]))
  let #(still_alive_reply, _buffer) = recv_text_message(socket, buffer)
  assert string.contains(still_alive_reply, "\"type\":\"error\"")

  tcp_close(socket)
}

/// `handle_text` は `frame_size_outcome` を `message_rate_outcome` より先に
/// 評価する(#501)。レート制限中でも巨大フレームは `rate_limited` ではなく
/// `frame_too_large` で拒否され、接続が閉じることを実ソケットで検証する。
/// 修正前はこの経路で `frame_size_outcome` が評価されず、`rate_limited` を
/// 受け取ったまま接続が生き続けていた。
pub fn ws_closes_after_frame_too_large_while_rate_limited_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  // `max_messages_per_heartbeat_window` (30) に達するまで送って応答を捨てる。
  let buffer = send_and_drain_buzz(socket, buffer, 30)

  // 31件目はレート制限に該当する状態だが、巨大フレームなので
  // `frame_too_large` を受け取り、接続は閉じるはずである。
  send_raw_text_frame(socket, string.repeat("a", 2049))
  let #(error_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(error_reply, "\"type\":\"error\"")
  assert string.contains(error_reply, "\"code\":\"frame_too_large\"")

  let assert <<>> = recv_close_frame(socket, buffer)
  let assert Error(_) = tcp_recv(socket, 2000)

  tcp_close(socket)
}

/// バイナリフレームもテキストフレームと同じフレームサイズ上限(#126)に
/// 従うことを実ソケットで検証する(#500)。修正前は `mist.Binary` 分岐が
/// `frame_size_outcome` を一切評価せず、上限超過分の `bit_array` を送り
/// 続けてもサーバが無制限に受理していた。
pub fn ws_closes_after_binary_frame_too_large_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  send_raw_binary_frame(socket, bit_array.from_string(string.repeat("a", 2049)))
  let #(error_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(error_reply, "\"type\":\"error\"")
  assert string.contains(error_reply, "\"code\":\"frame_too_large\"")

  let assert <<>> = recv_close_frame(socket, buffer)
  let assert Error(_) = tcp_recv(socket, 2000)

  tcp_close(socket)
}

/// バイナリフレームもテキストフレームと同じメッセージレート上限(#156)の
/// カウンタに計上されることを実ソケットで検証する(#500)。修正前は
/// `mist.Binary` 分岐が `record_message` を一切呼ばず、バイナリフレームを
/// 送り続けてもレート制限に一切引っかからなかった。
pub fn ws_binary_frames_count_toward_rate_limit_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  // `max_messages_per_heartbeat_window` (30) に達するまで送って応答を捨てる。
  // 各バイナリフレームは `binary_frame` エラーを返すが、それでもカウンタは
  // 進む。
  let buffer = send_and_drain_binary(socket, buffer, 30)

  // 31件目は上限超過なので、`binary_frame` ではなく `rate_limited` を受け取る。
  send_raw_binary_frame(socket, bit_array.from_string("x"))
  let #(rate_limited_reply, _buffer) = recv_text_message(socket, buffer)
  assert string.contains(rate_limited_reply, "\"type\":\"error\"")
  assert string.contains(rate_limited_reply, "\"code\":\"rate_limited\"")

  tcp_close(socket)
}

/// バイナリフレームを `count` 件送り、応答を1件ずつ読み捨てる。
fn send_and_drain_binary(
  socket: TcpSocket,
  buffer: BitArray,
  count: Int,
) -> BitArray {
  case count {
    0 -> buffer
    _ -> {
      send_raw_binary_frame(socket, bit_array.from_string("x"))
      let #(_reply, buffer) = recv_text_message(socket, buffer)
      send_and_drain_binary(socket, buffer, count - 1)
    }
  }
}

/// `buzz` メッセージを `count` 件送り、応答を1件ずつ読み捨てる。
fn send_and_drain_buzz(
  socket: TcpSocket,
  buffer: BitArray,
  count: Int,
) -> BitArray {
  case count {
    0 -> buffer
    _ -> {
      send_client_message(socket, json.object([#("type", json.string("buzz"))]))
      let #(_reply, buffer) = recv_text_message(socket, buffer)
      send_and_drain_buzz(socket, buffer, count - 1)
    }
  }
}

/// `Origin` が `Host` と一致しない接続を実HTTP経由で 403 拒否する
/// (CSWSH対策、#124)。`websocket.origin_header_allowed` 自体は
/// `websocket_test.gleam` で純粋関数として検証済みだが、それを呼び出す
/// `upgrade` 関数の配線(実際に 403 レスポンスが返ること)は、この
/// テストが無いと検知できなかった（#430）。
pub fn ws_rejects_origin_mismatch_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let socket = connect_with_retry(port, 50)

  let key = ws.make_client_key()
  let request =
    "GET /ws HTTP/1.1\r\n"
    <> "Host: 127.0.0.1:"
    <> int.to_string(port)
    <> "\r\n"
    <> "Upgrade: websocket\r\n"
    <> "Connection: Upgrade\r\n"
    <> "Sec-WebSocket-Key: "
    <> key
    <> "\r\n"
    <> "Sec-WebSocket-Version: 13\r\n"
    <> "Origin: https://evil.example\r\n"
    <> "\r\n"
  let assert Ok(Nil) = tcp_send(socket, bit_array.from_string(request))

  let #(header_text, _leftover) = read_response_headers(socket, <<>>)
  assert string.starts_with(header_text, "HTTP/1.1 403")

  tcp_close(socket)
}

/// `/ws` へ生ソケットで接続し、RFC 6455 ハンドシェイクを成立させる。
/// サーバはまだ listen していないことがあるので、接続自体もリトライする。
fn handshake(port: Int, attempts_remaining: Int) -> #(TcpSocket, BitArray) {
  upgrade(connect_with_retry(port, attempts_remaining), port)
}

/// `/ws` へ生ソケットで接続する（ハンドシェイクは行わない）。サーバはまだ
/// listen していないことがあるので、接続自体をリトライする。
fn connect_with_retry(port: Int, attempts_remaining: Int) -> TcpSocket {
  case tcp_connect(port), attempts_remaining {
    Ok(socket), _ -> socket
    Error(_), 0 -> panic as "サーバが期限内に listen しなかった"
    Error(_), _ -> {
      process.sleep(20)
      connect_with_retry(port, attempts_remaining - 1)
    }
  }
}

fn upgrade(socket: TcpSocket, port: Int) -> #(TcpSocket, BitArray) {
  let key = ws.make_client_key()
  let request =
    "GET /ws HTTP/1.1\r\n"
    <> "Host: 127.0.0.1:"
    <> int.to_string(port)
    <> "\r\n"
    <> "Upgrade: websocket\r\n"
    <> "Connection: Upgrade\r\n"
    <> "Sec-WebSocket-Key: "
    <> key
    <> "\r\n"
    <> "Sec-WebSocket-Version: 13\r\n"
    <> "\r\n"
  let assert Ok(Nil) = tcp_send(socket, bit_array.from_string(request))

  let #(header_text, leftover) = read_response_headers(socket, <<>>)
  assert string.starts_with(header_text, "HTTP/1.1 101")
  let expected_accept =
    "sec-websocket-accept: " <> string.lowercase(ws.parse_websocket_key(key))
  assert string.contains(string.lowercase(header_text), expected_accept)

  #(socket, leftover)
}

/// `\r\n\r\n` (ヘッダ終端) が現れるまで読み続け、ヘッダ本文と、それ以降に
/// 一緒に届いてしまったバイト列(まだ読んでいない WS フレームの先頭)を分ける。
fn read_response_headers(
  socket: TcpSocket,
  acc: BitArray,
) -> #(String, BitArray) {
  let assert Ok(acc_text) = bit_array.to_string(acc)
  case string.split_once(acc_text, "\r\n\r\n") {
    Ok(#(header_text, rest)) -> #(header_text, bit_array.from_string(rest))
    Error(Nil) -> {
      let assert Ok(chunk) = tcp_recv(socket, 2000)
      read_response_headers(socket, <<acc:bits, chunk:bits>>)
    }
  }
}

fn send_client_message(socket: TcpSocket, body: json.Json) -> Nil {
  send_raw_text_frame(socket, json.to_string(body))
}

/// Reads until a WebSocket close frame (RFC 6455 §5.5.1) is decoded, then
/// returns whatever bytes followed it (normally none).
fn recv_close_frame(socket: TcpSocket, buffer: BitArray) -> BitArray {
  let #(_reason, rest) = recv_close_reason(socket, buffer)
  rest
}

/// `recv_close_frame` と同じだが、close frame の code/reason も返す(#567)。
fn recv_close_reason(
  socket: TcpSocket,
  buffer: BitArray,
) -> #(ws.CloseReason, BitArray) {
  case ws.decode_frame(buffer, None) {
    Ok(#(ws.Complete(ws.Control(ws.CloseFrame(reason))), rest)) -> #(
      reason,
      rest,
    )
    Ok(#(_, _)) -> panic as "close frame を期待したが別のフレームを受信した"
    Error(_) -> {
      let assert Ok(chunk) = tcp_recv(socket, 2000)
      recv_close_reason(socket, <<buffer:bits, chunk:bits>>)
    }
  }
}

/// `frame_size_outcome` only inspects byte size, so an oversized frame does
/// not need to be valid JSON.
fn send_raw_text_frame(socket: TcpSocket, text: String) -> Nil {
  let mask = crypto.strong_random_bytes(4)
  let frame = ws.encode_text_frame(text, None, Some(mask))
  let assert Ok(Nil) = tcp_send(socket, bytes_tree.to_bit_array(frame))
  Nil
}

/// `send_raw_text_frame` と同じ理由・実装だが、`mist.Binary` 分岐を通す
/// バイナリフレームを送る(#500)。
fn send_raw_binary_frame(socket: TcpSocket, data: BitArray) -> Nil {
  let mask = crypto.strong_random_bytes(4)
  let frame = ws.encode_binary_frame(data, None, Some(mask))
  let assert Ok(Nil) = tcp_send(socket, bytes_tree.to_bit_array(frame))
  Nil
}

/// 1件のテキストフレームを読み、その本文と、まだ消費していない残りバイト列
/// (次のフレームの先頭)を返す。サーバ→クライアントのフレームは RFC 6455 上
/// マスクされない。
fn recv_text_message(
  socket: TcpSocket,
  buffer: BitArray,
) -> #(String, BitArray) {
  case ws.decode_frame(buffer, None) {
    Ok(#(ws.Complete(ws.Data(ws.TextFrame(payload))), rest)) -> {
      let assert Ok(text) = bit_array.to_string(payload)
      #(text, rest)
    }
    Ok(#(_, _)) -> panic as "予期しない WebSocket フレーム種別を受信した"
    Error(_) -> {
      let assert Ok(chunk) = tcp_recv(socket, 2000)
      recv_text_message(socket, <<buffer:bits, chunk:bits>>)
    }
  }
}

/// ハートビート間隔（実時間では30秒）を差し替えたサーバを起動し、実ポートを返す。
/// 短い間隔にすることで、`RoomBroadcast` 受信による延命（#581）を gleeunit の
/// テスト時間上限（約50秒）内で検証できる（#613）。
fn start_server_with_heartbeat_interval(interval_ms: Int) -> Int {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data
  let bound_port = process.new_subject()
  let assert Ok(_) =
    fn(req: Request(Connection)) {
      websocket.upgrade_with_heartbeat_interval(
        req,
        registry_subject,
        interval_ms,
      )
    }
    |> mist.new
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(bound_port, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(bound_port, 1000)
  port
}

/// join だけして以後は何も送らない接続は、他参加者の操作による room 配信を
/// 受け取り続ける限りハートビートで切断されない（#581 / #613）。
///
/// 間隔は300ms。Bob が100msごとに `reset` を送り、Alice は5窓分（1.5秒）の間
/// 一切何も送らずに配信だけを受け取る。`RoomBroadcast` 分岐の `mark_active`
/// が落ちると Alice は2回目の tick（600ms）で閉じられ、以降のフレームを
/// 受け取れなくなる。
pub fn ws_room_broadcast_keeps_silent_connection_alive_test() {
  let port = start_server_with_heartbeat_interval(300)
  let #(alice, alice_buffer) = handshake(port, 50)
  let #(bob, bob_buffer) = handshake(port, 50)
  let alice_buffer = join_and_drain(alice, alice_buffer, "Alice")
  let _bob_buffer = join_and_drain(bob, bob_buffer, "Bob")
  // Bob の join は Alice にも配信される。以降の assert を単純にするため読み捨てる。
  let #(joined, alice_buffer) = recv_text_message(alice, alice_buffer)
  assert string.contains(joined, "\"type\":\"participant_joined\"")

  let alice_buffer = relay_resets(bob, alice, alice_buffer, 15)

  // 1.5秒後（tick 5回分）でも Alice は生きていて、最後の配信も届く。
  send_client_message(bob, json.object([#("type", json.string("reset"))]))
  let #(reply, _buffer) = recv_text_message(alice, alice_buffer)
  assert reply == "{\"type\":\"round_reset\"}"

  tcp_close(alice)
  tcp_close(bob)
}

/// 上のテストの対照実験。何も送らず、room 配信も無い接続は、同じ間隔設定で
/// 2回目の tick に閉じられる。これが成り立つから、上のテストが「延命された」
/// ことを意味する（間隔の差し替えが効いている証拠にもなる）。
pub fn ws_silent_connection_without_broadcast_times_out_test() {
  let port = start_server_with_heartbeat_interval(300)
  let #(alice, alice_buffer) = handshake(port, 50)
  let alice_buffer = join_and_drain(alice, alice_buffer, "Alice")

  let #(reason, _rest) = recv_close_reason(alice, alice_buffer)
  assert reason
    == ws.CustomCloseReason(4000, bit_array.from_string("idle_timeout"))
  tcp_close(alice)
}

fn join_and_drain(
  socket: TcpSocket,
  buffer: BitArray,
  display_name: String,
) -> BitArray {
  send_client_message(
    socket,
    json.object([
      #("type", json.string("join")),
      #("room_id", json.string("HEARTBEAT")),
      #("display_name", json.string(display_name)),
    ]),
  )
  let #(join_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(join_reply, "\"type\":\"state\"")
  buffer
}

/// `sender` が100msごとに `reset` を `count` 回送り、`receiver` はそのたびに
/// 届く `round_reset` 配信を読み捨てる。`receiver` 側は何も送らない。
fn relay_resets(
  sender: TcpSocket,
  receiver: TcpSocket,
  buffer: BitArray,
  count: Int,
) -> BitArray {
  case count {
    0 -> buffer
    _ -> {
      process.sleep(100)
      send_client_message(
        sender,
        json.object([#("type", json.string("reset"))]),
      )
      let #(reply, buffer) = recv_text_message(receiver, buffer)
      assert reply == "{\"type\":\"round_reset\"}"
      relay_resets(sender, receiver, buffer, count - 1)
    }
  }
}
