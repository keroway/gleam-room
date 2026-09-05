import envoy
import gleamroom

/// `MAX_ROOMS` の未設定・不正値・正常値を区別すること（#352）。
///
/// `registry.start_with_max_rooms` / `poker_registry.start_with_max_rooms` は
/// 公開されていたが、本番の起動経路（`gleamroom.start`）からは到達不能
/// だった。`read_port`（#29）と同じ形で `read_max_rooms` を用意し、
/// 環境変数から反映できるようにする。
///
/// ## 環境変数の後片付け（#88）
///
/// `MAX_ROOMS` は `PORT` と同じくプロセス全体で共有される状態。
/// assert より前に片付ける（`read_max_rooms_with`）。
fn read_max_rooms_with(value: String) -> Int {
  envoy.set("MAX_ROOMS", value)
  let max_rooms = gleamroom.read_max_rooms()
  // **assert より前に片付ける。** ここを assert の後に置くと、失敗時に
  // 実行されず MAX_ROOMS が漏れる（#88、`port_test.gleam` と同じ理由）。
  envoy.unset("MAX_ROOMS")
  max_rooms
}

pub fn read_max_rooms_uses_the_default_when_unset_test() {
  envoy.unset("MAX_ROOMS")
  assert gleamroom.read_max_rooms() == 1000
}

pub fn read_max_rooms_uses_the_value_when_valid_test() {
  envoy.unset("MAX_ROOMS")
  assert read_max_rooms_with("5") == 5
}

/// 不正値でも既定値で起動を続けること（落とさない）。`read_port` と同じ方針。
pub fn read_max_rooms_falls_back_on_an_invalid_value_test() {
  envoy.unset("MAX_ROOMS")
  assert read_max_rooms_with("abc") == 1000
}

/// 1未満(0・負数)は room 上限として無意味なため、非数値と同じく警告を出して
/// 既定値へ落とすこと。
pub fn read_max_rooms_falls_back_on_zero_test() {
  envoy.unset("MAX_ROOMS")
  assert read_max_rooms_with("0") == 1000
}

pub fn read_max_rooms_falls_back_on_a_negative_value_test() {
  envoy.unset("MAX_ROOMS")
  assert read_max_rooms_with("-1") == 1000
}

pub fn read_max_rooms_uses_a_large_valid_value_test() {
  envoy.unset("MAX_ROOMS")
  assert read_max_rooms_with("50000") == 50_000
}

/// **後片付けそのものを検証する（#88）。**
pub fn read_max_rooms_with_leaves_no_max_rooms_behind_test() {
  envoy.unset("MAX_ROOMS")
  let _ = read_max_rooms_with("5")

  assert envoy.get("MAX_ROOMS") == Error(Nil)
}
