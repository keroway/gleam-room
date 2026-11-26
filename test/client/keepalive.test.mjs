// 無操作でも接続を維持するクライアント側 keepalive ping（#764）の回帰テスト。
// buzzer / poker は同じ client_js.shared を使うため、両ページで同じ検証をする。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const PING_INTERVAL_MS = 15000;
// サーバのハートビート窓（ws_guard.default_heartbeat_interval_ms）。
const SERVER_HEARTBEAT_WINDOW_MS = 30000;

const PAGES = [
  ["buzzer", undefined],
  ["poker", { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" }],
];

const pings = (socket) =>
  socket.sent.filter((data) => JSON.parse(data).type === "ping");

for (const [name, page] of PAGES) {
  test(`${name}: open 後はサーバの窓より短い間隔で ping を送る`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      assert.deepEqual(client.intervalDelays(), [], "open 前に ping タイマーが動いている");

      socket.handlers.open?.();
      assert.deepEqual(client.intervalDelays(), [PING_INTERVAL_MS]);
      assert.ok(PING_INTERVAL_MS * 2 <= SERVER_HEARTBEAT_WINDOW_MS, "窓あたり2回送れない");

      client.tickIntervals();
      client.tickIntervals();
      assert.equal(pings(socket).length, 2);
    } finally {
      client.dispose();
    }
  });

  test(`${name}: pong は画面にもログにも出ず、ページの処理へ渡らない`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      const logsBefore = client.logs.length;

      socket.handlers.message?.({ data: JSON.stringify({ type: "pong" }) });

      assert.equal(client.logs.length, logsBefore, "pong がログに出ている");
    } finally {
      client.dispose();
    }
  });

  test(`${name}: 切断で ping タイマーが止まり、再接続を繰り返しても増えない`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      for (let i = 0; i < 4; i += 1) {
        const socket = client.latestSocket();
        socket.handlers.open?.();
        assert.equal(client.intervalDelays().length, 1, `${i}回目の接続でタイマーが重複`);
        socket.handlers.close?.();
        assert.deepEqual(client.intervalDelays(), [], `${i}回目の切断でタイマーが残っている`);
        client.runTimers();
      }
    } finally {
      client.dispose();
    }
  });

  test(`${name}: 古い socket の ping タイマーは現接続へ送らず自己解除する`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      const oldSocket = client.latestSocket();
      oldSocket.handlers.open?.();
      // join 期限切れで旧 socket は破棄され、続く再接続タイマーで新しい接続へ進む。
      client.runTimers();
      client.runTimers();
      const next = client.latestSocket();
      assert.notEqual(next, oldSocket);
      assert.deepEqual(client.intervalDelays(), [], "破棄した接続の ping タイマーが残っている");

      next.handlers.open?.();
      client.tickIntervals();
      assert.equal(pings(oldSocket).length, 0);
      assert.equal(pings(next).length, 1);
    } finally {
      client.dispose();
    }
  });

  test(`${name}: 恒久拒否で ping タイマーが止まる`, () => {
    const client = startClient(page);
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify({ type: "error", code: "room_full", message: "full" }),
      });
      assert.deepEqual(client.intervalDelays(), []);
    } finally {
      client.dispose();
    }
  });
}
