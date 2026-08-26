// join が成立する前に "connected" UI へ遷移してしまう不整合の回帰テスト。
// web.gleam 側の join-ui.test.mjs（#62）と同じ検証を web_poker.gleam に対して行う。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };

test("open だけでは connected にならない", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    client.latestSocket().handlers.open?.();

    assert.notEqual(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});

test("join成立（state受信）で初めて connected になる", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", phase: "voting", participants: [] }),
    });

    assert.equal(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});

for (const code of ["room_full", "invalid_display_name", "invalid_room_id", "room_unavailable"]) {
  test(`${code} エラーは connected に戻さず、再度 join できる状態にする`, () => {
    const client = startClient(POKER_MODULE);
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify({ type: "error", code, message: "nope" }),
      });

      assert.equal(client.connectionState(), "disconnected");
      assert.equal(client.pendingTimers(), 0, "拒否直後に自動再接続を予約してはいけない");

      const before = client.sockets.length;
      client.submitJoin();
      assert.equal(client.sockets.length, before + 1, "再度joinできていない");
    } finally {
      client.dispose();
    }
  });
}

test("not_joined のような join 以外のエラーは接続状態を変えない", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", phase: "voting", participants: [] }),
    });
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "not_joined", message: "nope" }),
    });

    assert.equal(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});
