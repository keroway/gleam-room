// BUZZ ボタンの押下済み状態（#576）。#765 以降は推測をやめ、サーバの buzz 一覧と
// 応答待ちの要求（request_id）だけから決める。以前の相関IDなしの推測で個別に
// 塞いでいた取り違え（#689/#690/#708/#710/#724）は、ここで同じ場面を再現して
// 起きないことを確かめる。#768 以降、次の問題へ進めるのは司会だけなので、
// 参加者が自分で reset を送る場面（#689/#690/#708）はもう起きない。次の問題は
// 受付前（waiting）から始まり、司会が受付を開くまで BUZZ は押せない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import {
  buzzerState,
  buzzAccepted,
  roundReset,
  phaseChanged,
  reply,
  error,
  lastSent,
} from "./buzzer-wire.mjs";

function send(socket, message) {
  socket.handlers.message?.({ data: JSON.stringify(message) });
}

function joinAs(client, state = buzzerState()) {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  send(socket, state);
  return socket;
}

const aliceAndBob = (overrides = {}) =>
  buzzerState({
    selfId: "alice",
    participants: [
      { participant_id: "alice", display_name: "Alice" },
      { participant_id: "bob", display_name: "Bob" },
    ],
    ...overrides,
  });

test("BUZZ は現在の round と request_id を付けて送り、応答待ちの間はボタンを無効にする", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, buzzerState({ roundId: 3 }));
    assert.equal(client.isDisabled("buzz"), false);
    client.click("buzz");
    const sent = lastSent(socket, "buzz");
    assert.equal(sent.round_id, 3);
    assert.equal(typeof sent.request_id, "string");
    assert.equal(client.isDisabled("buzz"), true, "buzz 後もボタンが押せてしまう");
  } finally {
    client.dispose();
  }
});

test("自分の BUZZ が受理されたらボタンは無効のまま（直接応答と配信は1回だけ適用）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob());
    client.click("buzz");
    const { request_id } = lastSent(socket, "buzz");
    const accepted = buzzAccepted(2, { participantId: "alice", displayName: "Alice" });
    send(socket, reply(request_id, accepted));
    send(socket, accepted);
    assert.equal(client.isDisabled("buzz"), true);
    assert.deepEqual(client.childTextContents("buzzes"), ["Alice"]);
  } finally {
    client.dispose();
  }
});

test("BUZZ が拒否されたらボタンが有効に戻る（rate_limited など）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client);
    client.click("buzz");
    const { request_id } = lastSent(socket, "buzz");
    send(socket, reply(request_id, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), false, "拒否後もボタンが無効のまま");
  } finally {
    client.dispose();
  }
});

test("他参加者の受理通知の後に自分の BUZZ が拒否されたらボタンが有効に戻る（#710 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob());
    client.click("buzz");
    send(socket, buzzAccepted(2, { participantId: "bob", displayName: "Bob" }));
    send(socket, reply(lastSent(socket, "buzz").request_id, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), false);
  } finally {
    client.dispose();
  }
});

test("次の問題（round_reset）で受付前に戻り、司会が受付を開くと押せる", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob());
    client.click("buzz");
    send(
      socket,
      reply(lastSent(socket, "buzz").request_id,
        buzzAccepted(2, { participantId: "alice", displayName: "Alice" })),
    );
    send(socket, roundReset(3, 2));
    assert.equal(client.isDisabled("buzz"), true, "受付前なのに押せる");
    assert.deepEqual(client.childTextContents("buzzes"), []);
    send(socket, phaseChanged(4, "open", 2));
    assert.equal(client.isDisabled("buzz"), false, "受付開始後もボタンが無効のまま");
    client.click("buzz");
    assert.equal(lastSent(socket, "buzz").round_id, 2);
  } finally {
    client.dispose();
  }
});

test("次の問題で送った BUZZ が成功したらボタンは無効のまま（#724 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob({
      buzzes: [{ participant_id: "bob", display_name: "Bob", position: 1 }],
    }));
    send(socket, roundReset(2, 2));
    send(socket, phaseChanged(3, "open", 2));
    client.click("buzz");
    send(socket, buzzAccepted(4, { participantId: "alice", displayName: "Alice", roundId: 2 }));
    assert.equal(client.isDisabled("buzz"), true, "成功した本人のボタンが有効に戻った");
  } finally {
    client.dispose();
  }
});

test("reset 後の他参加者の成功通知では自分のボタンは有効のまま（#724 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob({
      buzzes: [{ participant_id: "bob", display_name: "Bob", position: 1 }],
    }));
    send(socket, roundReset(2, 2));
    send(socket, phaseChanged(3, "open", 2));
    send(socket, buzzAccepted(4, { participantId: "bob", displayName: "Bob", roundId: 2 }));
    assert.equal(client.isDisabled("buzz"), false, "他参加者の通知で無効化された");
  } finally {
    client.dispose();
  }
});

test("前の round を名指しした BUZZ は stale_round で拒否され、新しい round では押せる", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob());
    client.click("buzz");
    const staleId = lastSent(socket, "buzz").request_id;
    send(socket, reply(staleId, error("stale_round")));
    send(socket, roundReset(2, 2));
    send(socket, phaseChanged(3, "open", 2));
    assert.equal(client.isDisabled("buzz"), false);
  } finally {
    client.dispose();
  }
});

test("state に自分の buzz があれば最初から押下済みとして表示する（サーバ権威）", () => {
  const client = startClient();
  try {
    joinAs(client, aliceAndBob({
      buzzes: [{ participant_id: "alice", display_name: "Alice", position: 1 }],
    }));
    assert.equal(client.isDisabled("buzz"), true);
  } finally {
    client.dispose();
  }
});

test("already_buzzed なのに手元の一覧に無ければ state を取り直す", () => {
  const client = startClient();
  try {
    const socket = joinAs(client);
    client.click("buzz");
    send(socket, reply(lastSent(socket, "buzz").request_id, error("already_buzzed")));
    assert.ok(lastSent(socket, "sync"), "sync を要求していない");
  } finally {
    client.dispose();
  }
});

test("切断で応答待ちを捨て、再 join（state 受信）でボタンが有効に戻る", () => {
  const client = startClient();
  try {
    const socket = joinAs(client);
    client.click("buzz");
    socket.handlers.close?.();
    assert.equal(client.isDisabled("buzz"), true, "切断中は buzz が押せてはいけない");
    client.runTimers();
    const next = client.latestSocket();
    next.handlers.open?.();
    send(next, buzzerState({ instance: "inst-1", revision: 5 }));
    assert.equal(client.isDisabled("buzz"), false, "再 join 後もボタンが無効のまま");
  } finally {
    client.dispose();
  }
});

test("応答待ちの要求は上限を超えると古いものから捨てる", () => {
  const client = startClient();
  try {
    const socket = joinAs(client);
    // 押下を40回送る（ボタンは応答待ちで無効になるが、harness の click は
    // 無効でも発火する）。上限を超えた古い要求から捨てる。
    for (let i = 0; i < 40; i += 1) client.click("buzz");
    const ids = socket.sent.map((d) => JSON.parse(d)).filter((m) => m.request_id);
    // 最初の要求の応答は既に捨てた要求への応答になるが、例外にならない。
    send(socket, reply(ids[0].request_id, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), true, "最新の BUZZ の応答待ちが消えた");
  } finally {
    client.dispose();
  }
});
