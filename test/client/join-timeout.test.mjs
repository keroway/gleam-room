// 接続開始から join 成立（state 受信）までの待機上限（#696）。buzzer / poker の両ページで検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const JOIN_TIMEOUT_MS = 10000;
const PAGES = [
  ["buzzer", { modulePath: "src/gleamroom/web.gleam", functionName: "index_html" },
    { type: "state", participants: [], buzzes: [] }],
  ["poker", { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" },
    { type: "state", phase: "voting", participants: [], votes: [] }],
];

for (const [name, page, state] of PAGES) {
  test(`${name}: open が来ないまま期限を超えると旧 socket を破棄して再接続する`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      assert.deepEqual(client.timerDelays(), [JOIN_TIMEOUT_MS]);
      const first = client.latestSocket();
      client.runTimers(); // join 期限
      assert.ok(client.logs.some((l) => l.includes("join timed out")));
      client.runTimers(); // 再接続待ち
      assert.equal(client.sockets.length, 2);
      // 旧 socket の遅延イベントは現行接続を壊さない
      first.handlers.open?.();
      first.handlers.close?.();
      assert.equal(client.sockets.length, 2);
    } finally { client.dispose(); }
  });

  test(`${name}: open 後に state が来なくても期限で再試行できる`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      client.latestSocket().handlers.open?.();
      client.runTimers();
      assert.ok(client.logs.some((l) => l.includes("join timed out")));
      client.runTimers();
      assert.equal(client.sockets.length, 2);
    } finally { client.dispose(); }
  });

  test(`${name}: 期限前に state が届けば期限タイマーは解除される`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({ data: JSON.stringify(state) });
      assert.equal(client.pendingTimers(), 0);
      client.runTimers();
      assert.equal(client.sockets.length, 1);
      assert.ok(!client.logs.some((l) => l.includes("join timed out")));
    } finally { client.dispose(); }
  });
}
