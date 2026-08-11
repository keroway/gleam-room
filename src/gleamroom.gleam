import envoy
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/result
import gleamroom/registry
import gleamroom/web
import gleamroom/websocket
import logging
import mist.{type Connection, type ResponseData}

const default_port = 4000

pub fn main() -> Nil {
  logging.configure()

  let port = read_port()
  let assert Ok(registry_started) = registry.start()
  let registry_subject = registry_started.data

  let assert Ok(_) =
    handle_request(_, registry_subject)
    |> mist.new
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

fn handle_request(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
) -> Response(ResponseData) {
  case request.path_segments(req) {
    [] ->
      response.new(200)
      |> response.set_header("content-type", "text/html; charset=utf-8")
      |> response.set_body(mist.Bytes(bytes_tree.from_string(web.index_html())))

    ["health"] ->
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))

    ["ws"] -> websocket.upgrade(req, registry_subject)

    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

/// Reads the HTTP port from the `PORT` environment variable, falling back to
/// `default_port` when it is unset or not a valid integer.
fn read_port() -> Int {
  envoy.get("PORT")
  |> result.try(int.parse)
  |> result.unwrap(default_port)
}
