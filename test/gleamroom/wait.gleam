//// テストで「まだ起きていないこと」を待つための共通ヘルパ（#72 / #86）。
////
//// ## 固定 sleep をやめる理由
////
//// `process.kill` も `Release` も**シグナル/メッセージを送るだけ**で、
//// 戻った時点では相手の後始末が終わっていない。`process.sleep(150)` で
//// 待つと、遅いマシン（負荷のかかった CI やセルフホストランナー）では
//// 足りずにフレークし、速いマシンでは無駄に待つ。
////
//// **待つ対象を条件で表現する。** 条件が満たされたら即座に進み、
//// 期限内に満たされなければ**理由付きで落とす**（黙って先へ進まない）。
////
//// 同型のポーリングが各テストファイルに重複していたのをここへ集約した。

import gleam/erlang/process

/// ポーリングの間隔。20ms は supervisor_test が使っていた値に合わせている。
const interval_ms = 20

/// `check` が `True` を返すまで待つ。
///
/// `attempts` 回試しても満たされなければ `label` を添えて panic する。
/// 既定の上限は 100 回 = 2 秒で、BEAM のプロセス後始末には十分長い。
pub fn until(check: fn() -> Bool, label: String) -> Nil {
  until_within(check, label, 100)
}

/// 上限を指定して待つ。
pub fn until_within(check: fn() -> Bool, label: String, attempts: Int) -> Nil {
  case check(), attempts {
    True, _ -> Nil
    False, 0 -> panic as { "期限内に条件が満たされなかった: " <> label }
    False, _ -> {
      process.sleep(interval_ms)
      until_within(check, label, attempts - 1)
    }
  }
}

/// プロセスが終了するまで待つ。
pub fn until_dead(pid: process.Pid, label: String) -> Nil {
  until(fn() { !process.is_alive(pid) }, label)
}
