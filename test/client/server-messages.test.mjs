// handleServerMessage（web.gleam）が participant_joined / participant_left /
// buzz_accepted / round_reset / error の各分岐を正しく処理することの回帰テスト（#187）。
//
// log() 呼び出しの内容に加えて、childTextContents() で participants/buzzes 要素
// への描画結果も検証する（#389: harness.mjs の replaceChildren スタブが no-op
// だった間は描画内容を一切検証できていなかった）。フィールド参照を取り違えても
// （例: message.participant.id と message.participant_id の混同）ログの内容や
// ハンドラの例外、DOM への描画内容で検知できる。
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
    assert.deepEqual(
      client.childTextContents("participants"),
      ["Alice"],
      "participants 要素に Alice が描画されていない",
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
    assert.deepEqual(
      client.childTextContents("participants"),
      [],
      "退出後も participants 要素に描画が残っている",
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
      display_name: "Alice",
      position: 1,
    };
    socket.handlers.message?.({ data: JSON.stringify(buzz) });
    socket.handlers.message?.({ data: JSON.stringify(buzz) });

    const acceptedLogs = client.logs.filter((line) => line.includes("buzz accepted"));
    assert.equal(acceptedLogs.length, 1, "重複配信が二重にログされている");
    assert.ok(acceptedLogs[0].includes("p1"));
    assert.ok(acceptedLogs[0].includes("#1"));
    assert.deepEqual(
      client.childTextContents("buzzes"),
      ["Alice"],
      "buzzes 要素に順序付けたブザーが描画されていない",
    );
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
    assert.deepEqual(
      client.childTextContents("buzzes"),
      [],
      "round_reset 後も buzzes 要素にブザーが残っている",
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

test("壊れた JSON の message イベントは例外を漏らさずログに残り、直前の participants 状態を保つ（#324）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ id: "p1", display_name: "Alice" }]);
    const logsBeforeMalformed = client.logs.length;

    socket.handlers.message?.({ data: "not valid json" });

    assert.ok(
      client.logs.some((line) => line.includes("could not parse server message")),
      "パース失敗ログが残っていない",
    );
    assert.equal(
      client.logs.length,
      logsBeforeMalformed + 1,
      "パース失敗以外のログが増えている（状態が変化した疑い）",
    );

    // 直前の participants 状態が壊れていなければ、既存参加者の退出は
    // 通常どおり処理されるはず。
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_left", participant_id: "p1" }),
    });
    assert.ok(
      client.logs.some((line) => line.includes("left: p1")),
      "壊れた JSON の後で participants 状態が失われている",
    );
  } finally {
    client.dispose();
  }
});

test("state メッセージが妥当なJSONだが participants フィールド欠落だと、connected にならず誤って「パース失敗」と表示されない（#478）", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();

    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", buzzes: [] }),
    });

    assert.notEqual(
      client.connectionState(),
      "connected",
      "参加者情報が反映できないのに connected 扱いになっている",
    );
    assert.ok(
      client.logs.some((line) => line.includes("state message missing expected fields")),
      "形状不正を示すログが残っていない",
    );
    assert.ok(
      !client.logs.some((line) => line.includes("could not parse server message")),
      "JSON 自体は妥当なパースに成功しているのに「パース失敗」と誤ログされている",
    );
  } finally {
    client.dispose();
  }
});

test("未知の message.type はエラーにせずログに残す（#440: プロトコルドリフトの防衛線）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ id: "p1", display_name: "Alice" }]);
    const logsBeforeUnknown = client.logs.length;

    assert.doesNotThrow(() => {
      socket.handlers.message?.({
        data: JSON.stringify({ type: "some_future_message_type", foo: "bar" }),
      });
    });

    assert.ok(
      client.logs.some((line) => line.includes("unrecognized message")),
      "未知メッセージのログが残っていない",
    );
    assert.equal(
      client.logs.length,
      logsBeforeUnknown + 1,
      "未知メッセージ以外のログが増えている（状態が変化した疑い）",
    );
    assert.deepEqual(
      client.childTextContents("participants"),
      ["Alice"],
      "未知メッセージで既存の participants 描画が壊れている",
    );
  } finally {
    client.dispose();
  }
});

// join 拒否コード（#265/#314 相当）: サーバーが接続を閉じずに error を返す場合でも
// UI を即座に未接続へ戻し、フォームを再送信可能にする必要がある。
for (const code of ["room_full", "invalid_room_id", "invalid_display_name", "room_unavailable"]) {
  test(`${code} エラーは接続状態を未接続にリセットする`, () => {
    const client = startClient();
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({
        data: JSON.stringify({ type: "error", code, message: "rejected" }),
      });

      assert.equal(client.connectionState(), "disconnected");
    } finally {
      client.dispose();
    }
  });
}
