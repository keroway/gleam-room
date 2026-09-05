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
import gleamroom/poker_registry
import gleamroom/poker_websocket
import gleamroom/registry
import gleamroom/web
import gleamroom/web_poker
import gleamroom/websocket
import logging
import mist.{type Connection, type ResponseData}

const default_port = 4000

/// docs/architecture.md の「Supervision and lifecycle」が示す構成を実際に組む（#23）。
///
///     Application supervisor
///       +-- Room registry (buzzer)
///       +-- Room registry (poker)
///       +-- Web server
///
/// 以前は registry と mist を `let assert Ok(...)` で個別に起動しているだけで、
/// 親子関係も再起動戦略も無かった。どちらかが落ちても他方は生き続け、
/// **HTTP は 200 を返すのに join だけが無反応**という状態になりえた。
///
/// `one_for_one` を選ぶ理由（#78）: 以前は `rest_for_one` を使っていたが、
/// その根拠（「web server は registry に依存するので、registry が落ちたら
/// 古い名前解決を握った web server も作り直す必要がある」）は誤りだった。
/// web server に渡す `registry_subject` は `process.named_subject` で、
/// 名前解決は送信のたびに引き直される。registry が再起動して新プロセスに
/// 差し替わっても、mist 側は何も作り直さずに新しい registry へ届く。
/// にもかかわらず `rest_for_one` は registry の後ろに追加した mist（と、
/// その配下で稼働中の全 WebSocket 接続）を registry のクラッシュのたびに
/// 巻き添えで再起動していた。room 単位の障害分離という設計原則
/// （ADR 0002）に反して、registry の障害が無関係な全 room の接続断として
/// 全体へ波及していたため、`one_for_one` へ変更し registry と web server を
/// 独立して再起動できるようにする。
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

  case start(read_port()) {
    Ok(started) -> await_supervisor_exit(started.pid, halt_with_failure)
    Error(reason) -> {
      // #29 / #32 / #53 と同じ方針: 失敗を無警告でクラッシュさせず、
      // 理由をログに残してから終了する（#136）。
      logging.log(
        logging.Error,
        "gleamroom failed to start: reason=" <> string.inspect(reason),
      )
      panic as "gleamroom failed to start"
    }
  }
}

/// supervisor（または他の何らかの理由で main にリンクされたプロセス）の
/// exit を待ち、supervisor 自身の exit をログしてから `on_exit` を呼ぶ。
///
/// 未知の pid からの exit は無視して待ち続ける。現状 main にリンクされる
/// プロセスは supervisor だけだが、将来リンクが増えても無関係な exit で
/// アプリ全体の終了ログを誤って出さないようにするため。
///
/// `on_exit` を引数として受け取るのは、`erlang:halt` を直接呼ぶとプロセスが
/// 実際に終了しテストランナーごと落ちるため、テストからは差し替え可能に
/// しておく必要があるから（#189/#190）。本番呼び出しは常に
/// `halt_with_failure`。
pub fn await_supervisor_exit(
  supervisor_pid: process.Pid,
  on_exit: fn() -> Nil,
) -> Nil {
  let exit =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
    |> process.selector_receive_forever()

  case exit.pid == supervisor_pid {
    True -> {
      logging.log(
        logging.Emergency,
        "アプリ最上位 supervisor が終了したため、アプリケーションを終了します: "
          <> string.inspect(exit.reason),
      )
      on_exit()
    }
    False -> await_supervisor_exit(supervisor_pid, on_exit)
  }
}

/// 非ゼロ終了コードでプロセスを終了する（#189）。
///
/// `main` が値を返して正常 return すると OS からの終了コードは 0 になり、
/// `restart_tolerance` 超過で supervisor が shutdown した致命的な状況が
/// exit code に反映されない。systemd の `Restart=on-failure` 等、exit code
/// を再起動判定に使う運用で自動検知できるようにするため、明示的に
/// `erlang:halt(1)` を呼ぶ。
fn halt_with_failure() -> Nil {
  erlang_halt(1)
}

