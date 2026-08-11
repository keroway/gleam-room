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
pub fn read_port_uses_the_default_when_unset_test() {
  envoy.unset("PORT")
  assert gleamroom.read_port() == 4000
}

pub fn read_port_uses_the_value_when_valid_test() {
  envoy.set("PORT", "4321")
  assert gleamroom.read_port() == 4321
  envoy.unset("PORT")
}

/// 不正値でも既定値で起動を続けること（落とさない）。
///
/// ポートが違っても他は正常に動くため、ここで落とすと「動くはずのものが
/// 上がらない」ほうの害が大きい。警告で気づかせる方針を固定する。
pub fn read_port_falls_back_on_an_invalid_value_test() {
  envoy.set("PORT", "abc")
  assert gleamroom.read_port() == 4000
  envoy.unset("PORT")
}
