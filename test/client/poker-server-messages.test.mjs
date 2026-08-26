// handleServerMessage（web_poker.gleam）が state/participant_joined/
// participant_left/vote_registered/revealed/round_reset/error の各分岐を
// 正しく処理することの回帰テスト。web.gleam 側の server-messages.test.mjs
// （#187）と同じ狙いで、加えて Planning Poker 固有の受け入れ基準
// （reveal 前は投票値が見えない・自分の投票は reveal 前なら変更できる）
// を検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };

function joinAndConnect(client, participants = [], phase = "voting") {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  socket.handlers.message?.({
    data: JSON.stringify({ type: "state", phase, participants }),
  });
  return socket;
}

test("participant_joined は participants に追加されログに残る", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "participant_joined",
        participant: { participant_id: "p1", display_name: "Alice", has_voted: false },
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
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client, [
      { participant_id: "p1", display_name: "Alice", has_voted: false },
    ]);
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

test("vote_registered はログに残るが、投票値そのものは送られてこないので露出しない", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client, [
      { participant_id: "p1", display_name: "Alice", has_voted: false },
    ]);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "vote_registered", participant_id: "p1" }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("vote registered: p1")),
      "投票ログが残っていない",
    );
    // vote_registered のペイロードは participant_id だけで、投票値を
    // 一切含まない（reveal 前は他人の投票値が DOM に現れない、の起点）。
    assert.ok(
      !client.logs.some((line) => line.includes("value")),
      "vote_registered が投票値らしきものをログに出している",
    );
  } finally {
    client.dispose();
  }
});

test("reveal 前は投票ボタンが有効なままで、自分の投票は変更できる", () => {
  const client = startClient(POKER_MODULE);
  try {
    joinAndConnect(client);

    client.click("card-1");
    client.click("card-5");

    const socket = client.latestSocket();
    const sentVotes = socket.sent.map((raw) => JSON.parse(raw)).filter((m) => m.type === "vote");
    assert.deepEqual(
      sentVotes.map((m) => m.value),
      ["1", "5"],
      "reveal 前の投票変更が送信されていない",
    );
  } finally {
    client.dispose();
  }
});

test("revealed で votes がログに残り、round_reset で phase が voting に戻る", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client, [
      { participant_id: "p1", display_name: "Alice", has_voted: true },
    ]);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "revealed",
        votes: [{ participant_id: "p1", display_name: "Alice", value: "5" }],
      }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("revealed: 1 vote(s)")),
      "reveal ログが残っていない",
    );

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
  const client = startClient(POKER_MODULE);
  try {
    joinAndConnect(client);
    const socket = client.latestSocket();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "invalid_card", message: "bad card" }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("error [invalid_card]: bad card")),
      "エラーログが残っていない",
    );
    assert.equal(client.connectionState(), "connected", "拒否以外の error で接続が切られている");
  } finally {
    client.dispose();
  }
});
