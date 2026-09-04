// docs/planning-poker.md の Reconnect（buzzer と同じ transient-identity モデル）の
// 回帰テスト。web.gleam 側の reconnect.test.mjs（#61）と同じ検証を web_poker.gleam に
// 対して行う。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient, flapWithoutJoining } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };
const MAX_RECONNECT_ATTEMPTS = 5;
const RECONNECT_DELAY_MS = 1500;

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

test("error イベントはログに残るだけで例外を投げない", () => {
  // #110 の回帰テスト。error ハンドラは close 側の再接続処理に影響しない
  // no-op ログだが、これまでテストから一度も呼び出されていなかった。
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();

    assert.doesNotThrow(() => socket.handlers.error?.());
    assert.ok(
      client.logs.some((line) => line.includes("connection error")),
      "error イベントがログに残っていない",
    );
  } finally {
    client.dispose();
  }
});

test("接続中は保留中の再接続タイマーが残らない", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    // close で再接続タイマーを予約させる。
    socket.handlers.open?.();
    socket.handlers.close?.();
    assert.equal(client.pendingTimers(), 1, "再接続タイマーが予約されていない");
    assert.deepEqual(
      client.timerDelays(),
      [RECONNECT_DELAY_MS],
      "再接続タイマーの delay が RECONNECT_DELAY_MS と一致していない",
    );

    // 利用者が自分で join し直すと cancelReconnect が呼ばれ、予約が消える。
    client.submitJoin();
    assert.equal(client.pendingTimers(), 0, "join し直しても再接続待ちが残っている");
  } finally {
    client.dispose();
  }
});
