// handleServerMessage（web.gleam）が participant_joined / participant_left /
// buzz_accepted / round_reset / error の各分岐を正しく処理することの回帰テスト（#187）。
//
// harness.mjs の DOM スタブは replaceChildren を no-op にしているため（#log 以外の
// 描画結果は検証できない）、ここでは log() 呼び出しの内容で分岐の正しさを検証する。
// フィールド参照を取り違えても（例: message.participant.id と message.participant_id
// の混同）ログの内容やハンドラの例外で検知できる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

function joinAndConnect(client, participants = []) {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  socket.handlers.message?.({
    data: JSON.stringify({ type: "state", participants, buzzes: [] }),
  });
  return socket;
}

test("participant_joined は participants に追加されログに残る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "participant_joined",
        participant: { id: "p1", display_name: "Alice" },
      }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("joined: Alice")),
      "参加ログが残っていない",
    );
  } finally {
    client.dispose();
  }
});

test("participant_left はログに残る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_left", participant_id: "p1" }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("left: p1")),
      "退出ログが残っていない",
    );
  } finally {
    client.dispose();
  }
});

test("buzz_accepted はログに残り、同じ position の再配信は無視される（#43 の冪等化）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ id: "p1", display_name: "Alice" }]);
    const buzz = {
      type: "buzz_accepted",
      participant_id: "p1",
      position: 1,
    };
    socket.handlers.message?.({ data: JSON.stringify(buzz) });
    socket.handlers.message?.({ data: JSON.stringify(buzz) });

    const acceptedLogs = client.logs.filter((line) => line.includes("buzz accepted"));
    assert.equal(acceptedLogs.length, 1, "重複配信が二重にログされている");
    assert.ok(acceptedLogs[0].includes("p1"));
    assert.ok(acceptedLogs[0].includes("#1"));
  } finally {
    client.dispose();
  }
});

test("round_reset はログに残る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "buzz_accepted",
        participant_id: "p1",
        position: 1,
      }),
    });
    socket.handlers.message?.({ data: JSON.stringify({ type: "round_reset" }) });

    assert.ok(
      client.logs.some((line) => line.includes("round reset")),
      "リセットログが残っていない",
    );
  } finally {
    client.dispose();
  }
});

test("拒否以外のサーバー error はログに残るが接続は維持される", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "invalid_message", message: "bad frame" }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("error [invalid_message]: bad frame")),
      "エラーログが残っていない",
    );
    assert.equal(client.connectionState(), "connected", "拒否以外の error で接続が切られている");
  } finally {
    client.dispose();
  }
});

test("room_unavailable エラーは接続状態を未接続にリセットする", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "error",
        code: "room_unavailable",
        message: "room is gone",
      }),
    });

    assert.equal(client.connectionState(), "disconnected");
  } finally {
    client.dispose();
  }
});
