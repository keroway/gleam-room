// harness.mjs の DOM スタブが、実在しない要素 id をブラウザと同様に
// null で返すことの回帰テスト（#112）。id 実在性を検証しない場合、
// web.gleam の HTML 側と JS 側の id 不一致が green のまま見逃される。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import { extractElementIds } from "./extract.mjs";

test("web.gleam に実在する id は getElementById で取得できる", () => {
  const client = startClient();
  try {
    for (const id of extractElementIds()) {
      assert.notEqual(
        globalThis.document.getElementById(id),
        null,
        `既知の id "${id}" が取得できない`,
      );
    }
  } finally {
    client.dispose();
  }
});

test("実在しない id は本物のブラウザと同様に null を返す", () => {
  const client = startClient();
  try {
    assert.equal(globalThis.document.getElementById("no-such-id"), null);
  } finally {
    client.dispose();
  }
});

// runTimers() が delay を無視して登録順に発火すると、実ブラウザの setTimeout の
// 相対順序（delay の小さい方が先に発火する）と食い違う挙動を green のまま
// 見逃してしまう（#150）。
test("runTimers() は登録順ではなく delay の昇順で発火する", () => {
  const client = startClient();
  try {
    const order = [];
    globalThis.setTimeout(() => order.push("slow"), 100);
    globalThis.setTimeout(() => order.push("fast"), 10);
    globalThis.setTimeout(() => order.push("mid"), 50);

    const fired = client.runTimers();

    assert.equal(fired, 3);
    assert.deepEqual(order, ["fast", "mid", "slow"]);
  } finally {
    client.dispose();
  }
});
