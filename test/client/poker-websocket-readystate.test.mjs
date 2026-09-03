// vote/reveal/reset クリックが WebSocket readyState 未チェックで CLOSING/CLOSED 時に
// 無音に失敗する問題の回帰テスト。buzzer 側の websocket-readystate.test.mjs（#122）と
// 同じ検証を web_poker.gleam の sendIfOpen ガードに対して行う（#318）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };

test("OPEN な接続では vote/reveal/reset クリックがそのまま送信される", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", phase: "voting", participants: [] }),
    });
    socket.sent = [];

    client.click("card-5");
    client.click("reveal");
    client.click("reset");

    assert.deepEqual(
      socket.sent.map((raw) => JSON.parse(raw).type),
      ["vote", "reveal", "reset"],
    );
  } finally {
    client.dispose();
  }
});

for (const state of ["CLOSING", "CLOSED"]) {
  test(`readyState が ${state} の間は vote/reveal/reset クリックを送信せずログに残す`, () => {
    const client = startClient(POKER_MODULE);
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify({ type: "state", phase: "voting", participants: [] }),
      });

      // close イベントがまだ発火していない間に readyState だけが進む
      // ケースを再現する（サーバー起因のクローズ開始 〜 close イベント
      // 発火までの間隔）。
      socket.readyState = socket.constructor[state];
      socket.sent = [];
      const logEntriesBefore = client.logEntryCount();

      client.click("card-5");
      client.click("reveal");
      client.click("reset");

      assert.equal(socket.sent.length, 0);
      assert.ok(client.logEntryCount() > logEntriesBefore);
    } finally {
      client.dispose();
    }
  });
}
