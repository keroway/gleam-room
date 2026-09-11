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
    // reveal/reset の初期 disabled は静的HTML由来（<button disabled>）で、
    // setConnected() を経由しないためこの harness では再現されない。ここで
    // 検証するのは open だけでは setConnected(true) が呼ばれない（join/room-id/
    // display-name が無効化されない）ことに限る。
    assert.equal(client.isDisabled("join"), false, "join未成立でjoinボタンが無効化されている");
    assert.equal(client.isDisabled("room-id"), false, "join未成立でroom-id入力欄が無効化されている");
    assert.equal(
      client.isDisabled("display-name"),
      false,
      "join未成立でdisplay-name入力欄が無効化されている",
    );
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
    assert.equal(client.isDisabled("reveal"), false, "join成立後もrevealが無効化されたまま");
    assert.equal(client.isDisabled("reset"), false, "join成立後もresetが無効化されたまま");
    assert.equal(client.isDisabled("join"), true, "join成立後もjoinボタンが押せてしまう");
    assert.equal(client.isDisabled("room-id"), true, "join成立後もroom-id入力欄が編集できてしまう");
    assert.equal(
      client.isDisabled("display-name"),
      true,
      "join成立後もdisplay-name入力欄が編集できてしまう",
    );
  } finally {
    client.dispose();
  }
});

test("join成立後にソケットが切断されると再度 join できる状態に戻る", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.message?.({
      data: JSON.stringify({ type: "state", phase: "voting", participants: [] }),
    });
    socket.handlers.close?.();

    assert.equal(client.connectionState(), "disconnected");
    assert.equal(client.isDisabled("reveal"), true, "切断後もrevealが押せてしまう");
    assert.equal(client.isDisabled("reset"), true, "切断後もresetが押せてしまう");
    assert.equal(client.isDisabled("join"), false, "切断後にjoinボタンが無効化されたまま");
    assert.equal(client.isDisabled("room-id"), false, "切断後にroom-id入力欄が無効化されたまま");
    assert.equal(
      client.isDisabled("display-name"),
      false,
      "切断後にdisplay-name入力欄が無効化されたまま",
    );
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
      assert.equal(client.isDisabled("reveal"), true, `${code}拒否後もrevealが押せてしまう`);
      assert.equal(client.isDisabled("reset"), true, `${code}拒否後もresetが押せてしまう`);
      assert.equal(
        client.isDisabled("join"),
        false,
        `${code}拒否後にjoinボタンが無効化されたまま`,
      );

      const before = client.sockets.length;
      client.submitJoin();
      assert.equal(client.sockets.length, before + 1, "再度joinできていない");
    } finally {
      client.dispose();
    }
  });
}

// 空白のみの入力で無音 no-op になる問題の回帰テスト（#123 / buzzer側 join-ui.test.mjs と同型）。
for (const [roomId, displayName] of [
  [" ", "N"],
  ["R", " "],
  ["", ""],
]) {
  test(`room ID/display name が空白のみだと接続を試みずログに理由を出す (roomId=${JSON.stringify(roomId)}, displayName=${JSON.stringify(displayName)})`, () => {
    const client = startClient(POKER_MODULE);
    try {
      client.submitJoin(roomId, displayName);

      assert.equal(client.sockets.length, 0, "空白のみの入力で接続を試みてはいけない");
      assert.ok(
        client.logs.some((line) => line.includes("入力してください")),
        "理由がログに出ていない",
      );
    } finally {
      client.dispose();
    }
  });
}

// socket確立中(open〜state受信前)の二重submitが無音で握りつぶされる問題の
// 回帰テスト（#458 / buzzer側 join-ui.test.mjs と同型）。
test("socket確立中の二重submitはログを残して新規接続を開始しない", () => {
  const client = startClient(POKER_MODULE);
  try {
    client.submitJoin();
    client.latestSocket().handlers.open?.();

    const before = client.sockets.length;
    client.submitJoin();

    assert.equal(client.sockets.length, before, "socket確立中に再度接続を試みてはいけない");
    assert.ok(
      client.logs.some((line) => line.includes("already connecting or connected")),
      "二重submitの理由がログに出ていない",
    );
  } finally {
    client.dispose();
  }
});

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
