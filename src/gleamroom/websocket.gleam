import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None}
import mist.{
  type Connection, type Next, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}

/// Upgrades an HTTP request to a WebSocket connection and wires it to a
/// minimal echo/ping-pong handler. This module only deals with wire-level
/// transport; it intentionally carries no room or game state so later
/// issues can translate messages into typed domain commands here without
/// touching `gleamroom.gleam`.
pub fn upgrade(req: Request(Connection)) -> Response(ResponseData) {
  mist.websocket(
    request: req,
    handler: handle_message,
    on_init: on_init,
    on_close: on_close,
  )
}

fn on_init(
  _connection: WebsocketConnection,
) -> #(Nil, Option(process.Selector(Nil))) {
  #(Nil, None)
}

fn on_close(_state: Nil) -> Nil {
  Nil
}

fn handle_message(
  state: Nil,
  message: WebsocketMessage(Nil),
  connection: WebsocketConnection,
) -> Next(Nil, Nil) {
  case message {
    mist.Text(text) -> {
      let _ = mist.send_text_frame(connection, reply_for(text))
      mist.continue(state)
    }
    // Binary frames and custom/actor messages are accepted but not acted
    // on yet; ignoring them keeps the connection alive instead of crashing.
    mist.Binary(_data) -> mist.continue(state)
    mist.Custom(_message) -> mist.continue(state)
    mist.Closed -> mist.stop()
    mist.Shutdown -> mist.stop()
  }
}

/// Pure text-in/text-out policy for the echo/ping-pong transport check.
/// Kept separate from the handler so it can be unit tested without a live
/// WebSocket connection.
pub fn reply_for(text: String) -> String {
  case text {
    "ping" -> "pong"
    other -> other
  }
}
