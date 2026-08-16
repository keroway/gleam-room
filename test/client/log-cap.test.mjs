// #log の子要素が無制限に蓄積しないことの回帰テスト（#119）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

test("#log の子要素は上限を超えると古い順に削除される", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();

    for (let position = 0; position < 250; position += 1) {
      socket.handlers.message?.({
        data: JSON.stringify({
          type: "buzz_accepted",
          participant_id: "p1",
          position,
        }),
      });
    }

    assert.equal(client.logEntryCount(), 200);
  } finally {
    client.dispose();
  }
});
