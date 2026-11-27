// 短時間の切断から同じ参加者として戻る（#766）。join の応答で受け取った
// resume token をタブ単位の sessionStorage に保存し、再接続・再読み込みでは
// join ではなく resume を送る。戻れなかったときは理由と新規参加の導線を出す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import { buzzerState, INSTANCE, lastSent } from "./buzzer-wire.mjs";

const RESUME_KEY = "gleamroom.buzzer.resume";
const TOKEN = "token-abc";

function send(socket, message) {
  socket.handlers.message?.({ data: JSON.stringify(message) });
}

function saved(client) {
  const raw = client.storage.get(RESUME_KEY);
  return raw === undefined ? null : JSON.parse(raw);
}

function joinWithToken(client, roomId = "R", displayName = "N") {
  client.submitJoin(roomId, displayName);
  const socket = client.latestSocket();
  socket.handlers.open?.();
  send(socket, { ...buzzerState({ selfId: "me" }), resume_token: TOKEN });
  return socket;
}

const savedSession = {
  [RESUME_KEY]: JSON.stringify({
    room_id: "R",
    display_name: "N",
    room_instance_id: INSTANCE,
    resume_token: TOKEN,
  }),
};

test("join の応答の resume token を部屋・名前・部屋の世代と一緒に保存する", () => {
  const client = startClient();
  try {
    const socket = joinWithToken(client);
    assert.equal(lastSent(socket, "join").v, 2);
    assert.deepEqual(saved(client), {
      room_id: "R",
      display_name: "N",
      room_instance_id: INSTANCE,
      resume_token: TOKEN,
    });
  } finally {
    client.dispose();
  }
});

test("切断後の自動再接続は join ではなく resume を送る", () => {
  const client = startClient();
  try {
    const socket = joinWithToken(client);
    socket.handlers.close?.();
    client.runTimers();
    const next = client.latestSocket();
    next.handlers.open?.();
    const first = JSON.parse(next.sent[0]);
    assert.deepEqual(first, {
      type: "resume",
      v: 2,
      room_id: "R",
      room_instance_id: INSTANCE,
      resume_token: TOKEN,
    });
    // resume の応答には token が付かない。保存済みのものを使い続ける。
    send(next, buzzerState({ selfId: "me", revision: 3 }));
    assert.equal(client.connectionState(), "connected");
    assert.equal(saved(client).resume_token, TOKEN);
  } finally {
    client.dispose();
  }
});

test("ページを開き直すと保存した参加に自動で戻る", () => {
  const client = startClient({ storage: savedSession });
  try {
    assert.equal(client.sockets.length, 1, "保存した参加があるのに接続していない");
    const socket = client.latestSocket();
    socket.handlers.open?.();
    assert.equal(JSON.parse(socket.sent[0]).type, "resume");
    send(socket, buzzerState({ selfId: "me" }));
    assert.equal(client.connectionState(), "connected");
  } finally {
    client.dispose();
  }
});

test("保存が無ければページを開いても接続しない", () => {
  const client = startClient();
  try {
    assert.equal(client.sockets.length, 0);
  } finally {
    client.dispose();
  }
});

test("別の名前で参加し直すときは保存した token を使わない（表示名では戻れない）", () => {
  const client = startClient({ storage: savedSession });
  try {
    // 自動復帰を断念させてから、別の名前でフォームから参加する。
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, { type: "error", code: "invalid_token", message: "x" });
    client.submitJoin("R", "Other");
    const next = client.latestSocket();
    next.handlers.open?.();
    assert.equal(JSON.parse(next.sent[0]).type, "join");
  } finally {
    client.dispose();
  }
});

for (const code of ["room_gone", "resume_expired", "invalid_token"]) {
  test(`${code} なら token を捨て、理由と新規参加の導線を出し、再接続しない`, () => {
    const client = startClient({ storage: savedSession });
    try {
      const socket = client.latestSocket();
      socket.handlers.open?.();
      send(socket, { type: "error", code, message: "x" });
      assert.equal(saved(client), null, "戻れない token が残っている");
      assert.equal(client.connectionState(), "resume-failed");
      assert.match(client.textOf("status"), /新しい参加者として参加できます/);
      assert.equal(client.isDisabled("join"), false, "新規参加できない");
      assert.equal(client.pendingTimers(), 0, "戻れないのに再接続を予約した");
      // 次の参加は新規 join になる。
      client.submitJoin("R", "N");
      const next = client.latestSocket();
      next.handlers.open?.();
      assert.equal(JSON.parse(next.sent[0]).type, "join");
    } finally {
      client.dispose();
    }
  });
}

test("session_replaced なら再接続せず、別の画面で接続し直したことを伝える", () => {
  const client = startClient();
  try {
    const socket = joinWithToken(client);
    send(socket, { type: "error", code: "session_replaced", message: "x" });
    socket.handlers.close?.();
    assert.equal(client.connectionState(), "replaced");
    assert.equal(client.pendingTimers(), 0, "取り合いになる再接続を予約した");
    assert.equal(saved(client), null);
  } finally {
    client.dispose();
  }
});

test("Leave は leave を送って token を捨て、再接続しない", () => {
  const client = startClient();
  try {
    const socket = joinWithToken(client);
    assert.equal(client.isDisabled("leave"), false);
    client.click("leave");
    assert.ok(lastSent(socket, "leave"), "leave を送っていない");
    assert.equal(saved(client), null);
    assert.equal(client.isDisabled("leave"), true);
    socket.handlers.close?.();
    assert.equal(client.pendingTimers(), 0, "退出後に再接続を予約した");
    assert.equal(client.sockets.length, 1);
  } finally {
    client.dispose();
  }
});

test("切断中の参加者は印付きで残り、戻ると印が消える", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, buzzerState({
      selfId: "me",
      participants: [
        { participant_id: "me", display_name: "Me", connected: true },
        { participant_id: "bob", display_name: "Bob", connected: true },
      ],
    }));
    send(socket, {
      type: "participant_disconnected",
      room_instance_id: INSTANCE,
      revision: 2,
      participant_id: "bob",
    });
    assert.deepEqual(client.childTextContents("participants"), ["Me", "Bob（切断中）"]);
    send(socket, {
      type: "participant_reconnected",
      room_instance_id: INSTANCE,
      revision: 3,
      participant_id: "bob",
    });
    assert.deepEqual(client.childTextContents("participants"), ["Me", "Bob"]);
  } finally {
    client.dispose();
  }
});

test("state の参加者の connected=false も印付きで描画する", () => {
  const client = startClient();
  try {
    client.submitJoin();
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, buzzerState({
      participants: [{ participant_id: "bob", display_name: "Bob", connected: false }],
    }));
    assert.deepEqual(client.childTextContents("participants"), ["Bob（切断中）"]);
  } finally {
    client.dispose();
  }
});
