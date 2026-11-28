// 司会・参加者・会場表示の画面と受付の段階（#768）。どのボタンを出すかは
// サーバの state と通知（self_role・phase）だけで決める。権限はサーバが
// 確かめるので、ここで見るのは案内として正しい部品が出ているかどうか。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import {
  buzzerState,
  buzzAccepted,
  error,
  INSTANCE,
  lastSent,
  participant,
  phaseChanged,
  reply,
  roundReset,
} from "./buzzer-wire.mjs";

const RESUME_KEY = "gleamroom.buzzer.resume";

function send(socket, message) {
  socket.handlers.message?.({ data: JSON.stringify(message) });
}

function joinAs(client, state) {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  send(socket, state);
  return socket;
}

const people = [
  participant("host", "Host", { role: "host" }),
  participant("alice", "Alice"),
  participant("bob", "Bob"),
  participant("carol", "Carol", { connected: false }),
];

const asHost = (overrides = {}) =>
  buzzerState({ selfId: "host", selfRole: "host", phase: "waiting", participants: people, ...overrides });

const asPlayer = (overrides = {}) =>
  buzzerState({ selfId: "alice", selfRole: "player", phase: "waiting", participants: people, ...overrides });

test("参加者は受付前は押せず、受付が始まると押せる。最初の BUZZ で回答者を出す", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, asPlayer());
    assert.equal(client.isDisabled("buzz"), true, "受付前なのに押せる");
    assert.match(client.textOf("phase"), /受付前/);
    assert.equal(client.node("player-help").hidden, false, "参加者向けの説明が無い");
    assert.equal(client.node("host-panel").hidden, true, "参加者に司会の操作が出ている");

    send(socket, phaseChanged(2, "open"));
    assert.equal(client.isDisabled("buzz"), false);
    assert.match(client.textOf("phase"), /受付中/);

    send(socket, buzzAccepted(3, { participantId: "bob", displayName: "Bob" }));
    assert.match(client.textOf("phase"), /回答者：Bob/);
    // 回答者が決まった後も、まだ押していなければ押せる（順番に積まれる）。
    assert.equal(client.isDisabled("buzz"), false);
  } finally {
    client.dispose();
  }
});

test("参加者一覧で司会が分かり、人数は参加者だけを数える", () => {
  const client = startClient();
  try {
    joinAs(client, asPlayer());
    assert.deepEqual(client.childTextContents("participants"), [
      "Host（司会）",
      "Alice",
      "Bob",
      "Carol（切断中）",
    ]);
    assert.equal(client.textOf("participant-count"), "（3人）");
  } finally {
    client.dispose();
  }
});

test("司会には操作パネルが出て BUZZ は出ない。段階に合う操作だけ押せる", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, asHost());
    assert.equal(client.node("host-panel").hidden, false);
    assert.equal(client.node("buzz").hidden, true, "司会に BUZZ が出ている");
    const enabled = () =>
      ["open-acceptance", "close-acceptance", "skip", "next-question"].filter(
        (id) => !client.isDisabled(id),
      );
    assert.deepEqual(enabled(), ["open-acceptance", "next-question"]);

    client.click("open-acceptance");
    assert.deepEqual(
      { type: lastSent(socket, "open").type, round: lastSent(socket, "open").round_id },
      { type: "open", round: 1 },
    );
    send(socket, phaseChanged(2, "open"));
    assert.deepEqual(enabled(), ["close-acceptance", "skip", "next-question"]);

    send(socket, buzzAccepted(3, { participantId: "alice", displayName: "Alice" }));
    assert.deepEqual(enabled(), ["skip", "next-question"]);
    assert.match(client.textOf("phase"), /回答者：Alice/);

    client.click("next-question");
    assert.equal(lastSent(socket, "next_question").round_id, 1);
    send(socket, roundReset(4, 2));
    assert.deepEqual(enabled(), ["open-acceptance", "next-question"]);
    client.click("open-acceptance");
    assert.equal(lastSent(socket, "open").round_id, 2, "新しい問題の round を名指ししていない");
  } finally {
    client.dispose();
  }
});

test("会場表示へのリンクは部屋コードの /display を指す", () => {
  const client = startClient();
  try {
    joinAs(client, asHost());
    assert.equal(client.node("display-link").href, "http://127.0.0.1:4000/r/R/display");
  } finally {
    client.dispose();
  }
});

test("部屋の終了は2回押して確定する", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, asHost());
    client.click("end-session");
    assert.equal(lastSent(socket, "end_session"), undefined, "1回目で終了を送った");
    assert.match(client.textOf("end-session"), /もう一度押すと終了/);
    client.click("end-session");
    assert.ok(lastSent(socket, "end_session"));

    send(socket, phaseChanged(2, "finished"));
    assert.match(client.textOf("phase"), /終了しました/);
    for (const id of ["open-acceptance", "next-question", "end-session", "transfer-host"]) {
      assert.equal(client.isDisabled(id), true, `終了後も ${id} が押せる`);
    }
  } finally {
    client.dispose();
  }
});

test("終了した部屋では参加者も押せない", () => {
  const client = startClient();
  try {
    joinAs(client, asPlayer({ phase: "finished" }));
    assert.equal(client.isDisabled("buzz"), true);
    assert.equal(client.node("player-help").hidden, true);
  } finally {
    client.dispose();
  }
});

