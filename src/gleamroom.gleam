import envoy
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http.{Get, Head}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import gleamroom/call
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

  // supervisor が shutdown した場合に無言でプロセスが消えるのを避ける（#79）。
  //
  // `supervisor.start` は呼び出し元プロセス（= main）に supervisor を
  // link する。intensity/period の許容回数（既定・下記どちらも 5 秒間に
  // 2 回）を超えて子が再起動すると、supervisor は全子を terminate してから
  // 自身も reason `shutdown` で終了し、その exit signal が main まで伝播する。
  // trap_exits で受け止めて exit を明示的にログしてから終了させる。
  process.trap_exits(True)

  let assert Ok(started) = start(read_port())

  await_supervisor_exit(started.pid)
}

/// supervisor（または他の何らかの理由で main にリンクされたプロセス）の
/// exit を待ち、supervisor 自身の exit だけをログしてから戻る。
///
/// 未知の pid からの exit は無視して待ち続ける。現状 main にリンクされる
/// プロセスは supervisor だけだが、将来リンクが増えても無関係な exit で
/// アプリ全体の終了ログを誤って出さないようにするため。
fn await_supervisor_exit(supervisor_pid: process.Pid) -> Nil {
  let exit =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
    |> process.selector_receive_forever()

  case exit.pid == supervisor_pid {
    True ->
      logging.log(
        logging.Emergency,
        "アプリ最上位 supervisor が終了したため、アプリケーションを終了します: "
          <> string.inspect(exit.reason),
      )
    False -> await_supervisor_exit(supervisor_pid)
  }
}

/// スーパービジョンツリーを起動して返す（#34）。
///
/// `main` から切り出したのは**テストから起動できるようにするため**。
/// `main` は `sleep_forever` で戻らないので、HTTP ルーティングを実際に
/// 叩いて確かめる手段が無かった。
///
/// registry の名前は呼び出しごとに新しく作る。同じ VM で複数回起動しても
/// 名前が衝突しない（テストが本番と同じ経路を通れる）。
pub fn start(
  port: Int,
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  // 名前を経由することで、registry が再起動しても HTTP ハンドラは
  // 現行のプロセスへ届く（起動時の subject を握らない）。
  let registry_name = process.new_name("gleamroom_registry")
  let registry_subject = process.named_subject(registry_name)

  supervisor.new(supervisor.RestForOne)
  // `intensity`/`period` を明示する（#79）。値そのものは gleam_otp の既定
  // （5 秒間に 2 回）のままだが、無指定だと「意図して既定値を選んだ」のか
  // 「設定を忘れた」のか読み手が区別できない。MVP の規模で子は2つだけ
  // （registry, web server）で、どちらも `let assert` によるクラッシュ経路を
  // 持たないため、この既定値で十分という判断をここに残す。将来クラッシュ
  // 経路が増えて頻繁な再起動が正常系になるなら、そのときに見直す。
  |> supervisor.restart_tolerance(intensity: 2, period: 5)
  |> supervisor.add(
    supervision.worker(fn() { registry.start_named(registry_name) }),
  )
  |> supervisor.add(mist.supervised(
    handle_request(_, registry_subject)
    |> mist.new
    |> mist.port(port),
  ))
  |> supervisor.start
}

fn handle_request(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
) -> Response(ResponseData) {
  case request.path_segments(req) {
    [] ->
      case req.method {
        Get | Head ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(web.index_html())),
          )
          |> empty_body_for_head(req.method)
        _ -> method_not_allowed(["GET", "HEAD"])
      }

    // **registry に実際に問い合わせてから答える（#93）。**
    //
    // 以前は無条件に 200 "ok" を返していた。それでは `main` のコメントが
    // 問題として挙げている「HTTP は 200 を返すのに join だけが無反応」を
    // まさに検出できない。registry が死んでいても詰まっていても緑になる。
    //
    // supervisor が registry を再起動している最中もここは失敗する。
    // それは正しい: その瞬間 join は通らないので、503 を返して
    // ロードバランサやヘルスチェックに「まだ受けられない」と伝えるべき。
    ["health"] ->
      case req.method {
        Get | Head ->
          case registry.health(registry_subject) {
            Ok(rooms) ->
              response.new(200)
              |> response.set_body(
                mist.Bytes(bytes_tree.from_string(
                  "ok rooms=" <> int.to_string(rooms),
                )),
              )
            // **理由を分けて伝える（#92）。** どちらも 503 だが、運用者が次に
            // 見る場所が違う。落ちているなら supervisor の再起動状況、
            // 詰まっているなら負荷やタイムアウト値。
            Error(reason) ->
              response.new(503)
              |> response.set_body(
                mist.Bytes(
                  bytes_tree.from_string(case reason {
                    call.ActorDown -> "registry down"
                    call.Timeout -> "registry not responding"
                    call.Unknown(detail) -> "registry unavailable: " <> detail
                  }),
                ),
              )
          }
          |> empty_body_for_head(req.method)
        _ -> method_not_allowed(["GET", "HEAD"])
      }

    ["ws"] -> websocket.upgrade(req, registry_subject)

    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

/// HEAD は GET と同じヘッダを返しつつボディを送ってはならない（RFC 9110 §9.3.2）。
///
/// ステータス・ヘッダは GET と同じ組み立てを再利用し、最後にボディだけ
/// 差し替える。エラー分岐（503 など）でも同様に空にする必要があるため、
/// レスポンス組み立ての末尾に一括で適用する。
fn empty_body_for_head(
  resp: Response(ResponseData),
  method: http.Method,
) -> Response(ResponseData) {
  case method {
    Head -> response.set_body(resp, mist.Bytes(bytes_tree.new()))
    _ -> resp
  }
}

/// パスは一致したが HTTP メソッドが対応外のときに返す（#66）。
///
/// 以前は `request.path_segments` だけでルーティングしており、
/// POST / や DELETE /health でも同じ 200 が返っていた。
fn method_not_allowed(allowed: List(String)) -> Response(ResponseData) {
  response.new(405)
  |> response.set_header("allow", string.join(allowed, ", "))
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

/// `PORT` 環境変数から待ち受けポートを読む。
///
/// **未設定と「設定されているが不正」を区別する**（#29）。以前はどちらも
/// `result.unwrap(default_port)` で吸収しており、`PORT=abc` のようなタイポが
/// 警告もログも出さずに既定ポートで起動していた。設定したつもりの人からは
/// 「なぜか反映されない」としか見えず、原因に辿り着けない。
///
/// - 未設定: 意図された既定動作。静かに `default_port` を使う
/// - 不正値(数値として解釈できない、または 1-65535 の範囲外): 設定ミス。
///   **警告を出してから** `default_port` を使う
///
/// 起動自体は続ける。ポートが違っても他は正常に動くため、ここで落とすと
/// 「動くはずのものが上がらない」ほうの害が大きい。
pub fn read_port() -> Int {
  case envoy.get("PORT") {
    Error(Nil) -> default_port
    Ok(raw) ->
      case int.parse(raw) {
        Ok(port) if port >= 1 && port <= 65_535 -> port
        Ok(_) -> {
          logging.log(
            logging.Warning,
            "PORT="
              <> raw
              <> " は有効なポート番号(1-65535)の範囲外です。既定の "
              <> int.to_string(default_port)
              <> " 番で起動します。",
          )
          default_port
        }
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
