import gleamroom/websocket
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn websocket_reply_for_ping_is_pong_test() {
  assert websocket.reply_for("ping") == "pong"
}

pub fn websocket_reply_for_other_text_is_echoed_test() {
  assert websocket.reply_for("hello") == "hello"
}

pub fn websocket_reply_for_empty_text_is_echoed_test() {
  assert websocket.reply_for("") == ""
}
