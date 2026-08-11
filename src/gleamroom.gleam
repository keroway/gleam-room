import envoy
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleamroom/registry
import gleamroom/web
import gleamroom/websocket
import logging
import mist.{type Connection, type ResponseData}

const default_port = 4000

/// docs/architecture.md の「Supervision and lifecycle」が示す構成を実際に組む（#23）。
///
///     Application supervisor
///       +-- Room registry
///       +-- Web server
///
/// 以前は registry と mist を `let assert Ok(...)` で個別に起動しているだけで、
/// 親子関係も再起動戦略も無かった。どちらかが落ちても他方は生き続け、
/// **HTTP は 200 を返すのに join だけが無反応**という状態になりえた。
///
/// `rest_for_one` を選ぶ理由: web server は registry に依存するが逆は依存しない。
/// registry が落ちたら web server も作り直す必要がある（古い名前解決を握った
/// 接続を残さないため）。逆に web server だけが落ちた場合は registry を巻き込まない。
///
/// 子の順序は依存の順序。registry を先に立ててから web server を立てる。
pub fn main() -> Nil {
  logging.configure()

  let port = read_port()
  // 名前を経由することで、registry が再起動しても HTTP ハンドラは
  // 現行のプロセスへ届く（起動時の subject を握らない）。
  let registry_name = process.new_name("gleamroom_registry")
  let registry_subject = process.named_subject(registry_name)

  let assert Ok(_) =
    supervisor.new(supervisor.RestForOne)
    |> supervisor.add(
      supervision.worker(fn() { registry.start_named(registry_name) }),
    )
    |> supervisor.add(mist.supervised(
      handle_request(_, registry_subject)
      |> mist.new
      |> mist.port(port),
    ))
    |> supervisor.start

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

/// `PORT` 環境変数から待ち受けポートを読む。
///
/// **未設定と「設定されているが不正」を区別する**（#29）。以前はどちらも
/// `result.unwrap(default_port)` で吸収しており、`PORT=abc` のようなタイポが
/// 警告もログも出さずに既定ポートで起動していた。設定したつもりの人からは
/// 「なぜか反映されない」としか見えず、原因に辿り着けない。
///
/// - 未設定: 意図された既定動作。静かに `default_port` を使う
/// - 不正値: 設定ミス。**警告を出してから** `default_port` を使う
///
/// 起動自体は続ける。ポートが違っても他は正常に動くため、ここで落とすと
/// 「動くはずのものが上がらない」ほうの害が大きい。
pub fn read_port() -> Int {
  case envoy.get("PORT") {
    Error(Nil) -> default_port
    Ok(raw) ->
      case int.parse(raw) {
        Ok(port) -> port
        Error(Nil) -> {
          logging.log(
            logging.Warning,
            "PORT="
              <> raw
              <> " は整数として解釈できません。既定の "
              <> int.to_string(default_port)
              <> " 番で起動します。",
          )
          default_port
        }
      }
  }
}
