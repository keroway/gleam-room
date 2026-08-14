import envoy
import gleamroom

/// `PORT` の未設定・不正値・正常値を区別すること（#29）。
///
/// 以前は `envoy.get("PORT") |> result.try(int.parse) |> result.unwrap(4000)`
/// で、「未設定なので既定値」と「設定されているがタイポで無効」が区別なく
/// 吸収されていた。設定した人からは「なぜか反映されない」としか見えない。
///
/// 実サーバーでも確認済み: `PORT=abc` で
/// `WARN PORT=abc は整数として解釈できません。既定の 4000 番で起動します。`
/// が出たうえで 4000 番で起動する。
///
/// ## 環境変数の後片付け（#88）
///
/// `PORT` は**プロセス全体で共有される状態**で、gleeunit は同じ VM 内で
/// 全テストを走らせる。以前は `assert` の**後**に `envoy.unset` を置いていたため、
/// assert が落ちるとそこで中断して片付けが実行されず、`PORT` が残ったまま
/// 後続のテストへ漏れた。**本来 1 件で済む失敗が、無関係なテストの失敗に
/// 化ける**（そして原因はログから読み取れない）。
///
/// 対策は 2 つ:
///
///   1. 読み取り後・assert 前に片付ける（`read_port_with`）
///   2. 各テストが**開始時に未設定へ揃える**。他人の後片付けに依存しない
fn read_port_with(value: String) -> Int {
  envoy.set("PORT", value)
  let port = gleamroom.read_port()
  // **assert より前に片付ける。** ここを assert の後に置くと、失敗時に
  // 実行されず PORT が漏れる（#88）。
  envoy.unset("PORT")
  port
}

pub fn read_port_uses_the_default_when_unset_test() {
  envoy.unset("PORT")
  assert gleamroom.read_port() == 4000
}

pub fn read_port_uses_the_value_when_valid_test() {
  envoy.unset("PORT")
  assert read_port_with("4321") == 4321
}

/// 不正値でも既定値で起動を続けること（落とさない）。
///
/// ポートが違っても他は正常に動くため、ここで落とすと「動くはずのものが
/// 上がらない」ほうの害が大きい。警告で気づかせる方針を固定する。
pub fn read_port_falls_back_on_an_invalid_value_test() {
  envoy.unset("PORT")
  assert read_port_with("abc") == 4000
}

/// 数値としては解釈できても TCP ポート番号として無効な値
/// (負数・0・65535超)は、非数値と同じく警告を出して既定値へ落とすこと(#144)。
pub fn read_port_falls_back_on_a_negative_value_test() {
  envoy.unset("PORT")
  assert read_port_with("-1") == 4000
}

pub fn read_port_falls_back_on_zero_test() {
  envoy.unset("PORT")
  assert read_port_with("0") == 4000
}

pub fn read_port_falls_back_on_a_value_above_the_maximum_test() {
  envoy.unset("PORT")
  assert read_port_with("70000") == 4000
}

pub fn read_port_uses_the_maximum_valid_value_test() {
  envoy.unset("PORT")
  assert read_port_with("65535") == 65_535
}

/// **後片付けそのものを検証する（#88）。** これが無いと、片付けを消す変更を
/// 誰も止められない（他のテストは PORT が漏れても自分では気づかない）。
pub fn read_port_with_leaves_no_port_behind_test() {
  envoy.unset("PORT")
  let _ = read_port_with("4321")

  assert envoy.get("PORT") == Error(Nil)
}
