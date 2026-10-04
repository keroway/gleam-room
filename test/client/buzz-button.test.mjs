// BUZZ ボタンの「buzz 済み」状態（#576）。サーバーは自分の参加者IDを渡さないため、
// クリックで楽観的に無効化し、already_buzzed で確定、round_reset/state/切断で戻す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

function joinAndConnect(client) {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  socket.handlers.message?.({
    data: JSON.stringify({ type: "state", participants: [], buzzes: [] }),
  });
  return socket;
}

function send(socket, message) {
  socket.handlers.message?.({ data: JSON.stringify(message) });
}

test("BUZZ をクリックするとボタンが無効化される", () => {
  const client = startClient();
  try {
    joinAndConnect(client);
    assert.equal(client.isDisabled("buzz"), false);
    client.click("buzz");
    assert.equal(client.isDisabled("buzz"), true, "buzz 後もボタンが押せてしまう");
  } finally {
    client.dispose();
  }
});

test("already_buzzed エラーではボタンが無効のまま維持される", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    client.click("buzz");
    send(socket, { type: "error", code: "already_buzzed", message: "already buzzed" });
    assert.equal(client.isDisabled("buzz"), true, "already_buzzed 後にボタンが有効に戻った");
  } finally {
    client.dispose();
  }
});

test("rate_limited などで buzz が拒否されたらボタンが有効に戻る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    client.click("buzz");
    send(socket, { type: "error", code: "rate_limited", message: "slow down" });
    assert.equal(client.isDisabled("buzz"), false, "拒否後もボタンが無効のまま");
  } finally {
    client.dispose();
  }
});

test("round_reset でボタンが有効に戻る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    client.click("buzz");
    send(socket, { type: "round_reset" });
    assert.equal(client.isDisabled("buzz"), false, "round_reset 後もボタンが無効のまま");
  } finally {
    client.dispose();
  }
});

test("切断後の再 join（state 受信）でボタンが有効に戻る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    client.click("buzz");
    socket.handlers.close?.();
    assert.equal(client.isDisabled("buzz"), true, "切断中は buzz が押せてはいけない");
    joinAndConnect(client);
    assert.equal(client.isDisabled("buzz"), false, "再 join 後もボタンが無効のまま");
  } finally {
    client.dispose();
  }
});
