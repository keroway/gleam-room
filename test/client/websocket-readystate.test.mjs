// buzz/次の問題 クリックが WebSocket readyState 未チェックで CLOSING/CLOSED 時に
// 無音に失敗する問題の回帰テスト（#122）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import { buzzerState } from "./buzzer-wire.mjs";

test("OPEN な接続では buzz/次の問題 クリックがそのまま送信される", () => {
  for (const [selfRole, button, type] of [
    ["player", "buzz", "buzz"],
    ["host", "next-question", "next_question"],
  ]) {
    const client = startClient();
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify(buzzerState({ selfRole })),
      });
      socket.sent = [];

      client.click(button);

      assert.deepEqual(
        socket.sent.map((raw) => JSON.parse(raw).type),
        [type],
      );
    } finally {
      client.dispose();
    }
  }
});

for (const state of ["CLOSING", "CLOSED"]) {
  test(`readyState が ${state} の間は buzz/次の問題 クリックを送信せずログに残す`, () => {
    const client = startClient();
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify(buzzerState()),
      });

      // close イベントがまだ発火していない間に readyState だけが進む
      // ケースを再現する（サーバー起因のクローズ開始 〜 close イベント
      // 発火までの間隔）。
      socket.readyState = socket.constructor[state];
      socket.sent = [];
      const logEntriesBefore = client.logEntryCount();

      client.click("buzz");
      client.click("next-question");

      assert.equal(socket.sent.length, 0);
      assert.ok(client.logEntryCount() > logEntriesBefore);
    } finally {
      client.dispose();
    }
  });
}
