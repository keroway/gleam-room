// BUZZ ボタンの押下済み状態（#576）。#765 以降は推測をやめ、サーバの buzz 一覧と
// 応答待ちの要求（request_id）だけから決める。以前の相関IDなしの推測で個別に
// 塞いでいた取り違え（#689/#690/#708/#710/#724）は、ここで同じ場面を再現して
// 起きないことを確かめる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import {
  buzzerState,
  buzzAccepted,
  roundReset,
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

test("BUZZ と reset を続けて送り、reset だけが拒否されても BUZZ の応答待ちは残る（#708 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client);
    client.click("buzz");
    const buzzId = lastSent(socket, "buzz").request_id;
    client.click("reset");
    const resetId = lastSent(socket, "reset").request_id;
    send(socket, reply(resetId, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), true, "reset の拒否で BUZZ の応答待ちが解除された");
    send(socket, reply(buzzId, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), false, "両方の拒否後もボタンが無効のまま");
  } finally {
    client.dispose();
  }
});

test("受理済み BUZZ の後の reset が拒否されても押下済みのまま（#690 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob());
    client.click("buzz");
    send(
      socket,
      reply(lastSent(socket, "buzz").request_id,
        buzzAccepted(2, { participantId: "alice", displayName: "Alice" })),
    );
    client.click("reset");
    send(socket, reply(lastSent(socket, "reset").request_id, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), true, "reset 拒否で押下済み状態が解除された");
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

test("round_reset で次の round に進み、ボタンが有効に戻る", () => {
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
    assert.equal(client.isDisabled("buzz"), false, "round_reset 後もボタンが無効のまま");
    assert.deepEqual(client.childTextContents("buzzes"), []);
    client.click("buzz");
    assert.equal(lastSent(socket, "buzz").round_id, 2);
  } finally {
    client.dispose();
  }
});

test("reset の応答後に送った BUZZ は reset の配信コピーで押下可能に戻らない（#689 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob());
    client.click("reset");
    send(socket, reply(lastSent(socket, "reset").request_id, roundReset(2, 2)));
    client.click("buzz");
    send(socket, roundReset(2, 2));
    assert.equal(client.isDisabled("buzz"), true, "配信コピーで押下済み状態が解除された");
  } finally {
    client.dispose();
  }
});

test("reset の応答前に送った BUZZ が新しい round で成功したらボタンは無効のまま（#724 の場面）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, aliceAndBob({
      buzzes: [{ participant_id: "bob", display_name: "Bob", position: 1 }],
    }));
    client.click("reset");
    send(socket, roundReset(2, 2));
    client.click("buzz");
    send(socket, buzzAccepted(3, { participantId: "alice", displayName: "Alice", roundId: 2 }));
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
    send(socket, buzzAccepted(3, { participantId: "bob", displayName: "Bob", roundId: 2 }));
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
    for (let i = 0; i < 40; i += 1) client.click("reset");
    client.click("buzz");
    const ids = socket.sent.map((d) => JSON.parse(d)).filter((m) => m.request_id);
    // 最初の reset の応答は既に捨てた要求への応答になるが、例外にならない。
    send(socket, reply(ids[0].request_id, error("rate_limited")));
    assert.equal(client.isDisabled("buzz"), true, "最新の BUZZ の応答待ちが消えた");
  } finally {
    client.dispose();
  }
});