@external(erlang, "erlang", "halt")
fn erlang_halt(code: Int) -> Nil

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
  let poker_registry_name = process.new_name("gleamroom_poker_registry")
  let poker_registry_subject = process.named_subject(poker_registry_name)

  supervisor.new(supervisor.OneForOne)
  // `intensity`/`period` を明示する（#79）。値そのものは gleam_otp の既定
  // （5 秒間に 2 回）のままだが、無指定だと「意図して既定値を選んだ」のか
  // 「設定を忘れた」のか読み手が区別できない。子は3つ（buzzer registry,
  // poker registry, web server）で、どれも `let assert` によるクラッシュ
  // 経路を持たないため、この既定値で十分という判断をここに残す。将来
  // クラッシュ経路が増えて頻繁な再起動が正常系になるなら、そのときに見直す。
  |> supervisor.restart_tolerance(intensity: 2, period: 5)
  |> supervisor.add(
    supervision.worker(fn() { registry.start_named(registry_name) }),
  )
  // buzzer と隔離された poker room actor 用の registry（#279）。
  // `one_for_one` の下で buzzer registry / web server とは独立して起動・
  // 再起動できる。`/health` も両方の registry を問い合わせる（#285）。
  |> supervisor.add(
    supervision.worker(fn() { poker_registry.start_named(poker_registry_name) }),
  )
  |> supervisor.add(mist.supervised(
    handle_request(_, registry_subject, poker_registry_subject)
    |> mist.new
    |> mist.port(port),
  ))
  |> supervisor.start
}

/// `start` の、ポートをOSに動的採番させる版（#152）。
///
/// テストが固定ポートを使うと、CI・開発機でそのポートが既に他プロセスに
/// 専有されている場合に、ルーティング自体とは無関係な bind 失敗で落ちる。
/// ポート `0` を渡すとOSが空きポートを選んで bind するため、この衝突自体が
/// 起こらなくなる。実際に採番されたポートは mist の `after_start` フックで
/// 受け取り、呼び出し元へ返す。
pub fn start_on_ephemeral_port() -> Result(
  #(Int, actor.Started(supervisor.Supervisor)),
  actor.StartError,
) {
  let registry_name = process.new_name("gleamroom_registry")
  let registry_subject = process.named_subject(registry_name)
  let poker_registry_name = process.new_name("gleamroom_poker_registry")
  let poker_registry_subject = process.named_subject(poker_registry_name)

  let bound_port = process.new_subject()

  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 2, period: 5)
  |> supervisor.add(
    supervision.worker(fn() { registry.start_named(registry_name) }),
  )
  |> supervisor.add(
    supervision.worker(fn() { poker_registry.start_named(poker_registry_name) }),
  )
  |> supervisor.add(mist.supervised(
    handle_request(_, registry_subject, poker_registry_subject)
    |> mist.new
    |> with_ephemeral_port(bound_port),
  ))
  |> supervisor.start
  |> with_bound_port(bound_port)
}

/// registry を外部から注入して web server だけを起動する（#142）。
///
/// `start` は registry の名前を呼び出しごとに内部生成するため、テストから
/// 「停止した／無応答の registry」を差し込む手段が無い。`/health` の 503 分岐
/// （`call.ActorDown` / `call.Timeout`）を実サーバ越しに検証するには、意図的に
/// 壊れた `registry_subject` を渡して web server だけを直接起動する必要がある。
/// ポートは CI・開発機での衝突を避けるため OS に動的採番させる（#152）。
pub fn start_web_only_on_ephemeral_port(
  registry_subject: Subject(registry.Message),
  poker_registry_subject: Subject(poker_registry.Message),
) -> Result(#(Int, actor.Started(supervisor.Supervisor)), actor.StartError) {
  let bound_port = process.new_subject()

  handle_request(_, registry_subject, poker_registry_subject)
  |> mist.new
  |> with_ephemeral_port(bound_port)
  |> mist.start
  |> with_bound_port(bound_port)
}

/// ポート `0`（OS動的採番）を割り当て、実際に採番されたポートを
/// `bound_port` へ送るよう `after_start` を設定する。
fn with_ephemeral_port(
  builder: mist.Builder(a, b),
  bound_port: Subject(Int),
) -> mist.Builder(a, b) {
  builder
  |> mist.port(0)
  |> mist.after_start(fn(port, _scheme, _ip_address) {
    process.send(bound_port, port)
  })
}

