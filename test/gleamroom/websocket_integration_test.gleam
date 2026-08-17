import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleamroom
import gleamroom/registry
import gramps/websocket as ws

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

  send_client_message(socket, json.object([#("type", json.string("reset"))]))
  let #(reset_reply, _buffer) = recv_text_message(socket, buffer)
  assert reset_reply == "{\"type\":\"round_reset\"}"

  tcp_close(socket)
}

/// room actor が join 後に死ぬと、接続は再 join できるようになる（#100）。
///
/// 以前は `state.room` を死んだ handle に固定したまま更新せず、以後の
/// buzz/reset は `room_unavailable` を返し続け、再 join も
/// `already_joined` で拒否され続けて接続が永久にスタックしていた。
/// 修正後は `room.dispatch` の失敗時に `state.room` を `None` へ戻すため、
/// 同じ接続からの再 join が新しい room に参加できる。
pub fn ws_rejoins_after_room_actor_dies_test() {
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(registry_subject)
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
  assert string.contains(buzz_reply, "\"code\":\"room_unavailable\"")

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

/// `/ws` へ生ソケットで接続し、RFC 6455 ハンドシェイクを成立させる。
/// サーバはまだ listen していないことがあるので、接続自体もリトライする。
fn handshake(port: Int, attempts_remaining: Int) -> #(TcpSocket, BitArray) {
  case tcp_connect(port), attempts_remaining {
    Ok(socket), _ -> upgrade(socket, port)
    Error(_), 0 -> panic as "サーバが期限内に listen しなかった"
    Error(_), _ -> {
      process.sleep(20)
      handshake(port, attempts_remaining - 1)
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
  let mask = crypto.strong_random_bytes(4)
  let frame = ws.encode_text_frame(json.to_string(body), None, Some(mask))
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
