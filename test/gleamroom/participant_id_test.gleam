import gleam/list
import gleam/string
import gleamroom/websocket

/// 参加者 ID が BEAM の PID 文字列表現を含まないこと（#28）。
///
/// 以前は `process.self() |> string.inspect` の結果 —— `<0.612.0>` 形式 —— を
/// そのまま公開プロトコルの識別子に使っており、実サーバーで
/// `{"id":"//erl(<0.132.0>)"}` を観測していた。
///
/// PID を外に出すと (1) サーバー内部のプロセス構造が漏れ、(2) PID は
/// **プロセス終了後に再利用される**ため再接続で別人に同じ ID が割り当たり、
/// (3) 公開プロトコルが実装詳細に固定される。
pub fn participant_id_does_not_leak_a_beam_pid_test() {
  let id = websocket.new_participant_id()

  assert !string.contains(id, "<")
  assert !string.contains(id, ">")
  assert !string.contains(id, "erl")
  assert id != ""
}

/// 呼ぶたびに異なる値になること（#28）。
///
/// 同じ値が返ると、同一ルームの参加者が互いに区別できなくなる。
/// 暗号論的乱数 16 バイトなので、この回数で衝突すれば実装が壊れている。
pub fn participant_ids_are_unique_across_calls_test() {
  let ids =
    list.repeat(Nil, 100) |> list.map(fn(_) { websocket.new_participant_id() })

  assert list.length(list.unique(ids)) == 100
}

/// URL/クエリ文字列にそのまま埋め込んでも壊れないこと（#77）。
///
/// 標準アルファベットの base64 は `+`（クエリ文字列で空白に解釈される）と
/// `/`（パスセグメントの区切りになる）を含みうる。100 回生成して一度も
/// 出現しなければ、URL安全アルファベットを使えている強い根拠になる。
pub fn participant_ids_are_url_safe_test() {
  let ids =
    list.repeat(Nil, 100) |> list.map(fn(_) { websocket.new_participant_id() })

  assert list.all(ids, fn(id) {
    !string.contains(id, "+") && !string.contains(id, "/")
  })
}
