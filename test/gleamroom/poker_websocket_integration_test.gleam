import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleamroom
import gleamroom/poker_registry
import gleamroom/registry
import gramps/websocket as ws

/// `/poker/ws` を実際に生ソケットでハンドシェイクし、join → vote → reveal →
/// reset を1往復させる統合テスト（#281）。`websocket_integration_test.gleam`
/// と同じ手法（`gramps` + `gleamroom_ws_test_tcp.erl` で生 TCP を扱う）を使う。
pub type TcpSocket

@external(erlang, "gleamroom_ws_test_tcp", "connect")
fn tcp_connect(port: Int) -> Result(TcpSocket, String)

@external(erlang, "gleamroom_ws_test_tcp", "send")
fn tcp_send(socket: TcpSocket, data: BitArray) -> Result(Nil, String)

@external(erlang, "gleamroom_ws_test_tcp", "recv")
fn tcp_recv(socket: TcpSocket, timeout_ms: Int) -> Result(BitArray, String)

@external(erlang, "gleamroom_ws_test_tcp", "close")
fn tcp_close(socket: TcpSocket) -> Nil

pub fn poker_ws_roundtrip_join_vote_reveal_reset_test() {
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
  assert string.contains(join_reply, "\"phase\":\"voting\"")
  assert string.contains(join_reply, "\"display_name\":\"Alice\"")

  send_client_message(
    socket,
    json.object([#("type", json.string("vote")), #("value", json.string("5"))]),
  )
  let #(vote_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(vote_reply, "\"type\":\"vote_registered\"")
  // reveal 前に配信される `vote_registered` に投票値が含まれないことを
  // ワイヤ上で確認する（#281 の受け入れ基準）。
  assert !string.contains(vote_reply, "\"value\"")
  assert !string.contains(vote_reply, "\"5\"")
  // poker room actor は issuer 自身も含めて subscribers 全員へ broadcast
  // する（`poker.gleam`'s `broadcast` #143 と同じ理由: `dispatch` の同期
  // 応答が失われても非同期経路で届くように）。`websocket_integration_test.gleam`
  // の buzz_echo と同じ理由で、同一内容の2通目をここで読み捨てる。
  let #(vote_echo, buffer) = recv_text_message(socket, buffer)
  assert vote_echo == vote_reply

  send_client_message(socket, json.object([#("type", json.string("reveal"))]))
  let #(reveal_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(reveal_reply, "\"type\":\"revealed\"")
  assert string.contains(reveal_reply, "\"display_name\":\"Alice\"")
  assert string.contains(reveal_reply, "\"value\":\"5\"")
  let #(reveal_echo, buffer) = recv_text_message(socket, buffer)
  assert reveal_echo == reveal_reply

  send_client_message(socket, json.object([#("type", json.string("reset"))]))
  let #(reset_reply, _buffer) = recv_text_message(socket, buffer)
  assert reset_reply == "{\"type\":\"round_reset\"}"

  tcp_close(socket)
}

/// poker room actor が join 後に死ぬと、接続は再 join できるようになる
/// （`websocket_integration_test.gleam`'s `ws_rejoins_after_room_actor_dies_test`
/// と同じ理由、#100）。
pub fn poker_ws_rejoins_after_room_actor_dies_test() {
  let assert Ok(registry_started) = registry.start()
  let assert Ok(poker_registry_started) = poker_registry.start()
  let poker_registry_subject = poker_registry_started.data
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(
      registry_started.data,
      poker_registry_subject,
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
    poker_registry.lookup(
      poker_registry_subject,
      poker_registry.room_id("ROOM1"),
    )
  let assert Ok(room_pid) = process.subject_owner(room_subject)
  process.kill(room_pid)
  // room actor の死が registry/接続双方に伝播するのを待つ。
  process.sleep(50)

  send_client_message(
    socket,
    json.object([#("type", json.string("vote")), #("value", json.string("5"))]),
  )
  let #(vote_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(vote_reply, "\"type\":\"error\"")
  assert string.contains(vote_reply, "\"code\":\"room_unavailable\"")

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

/// `docs/mvp.md`・`docs/planning-poker.md` が明示的に約束している
/// 「`frame_too_large` の後は接続が閉じる」というクライアント可視の契約を、
/// 実ソケットで検証する。`websocket_integration_test.gleam`'s
/// `ws_closes_after_frame_too_large_test` と同じ理由（#445）を `/poker/ws`
/// 側の配線（`poker_websocket.gleam`'s `handle_text`）に対して行う。
pub fn poker_ws_closes_after_frame_too_large_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  send_raw_text_frame(socket, string.repeat("a", 2049))
  let #(error_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(error_reply, "\"type\":\"error\"")
  assert string.contains(error_reply, "\"code\":\"frame_too_large\"")

  // `mist.stop()` makes mist send a standard WebSocket close frame (RFC
  // 6455 §5.5.1) before it actually closes the underlying TCP socket; the
  // close frame and the TCP close may or may not land in the same `recv`
  // depending on scheduling, so consume the close frame explicitly before
  // asserting the socket itself is closed.
  let assert <<>> = recv_close_frame(socket, buffer)
  let assert Error(_) = tcp_recv(socket, 2000)

  tcp_close(socket)
}

/// `docs/mvp.md`・`docs/planning-poker.md` が明示的に約束している
/// 「`rate_limited` の後も接続は継続する」というクライアント可視の契約を、
/// 実ソケットで検証する。`websocket_integration_test.gleam`'s
/// `ws_continues_after_rate_limited_test` と同じ理由（#449）を `/poker/ws`
/// 側の配線（`poker_websocket.gleam`'s `handle_text`）に対して行う。
pub fn poker_ws_continues_after_rate_limited_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let #(socket, buffer) = handshake(port, 50)

  // `max_messages_per_heartbeat_window` (30) に達するまで送って応答を捨てる。
  let buffer = send_and_drain_reveal(socket, buffer, 30)

  // 31件目は上限超過なので rate_limited を受け取る。
  send_client_message(socket, json.object([#("type", json.string("reveal"))]))
  let #(rate_limited_reply, buffer) = recv_text_message(socket, buffer)
  assert string.contains(rate_limited_reply, "\"type\":\"error\"")
  assert string.contains(rate_limited_reply, "\"code\":\"rate_limited\"")

  // 接続はまだ生きている: もう1通送っても close frame ではなく応答が返る。
  send_client_message(socket, json.object([#("type", json.string("reveal"))]))
  let #(still_alive_reply, _buffer) = recv_text_message(socket, buffer)
  assert string.contains(still_alive_reply, "\"type\":\"error\"")

  tcp_close(socket)
}

/// `reveal` メッセージを `count` 件送り、応答を1件ずつ読み捨てる。
fn send_and_drain_reveal(
  socket: TcpSocket,
  buffer: BitArray,
  count: Int,
) -> BitArray {
  case count {
    0 -> buffer
    _ -> {
      send_client_message(
        socket,
        json.object([#("type", json.string("reveal"))]),
      )
      let #(_reply, buffer) = recv_text_message(socket, buffer)
      send_and_drain_reveal(socket, buffer, count - 1)
    }
  }
}

/// `Origin` が `Host` と一致しない接続を実HTTP経由で 403 拒否する
/// (CSWSH対策、#124)。`websocket_integration_test.gleam` の
/// `ws_rejects_origin_mismatch_test` と同じ検証を `/poker/ws` 側の配線
/// (`poker_websocket.gleam` の `upgrade`)に対して行う（#430）。
pub fn poker_ws_rejects_origin_mismatch_test() {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  let socket = connect_with_retry(port, 50)

  let key = ws.make_client_key()
  let request =
    "GET /poker/ws HTTP/1.1\r\n"
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

/// `/poker/ws` へ生ソケットで接続し、RFC 6455 ハンドシェイクを成立させる。
/// サーバはまだ listen していないことがあるので、接続自体もリトライする。
fn handshake(port: Int, attempts_remaining: Int) -> #(TcpSocket, BitArray) {
  upgrade(connect_with_retry(port, attempts_remaining), port)
}

/// `/poker/ws` へ生ソケットで接続する（ハンドシェイクは行わない）。サーバは
/// まだ listen していないことがあるので、接続自体をリトライする。
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
    "GET /poker/ws HTTP/1.1\r\n"
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
  case ws.decode_frame(buffer, None) {
    Ok(#(ws.Complete(ws.Control(ws.CloseFrame(_))), rest)) -> rest
    Ok(#(_, _)) -> panic as "close frame を期待したが別のフレームを受信した"
    Error(_) -> {
      let assert Ok(chunk) = tcp_recv(socket, 2000)
      recv_close_frame(socket, <<buffer:bits, chunk:bits>>)
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
