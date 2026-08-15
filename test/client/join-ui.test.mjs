// join が成立する前に "connected" UI へ遷移してしまう不整合の回帰テスト（#62）。
//
// web.gleam のクライアントは WebSocket "open" と join の成立（サーバから
// "state" が届く）を別のタイミングとして扱う必要がある。さらに
// "room_unavailable"/"join_rejected" はソケットを閉じずに返るため
// （websocket.gleam の with_room/JoinRejected 分岐）、クライアント側で
// 明示的に "未接続・再度join可能" な状態へ戻さない限り UI が固まる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

test("open だけでは connected にならない", () => {
  const client = startClient();
  try {
    client.submitJoin();
    client.latestSocket().handlers.open?.();

    assert.notEqual(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});

test("join成立（state受信）で初めて connected になる", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", participants: [], buzzes: [] }),
    });

    assert.equal(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});

for (const code of ["join_rejected", "room_unavailable"]) {
  test(`${code} エラーは connected に戻さず、再度 join できる状態にする`, () => {
    const client = startClient();
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify({ type: "error", code, message: "nope" }),
      });

      assert.equal(client.connectionState(), "disconnected");
      assert.equal(client.pendingTimers(), 0, "拒否直後に自動再接続を予約してはいけない");

      // ソケットが解放され、フォームから再度 join できる。
      const before = client.sockets.length;
      client.submitJoin();
      assert.equal(client.sockets.length, before + 1, "再度joinできていない");
    } finally {
      client.dispose();
    }
  });
}

test("not_joined のような join 以外のエラーは接続状態を変えない", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", participants: [], buzzes: [] }),
    });
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "not_joined", message: "nope" }),
    });

    assert.equal(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});
