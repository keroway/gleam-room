// docs/mvp.md の MVP 必須機能 "Basic reconnect handling" の回帰テスト（#61）。
//
// このロジックは web.gleam に JS 文字列として埋め込まれており、Gleam 側からは
// 検証できない。ブラウザ自動化も入れず、Node 標準の `node --test` と
// 最小のスタブだけで済ませている（新しい依存を増やさない）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const MAX_RECONNECT_ATTEMPTS = 5;

/// join が成立しないまま open→close を繰り返す状況を作る。
/// サーバが接続直後に切る場合がこれにあたる。
function flapWithoutJoining(client, rounds) {
  for (let i = 0; i < rounds; i += 1) {
    const before = client.sockets.length;
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.close?.();
    client.runTimers();
    if (client.sockets.length === before) return i + 1; // 再接続を諦めた回
  }
  return null;
}

test("再接続は MAX_RECONNECT_ATTEMPTS で打ち切られる", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const gaveUpAt = flapWithoutJoining(client, MAX_RECONNECT_ATTEMPTS + 5);

    assert.notEqual(gaveUpAt, null, "上限に達しても再接続を続けている");
    // 初回 1 本 + 再接続 MAX 本で打ち止め。
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
  // #87 の回帰テスト。open でリセットすると、join が通らない限り
  // 上限に永久に到達しない。
  const client = startClient();
  try {
    client.submitJoin();

    // 4 回失敗させる（上限にはまだ届かない）。
    flapWithoutJoining(client, 4);
    const beforeJoin = client.sockets.length;

    // 5 本目で join が成立する。
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", participants: [], buzzes: [] }),
    });
    socket.handlers.close?.();
    client.runTimers();

    // 成立したので試行回数は戻り、再び MAX 回まで粘れる。
    assert.equal(client.sockets.length, beforeJoin + 1);
    const gaveUpAt = flapWithoutJoining(client, MAX_RECONNECT_ATTEMPTS + 5);
    assert.notEqual(gaveUpAt, null);
    assert.equal(gaveUpAt, MAX_RECONNECT_ATTEMPTS);
  } finally {
    client.dispose();
  }
});

test("利用者が自分で join し直すと試行回数が戻る", () => {
  const client = startClient();
  try {
    client.submitJoin();
    flapWithoutJoining(client, MAX_RECONNECT_ATTEMPTS + 2);
    // 諦めた状態。ここで利用者がフォームから join し直す。
    const before = client.sockets.length;
    client.submitJoin();

    assert.equal(client.sockets.length, before + 1, "手動 join で再接続できていない");
  } finally {
    client.dispose();
  }
});

test("接続中は保留中の再接続タイマーが残らない", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    assert.equal(client.pendingTimers(), 0, "接続できているのに再接続待ちがある");
  } finally {
    client.dispose();
  }
});
