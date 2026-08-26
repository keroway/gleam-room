import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/string
import gleamroom
import gleamroom/call
import gleamroom/poker_registry
import gleamroom/registry
import gleamroom/wait

/// HTTP ルーティングを**実際にサーバを起動して**確かめる（#34）。
///
/// これまで `handle_request` を通るテストは 1 つも無かった。#93 で `/health` を
/// registry へ問い合わせる形に直し、#92 で本文を書き分けたが、**その配線が
/// 繋がっていることは一度も検証していない**（検証していたのは
/// `registry.health` の振る舞いだけ）。ルーティングを間違えても誰も気づけない。
///
/// mist の `Connection` は不透明でテストから作れないため、擬似リクエストでは
/// なく**本物のサーバへ本物の HTTP を投げる**。gleam_httpc は
/// この検証のためだけの dev-dependency。
///
/// ポートは固定値ではなくOSに動的採番させる（`gleamroom.start_on_ephemeral_port`
/// / `start_web_only_on_ephemeral_port`、#152）。固定ポートだと、CI・開発機で
/// そのポートが既に他プロセスに専有されている場合や、このファイル内の複数テストが
/// 並行に走った場合に Eaddrinuse で落ち、しかも `await_ready` の一律の panic
/// メッセージからは「ルーティングの不具合」なのか「ポート衝突」なのか
/// 切り分けられなかった。動的採番なら、この種の衝突自体が起こらない。
fn start_server() -> Int {
  let assert Ok(#(port, _)) = gleamroom.start_on_ephemeral_port()
  // 起動直後は listen が間に合わないことがある。固定 sleep で待たず、
  // 実際に応答するまで叩いて確かめる。
  await_ready(port, 50)
  port
}

fn start_web_only_server(
  registry_subject: process.Subject(registry.Message),
  poker_registry_subject: process.Subject(poker_registry.Message),
) -> Int {
  let assert Ok(#(port, _)) =
    gleamroom.start_web_only_on_ephemeral_port(
      registry_subject,
      poker_registry_subject,
    )
  await_ready(port, 50)
  port
}

/// `start_web_only_server` に渡す、健全な poker registry の subject
/// （buzzer 側だけを故障させるテスト用）。
fn healthy_poker_registry_subject() -> process.Subject(poker_registry.Message) {
  let assert Ok(started) = poker_registry.start()
  started.data
}

fn await_ready(port: Int, remaining: Int) -> Nil {
  case get(port, "/health"), remaining {
    Ok(_), _ -> Nil
    Error(_), 0 -> panic as "サーバが期限内に応答しなかった"
    Error(_), _ -> {
      process.sleep(20)
      await_ready(port, remaining - 1)
    }
  }
}

fn get(port: Int, path: String) -> Result(#(Int, String), Nil) {
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> path)
  case httpc.send(req) {
    Ok(response) -> Ok(#(response.status, response.body))
    Error(_) -> Error(Nil)
  }
}

fn request_with_method(
  port: Int,
  path: String,
  method: http.Method,
) -> Result(response.Response(String), Nil) {
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> path)
  let req = request.set_method(req, method)
  case httpc.send(req) {
    Ok(response) -> Ok(response)
    Error(_) -> Error(Nil)
  }
}

pub fn routing_serves_the_expected_paths_test() {
  let port = start_server()

  // `/` はブザークイズのブラウザクライアントを返す。
  let assert Ok(#(status, body)) = get(port, "/")
  assert status == 200
  assert string.contains(body, "<script>")

  // `/poker` は Planning Poker のブラウザクライアントを返す（#282）。
  let assert Ok(#(poker_status, poker_body)) = get(port, "/poker")
  assert poker_status == 200
  assert string.contains(poker_body, "<script>")

  // `/health` は buzzer / poker 両方の registry へ問い合わせた結果を返す
  // （#93 / #92 / #285）。room がまだ無いので 0 件。
  // **配線が繋がっていなければここで気づける。**
  let assert Ok(#(health_status, health_body)) = get(port, "/health")
  assert health_status == 200
  assert health_body
    == "ok buzzer_rooms=0 buzzer_stuck=0 poker_rooms=0 poker_stuck=0"

  // 未知のパスは 404。
  let assert Ok(#(missing_status, _)) = get(port, "/nope")
  assert missing_status == 404

  // `/ws` は WebSocket upgrade を要求する。素の GET は mist が **400** を返す
  // （vendored mist: "If the request is not upgradable, a 400 response will be
  // sent to the client."）。実際に測って 400 であることを確認したうえで固定する。
  //
  // **`!= 200` では駄目（#131）。** 404 でも 500 でも通ってしまうので、
  // `/ws` のルーティングが外れて catch-all に落ちる回帰を無言で見逃す。
  // このテストの目的は「配線が繋がっていること」の検証で、そこが抜けていた。
  let assert Ok(#(ws_status, _)) = get(port, "/ws")
  assert ws_status == 400

  // パスは一致してもメソッドが対応外なら 405 を返す（#66）。
  //
  // 以前は `request.path_segments` のみでルーティングしており、
  // POST / や DELETE /health でも `/` `/health` と同じ 200 が返っていた。
  let assert Ok(root_response) = request_with_method(port, "/", http.Post)
  assert root_response.status == 405
  assert response.get_header(root_response, "allow") == Ok("GET, HEAD")

  let assert Ok(poker_response) = request_with_method(port, "/poker", http.Post)
  assert poker_response.status == 405
  assert response.get_header(poker_response, "allow") == Ok("GET, HEAD")

  let assert Ok(health_response) =
    request_with_method(port, "/health", http.Delete)
  assert health_response.status == 405
  assert response.get_header(health_response, "allow") == Ok("GET, HEAD")

  // `/ws` も GET 以外は 405（#176）。以前は `websocket.upgrade` へ
  // メソッド検証なしで丸投げしており、必要なヘッダさえ揃えば POST/DELETE
  // でも WebSocket アップグレードが成立しうる状態だった（RFC 6455 §4.1
  // はハンドシェイクを GET に限定している）。
  let assert Ok(ws_response) = request_with_method(port, "/ws", http.Post)
  assert ws_response.status == 405
  assert response.get_header(ws_response, "allow") == Ok("GET")
}

pub fn head_responses_have_an_empty_body_test() {
  let port = start_server()

  // RFC 9110 §9.3.2: HEAD は GET と同じステータス・ヘッダーを返すが、
  // ボディを送ってはならない。GET と比較して両方を確かめる。
  let assert Ok(root_get_response) = request_with_method(port, "/", http.Get)
  let assert Ok(root_response) = request_with_method(port, "/", http.Head)
  assert root_response.status == root_get_response.status
  assert response.get_header(root_response, "content-type")
    == response.get_header(root_get_response, "content-type")
  assert root_response.body == ""

  let assert Ok(health_get_response) =
    request_with_method(port, "/health", http.Get)
  let assert Ok(health_response) =
    request_with_method(port, "/health", http.Head)
  assert health_response.status == health_get_response.status
  assert health_response.body == ""
}

/// `/health` の 503 本文は `call.Failure` の3バリアントすべてを区別する
/// （#114）。`ActorDown`/`Timeout` は README とテストが既にあったが、
/// `call.Unknown`（文字列一致で分類できなかった例外）だけが欠けていた。
pub fn health_failure_body_distinguishes_all_three_reasons_test() {
  assert gleamroom.health_failure_body(call.ActorDown) == "registry down"
  assert gleamroom.health_failure_body(call.Timeout)
    == "registry not responding"
  assert gleamroom.health_failure_body(call.Unknown("boom"))
    == "registry unavailable: boom"
}

/// `/health` は buzzer / poker のどちらが失敗したか本文で書き分ける
/// （#285）。片方だけの失敗と、両方の失敗を区別する。
pub fn combined_health_failure_body_labels_the_failing_registry_test() {
  assert gleamroom.combined_health_failure_body(Error(call.ActorDown), Ok(Nil))
    == "buzzer: registry down"
  assert gleamroom.combined_health_failure_body(Ok(Nil), Error(call.Timeout))
    == "poker: registry not responding"
  assert gleamroom.combined_health_failure_body(
      Error(call.ActorDown),
      Error(call.Timeout),
    )
    == "buzzer: registry down; poker: registry not responding"
}

/// `/health` の503分岐は純粋関数のテストしか無く、実際にHTTP経由で叩いた
/// ときに `handle_request` の配線が正しくステータス・本文を返すことは
/// 一度も検証されていなかった（#142）。ここでは registry actor を意図的に
/// 停止させ、`ActorDown` 分岐を実サーバ越しに確かめる。
pub fn health_returns_503_actor_down_via_http_test() {
  // registry_test.gleam の `health_fails_when_the_registry_is_dead_test` と
  // 同じ手法: このテストプロセス自身が registry を起動すると link されており、
  // `process.kill` した瞬間にテストプロセスまで巻き添えで落ちる。
  // 別プロセスに起動させ、subject だけ受け取る。
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = registry.start()
    process.send(ready, started.data)
    process.sleep(3000)
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  let assert Ok(pid) = process.subject_owner(subject)

  process.kill(pid)
  wait.until_dead(pid, "registry が終了する")

  let port = start_web_only_server(subject, healthy_poker_registry_subject())

  let assert Ok(#(status, body)) = get(port, "/health")
  assert status == 503
  assert body == "buzzer: registry down"
}

/// `Timeout` 分岐の実サーバ越し確認（#142）。誰も処理しない subject を渡し、
/// `registry.health` を詰まらせる（registry_test.gleam と同じ手法）。
pub fn health_returns_503_timeout_via_http_test() {
  let unresponsive: process.Subject(registry.Message) = process.new_subject()

  let port =
    start_web_only_server(unresponsive, healthy_poker_registry_subject())

  let assert Ok(#(status, body)) = get(port, "/health")
  assert status == 503
  assert body == "buzzer: registry not responding"
}

/// #279 で判明した穴（poker registry が停止していても `/health` が 200 を
/// 返し続ける）を塞いだことを固定する（#285）。`/health` は poker registry
/// にも問い合わせ、死んでいれば 503 を返す。
///
/// `health_returns_503_actor_down_via_http_test` と同じ手法: 別プロセスで
/// poker registry を起動して kill する（テストプロセス自身が起動すると
/// link で巻き添えになる）。`start_web_only_on_ephemeral_port` で起動する
/// ため supervisor の自動再起動が無く、kill した状態がそのまま観測できる。
pub fn health_returns_503_when_the_poker_registry_is_dead_test() {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = poker_registry.start()
    process.send(ready, started.data)
    process.sleep(3000)
  })
  let assert Ok(poker_registry_subject) = process.receive(ready, 1000)
  let assert Ok(poker_registry_pid) =
    process.subject_owner(poker_registry_subject)

  process.kill(poker_registry_pid)
  wait.until_dead(poker_registry_pid, "poker registry が終了する")

  let assert Ok(healthy_registry_started) = registry.start()
  let port =
    start_web_only_server(healthy_registry_started.data, poker_registry_subject)

  let assert Ok(#(status, body)) = get(port, "/health")
  assert status == 503
  assert body == "poker: registry down"
}
