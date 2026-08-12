import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/string
import gleamroom

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
const test_port = 4173

fn start_server() -> Nil {
  let assert Ok(_) = gleamroom.start(test_port)
  // 起動直後は listen が間に合わないことがある。固定 sleep で待たず、
  // 実際に応答するまで叩いて確かめる。
  await_ready(50)
}

fn await_ready(remaining: Int) -> Nil {
  case get("/health"), remaining {
    Ok(_), _ -> Nil
    Error(_), 0 -> panic as "サーバが期限内に応答しなかった"
    Error(_), _ -> {
      process.sleep(20)
      await_ready(remaining - 1)
    }
  }
}

fn get(path: String) -> Result(#(Int, String), Nil) {
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(test_port) <> path)
  case httpc.send(req) {
    Ok(response) -> Ok(#(response.status, response.body))
    Error(_) -> Error(Nil)
  }
}

pub fn routing_serves_the_expected_paths_test() {
  start_server()

  // `/` はブラウザクライアントを返す。
  let assert Ok(#(status, body)) = get("/")
  assert status == 200
  assert string.contains(body, "<script>")

  // `/health` は registry へ問い合わせた結果を返す（#93 / #92）。
  // room がまだ無いので 0 件。**配線が繋がっていなければここで気づける。**
  let assert Ok(#(health_status, health_body)) = get("/health")
  assert health_status == 200
  assert health_body == "ok rooms=0"

  // 未知のパスは 404。
  let assert Ok(#(missing_status, _)) = get("/nope")
  assert missing_status == 404

  // `/ws` は WebSocket upgrade を要求する。素の GET は 101 にはならない。
  let assert Ok(#(ws_status, _)) = get("/ws")
  assert ws_status != 200
}
