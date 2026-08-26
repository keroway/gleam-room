// docs/planning-poker.md の Reconnect（buzzer と同じ transient-identity モデル）の
// 回帰テスト。web.gleam 側の reconnect.test.mjs（#61）と同じ検証を web_poker.gleam に
// 対して行う。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };
const MAX_RECONNECT_ATTEMPTS = 5;

function flapWithoutJoining(client, rounds) {
  for (let i = 0; i < rounds; i += 1) {
    const before = client.sockets.length;
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.close?.();
    client.runTimers();
    if (client.sockets.length === before) return i + 1;
  }
  return null;
}

test("再接続は MAX_RECONNECT_ATTEMPTS で打ち切られる", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const gaveUpAt = flapWithoutJoining(client, MAX_RECONNECT_ATTEMPTS + 5);

    assert.notEqual(gaveUpAt, null, "上限に達しても再接続を続けている");
    assert.equal(client.sockets.length, 1 + MAX_RECONNECT_ATTEMPTS);
    assert.ok(
      client.logs.some((line) => line.includes("giving up automatic reconnect")),
      "諦めたことがログに残っていない",
    );
  } finally {
    client.dispose();
  }
});

test("試行回数は open ではなく join 成立（state 受信）で戻る", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();

    flapWithoutJoining(client, 4);
    const beforeJoin = client.sockets.length;

    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", phase: "voting", participants: [] }),
    });
    socket.handlers.close?.();
    client.runTimers();

    assert.equal(client.sockets.length, beforeJoin + 1);
    const gaveUpAt = flapWithoutJoining(client, MAX_RECONNECT_ATTEMPTS + 5);
    assert.notEqual(gaveUpAt, null);
    assert.equal(gaveUpAt, MAX_RECONNECT_ATTEMPTS);
  } finally {
    client.dispose();
  }
});

test("利用者が自分で join し直すと試行回数が戻る", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    flapWithoutJoining(client, MAX_RECONNECT_ATTEMPTS + 2);
    const before = client.sockets.length;
    client.submitJoin();

    assert.equal(client.sockets.length, before + 1, "手動 join で再接続できていない");
  } finally {
    client.dispose();
  }
});
