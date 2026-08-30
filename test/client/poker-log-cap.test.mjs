// #log の子要素が無制限に蓄積しないことの回帰テスト（#119）。
// web.gleam 側の log-cap.test.mjs と同じ検証を web_poker.gleam に対して行う（#300）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };

test("#log の子要素は上限を超えると古い順に削除される（poker）", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();

    for (let position = 0; position < 250; position += 1) {
      socket.handlers.message?.({
        data: JSON.stringify({
          type: "vote_registered",
          participant_id: `p${position}`,
        }),
      });
    }

    assert.equal(client.logEntryCount(), 200);
  } finally {
    client.dispose();
  }
});