/// `with_ephemeral_port` が送った実ポートを `Result` へ合流させる。
///
/// `mist.after_start` はサーバが listen を開始した時点で同期的に呼ばれる
/// （`supervisor.start`/`mist.start` が戻る前）ため、ここでの `receive` は
/// 待ちぼうけにならない。
fn with_bound_port(
  result: Result(actor.Started(a), actor.StartError),
  bound_port: Subject(Int),
) -> Result(#(Int, actor.Started(a)), actor.StartError) {
  case result {
    Ok(started) -> {
      let assert Ok(port) = process.receive(bound_port, 1000)
      Ok(#(port, started))
    }
    Error(err) -> Error(err)
  }
}

fn handle_request(
  req: Request(Connection),
  registry_subject: Subject(registry.Message),
  poker_registry_subject: Subject(poker_registry.Message),
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
        Get | Head -> {
          let buzzer_health = registry.health(registry_subject)
          let poker_health = poker_registry.health(poker_registry_subject)
          case buzzer_health, poker_health {
            Ok(registry.HealthSnapshot(rooms: buzzer_rooms, stuck: buzzer_stuck)),
              Ok(poker_registry.HealthSnapshot(
                rooms: poker_rooms,
                stuck: poker_stuck,
              ))
            ->
              response.new(200)
              |> response.set_body(
                mist.Bytes(bytes_tree.from_string(
                  "ok buzzer_rooms="
                  <> int.to_string(buzzer_rooms)
                  <> " buzzer_stuck="
                  <> int.to_string(buzzer_stuck)
                  <> " poker_rooms="
                  <> int.to_string(poker_rooms)
                  <> " poker_stuck="
                  <> int.to_string(poker_stuck),
                )),
              )
            // **理由を分けて伝える（#92）。** どちらの registry が失敗したか
            // 本文に書き分ける。運用者が次に見る場所が registry ごとに
            // 違うため（落ちているなら supervisor の再起動状況、詰まっている
            // なら負荷やタイムアウト値）、両方失敗していれば両方載せる（#285）。
            _, _ ->
              response.new(503)
              |> response.set_body(
                mist.Bytes(
                  bytes_tree.from_string(combined_health_failure_body(
                    buzzer_health,
                    poker_health,
                  )),
                ),
              )
          }
          |> empty_body_for_head(req.method)
        }
        _ -> method_not_allowed(["GET", "HEAD"])
      }

    ["ws"] ->
      case req.method {
        Get -> websocket.upgrade(req, registry_subject)
        _ -> method_not_allowed(["GET"])
      }

    ["poker", "ws"] ->
      case req.method {
        Get -> poker_websocket.upgrade(req, poker_registry_subject)
        _ -> method_not_allowed(["GET"])
      }

    ["poker"] ->
      case req.method {
        Get | Head ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(web_poker.poker_html())),
          )
          |> empty_body_for_head(req.method)
        _ -> method_not_allowed(["GET", "HEAD"])
      }

    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

/// `/health` が 503 を返すときの本文（#114）。
///
/// `pub` にして単体テストから直接呼べるようにしている。`call.Unknown` は
/// 生の `actor.call` 失敗をそのまま HTTP 経由で再現するのが難しいため
/// （registry actor を意図的に想定外の例外で落とす必要がある）、実サーバ越しの
/// ルーティングテストではなくこの純粋関数を直接検証する。
pub fn health_failure_body(reason: call.Failure) -> String {
  case reason {
    call.ActorDown -> "registry down"
    call.Timeout -> "registry not responding"
    call.Unknown(detail) -> "registry unavailable: " <> detail
  }
}

/// buzzer / poker どちらの registry が失敗したかを本文に書き分ける（#285）。
///
/// `/health` は2つの registry を独立に問い合わせる。片方だけが失敗した
/// 場合はその registry の理由だけを、両方失敗していれば両方を載せる。
/// 呼び出し元（`handle_request`）は少なくとも一方が `Error` のときだけ
/// これを呼ぶため、両方 `Ok` の分岐は到達しない。
pub fn combined_health_failure_body(
  buzzer: Result(a, call.Failure),
  poker: Result(b, call.Failure),
) -> String {
  case buzzer, poker {
    Error(buzzer_reason), Error(poker_reason) ->
      "buzzer: "
      <> health_failure_body(buzzer_reason)
      <> "; poker: "
      <> health_failure_body(poker_reason)
    Error(buzzer_reason), Ok(_) ->
      "buzzer: " <> health_failure_body(buzzer_reason)
    Ok(_), Error(poker_reason) -> "poker: " <> health_failure_body(poker_reason)
    Ok(_), Ok(_) ->
      panic as "combined_health_failure_body called with two successes"
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