test("司会を渡せる相手は接続中の参加者だけで、選んだ相手の id を送る", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, asHost());
    assert.deepEqual(client.childTextContents("transfer-target"), ["Alice", "Bob"]);
    client.node("transfer-target").value = "bob";
    client.click("transfer-host");
    const sent = lastSent(socket, "transfer_host");
    assert.equal(sent.participant_id, "bob");
    assert.equal(typeof sent.request_id, "string");
  } finally {
    client.dispose();
  }
});

test("司会を渡すと参加者になり、保存していた司会 token を消す", () => {
  const storage = {
    [RESUME_KEY]: JSON.stringify({
      room_id: "R",
      display_name: "N",
      room_instance_id: INSTANCE,
      resume_token: "resume-secret",
      host_token: "host-secret",
    }),
  };
  const client = startClient({ storage });
  try {
    const socket = client.latestSocket();
    socket.handlers.open?.();
    const resume = JSON.parse(socket.sent[0]);
    assert.equal(resume.type, "resume");
    assert.equal(resume.host_token, "host-secret", "司会 token を添えて戻っていない");
    send(socket, asHost());

    send(socket, { type: "host_transferred", room_instance_id: INSTANCE, revision: 2, from: "host", to: "alice" });
    assert.equal(client.node("host-panel").hidden, true);
    assert.equal(client.node("buzz").hidden, false);
    assert.match(client.textOf("notice"), /司会を渡しました/);
    const saved = JSON.parse(client.storage.get(RESUME_KEY));
    assert.equal(saved.host_token, undefined);
    assert.equal(saved.resume_token, "resume-secret");
  } finally {
    client.dispose();
  }
});

test("司会を受け取ると操作パネルが出て、届いた司会 token を保存する（ログには出さない）", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, { ...asPlayer(), resume_token: "resume-secret" });
    send(socket, { type: "host_transferred", room_instance_id: INSTANCE, revision: 2, from: "host", to: "alice" });
    send(socket, { type: "host_assigned", host_token: "new-host-secret" });
    assert.equal(client.node("host-panel").hidden, false);
    assert.match(client.textOf("notice"), /あなたが司会になりました/);
    assert.equal(JSON.parse(client.storage.get(RESUME_KEY)).host_token, "new-host-secret");
    assert.ok(!client.logs.join("\n").includes("new-host-secret"));
    assert.deepEqual(client.childTextContents("participants").slice(0, 2), ["Host", "Alice（司会）"]);
  } finally {
    client.dispose();
  }
});

test("操作が通らなかった理由を画面に出し、接続は続ける", () => {
  const client = startClient();
  try {
    const socket = joinAs(client, asPlayer());
    client.click("buzz");
    send(socket, reply(lastSent(socket, "buzz").request_id, error("not_accepting")));
    assert.match(client.textOf("notice"), /まだ受付が始まっていません/);
    assert.equal(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});

test("終了した部屋に参加しようとすると理由を出し、新しく作る導線を出す", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, error("session_finished"));
    assert.match(client.textOf("status"), /終了しています/);
    assert.equal(client.pendingTimers(), 0);
    assert.equal(client.node("create-form").hidden, false);
  } finally {
    client.dispose();
  }
});

test("会場表示は名前を入れずにすぐ watch で見始め、操作部品を出さない", () => {
  const client = startClient({ pathname: "/r/k7m2qx/display" });
  try {
    assert.equal(client.node("entry").hidden, true, "入力欄が出ている");
    const socket = client.latestSocket();
    assert.ok(socket, "会場表示が接続していない");
    socket.handlers.open?.();
    assert.deepEqual(JSON.parse(socket.sent[0]), { type: "watch", v: 2, room_id: "K7M2QX" });

    send(socket, buzzerState({ selfId: null, selfRole: "display", phase: "open", participants: people }));
    assert.equal(client.connectionState(), "connected");
    assert.equal(client.node("buzz").hidden, true);
    assert.equal(client.node("host-panel").hidden, true);
    assert.equal(client.node("leave").hidden, true);
    // 招待は静的 HTML で hidden。会場表示では一度も表示しない。
    assert.notEqual(client.node("invite").hidden, false, "会場表示に招待が出ている");
    assert.equal(client.node("display-help").hidden, false);
    assert.match(client.textOf("phase"), /受付中/);

    send(socket, buzzAccepted(2, { participantId: "bob", displayName: "Bob" }));
    assert.match(client.textOf("phase"), /回答者：Bob/);
    assert.deepEqual(client.childTextContents("buzzes"), ["Bob"]);
    assert.equal(client.storage.get(RESUME_KEY), undefined, "会場表示が参加情報を保存した");
  } finally {
    client.dispose();
  }
});

test("会場表示は切れても入力欄を出さず、自動で見直す", () => {
  const client = startClient({ pathname: "/r/K7M2QX/display" });
  try {
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, buzzerState({ selfId: null, selfRole: "display" }));
    socket.handlers.close?.();
    assert.equal(client.node("entry").hidden, true);
    client.runTimers();
    const next = client.latestSocket();
    assert.notEqual(next, socket);
    next.handlers.open?.();
    assert.equal(JSON.parse(next.sent[0]).type, "watch");
  } finally {
    client.dispose();
  }
});
