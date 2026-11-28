// 部屋の作成と招待（#767）。作成はサーバが部屋コードを発行し、作った本人への
// state にだけ部屋コードと司会 token が付く。招待 URL（/r/部屋コード）と QR には
// 部屋コードだけを載せ、token は載せない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import { clientJsConst } from "./extract.mjs";
import { buzzerState, INSTANCE, lastSent } from "./buzzer-wire.mjs";

const RESUME_KEY = "gleamroom.buzzer.resume";
const CODE = "K7M2QX";
const RESUME_TOKEN = "resume-secret";
const HOST_TOKEN = "host-secret";

function send(socket, message) {
  socket.handlers.message?.({ data: JSON.stringify(message) });
}

function saved(client) {
  const raw = client.storage.get(RESUME_KEY);
  return raw === undefined ? null : JSON.parse(raw);
}

const qrMatrix = new Function(`${clientJsConst("qr_code")}; return qrMatrix;`)();

function qrPath(text, quietZone = 4) {
  let d = "";
  qrMatrix(text).forEach((row, y) => {
    row.forEach((dark, x) => {
      if (dark) d += `M${x + quietZone} ${y + quietZone}h1v1h-1z`;
    });
  });
  return d;
}

function created(client, displayName = "Host") {
  client.submitCreate(displayName);
  const socket = client.latestSocket();
  socket.handlers.open?.();
  send(socket, {
    ...buzzerState({ selfId: "me" }),
    resume_token: RESUME_TOKEN,
    room_id: CODE,
    host_token: HOST_TOKEN,
  });
  return socket;
}

test("部屋を作ると create を送り、部屋コードと token を保存して招待を出す", () => {
  const client = startClient();
  try {
    const socket = created(client);
    assert.deepEqual(JSON.parse(socket.sent[0]), {
      type: "create",
      v: 2,
      display_name: "Host",
    });
    assert.equal(client.connectionState(), "connected");
    assert.deepEqual(saved(client), {
      room_id: CODE,
      display_name: "Host",
      room_instance_id: INSTANCE,
      resume_token: RESUME_TOKEN,
      host_token: HOST_TOKEN,
    });
    // 再読み込みしても同じ部屋に戻れるよう、アドレスを招待 URL にする。
    assert.deepEqual(client.historyUrls, [`/r/${CODE}`]);
    assert.equal(client.node("invite").hidden, false);
    assert.equal(client.textOf("invite-code"), CODE);
    assert.equal(client.node("invite-url").value, `http://127.0.0.1:4000/r/${CODE}`);
    const [svg] = client.node("invite-qr").children;
    assert.equal(svg.id, "svg", "QR の SVG が描かれていない");
  } finally {
    client.dispose();
  }
});

test("招待 URL・QR・ログに token が出ない", () => {
  const client = startClient();
  try {
    const socket = created(client);
    const url = client.node("invite-url").value;
    assert.equal(url, `http://127.0.0.1:4000/r/${CODE}`);
    assert.ok(!url.includes(RESUME_TOKEN) && !url.includes(HOST_TOKEN));
    // QR の座標には token が平文で出ないので、描いた暗モジュールが「部屋コード
    // だけの招待 URL」の QR と一致することで、token を符号化していないと確かめる。
    const [svg] = client.node("invite-qr").children;
    const path = svg.children.find((child) => child.id === "path");
    assert.equal(path.getAttribute("d"), qrPath(url));
    // 形の崩れたメッセージは丸ごとログに書くが、token の値は伏せる。
    send(socket, { type: "state", resume_token: RESUME_TOKEN, host_token: HOST_TOKEN });
    const logs = client.logs.join("\n");
    assert.ok(logs.includes("state message missing expected fields"));
    assert.ok(!logs.includes(RESUME_TOKEN) && !logs.includes(HOST_TOKEN), "ログに token が出ている");
  } finally {
    client.dispose();
  }
});

test("作成後の再接続は作った部屋への resume になり、部屋を作り直さない", () => {
  const client = startClient();
  try {
    const socket = created(client);
    socket.handlers.close?.();
    client.runTimers();
    const next = client.latestSocket();
    next.handlers.open?.();
    const first = JSON.parse(next.sent[0]);
    assert.equal(first.type, "resume");
    assert.equal(first.room_id, CODE);
  } finally {
    client.dispose();
  }
});

test("作成の応答前に接続が切れたら送り直さず、もう一度作れるようにする", () => {
  const client = startClient();
  try {
    client.submitCreate("Host");
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.close?.();
    assert.equal(client.pendingTimers(), 0, "作成を自動で送り直そうとしている");
    assert.match(client.textOf("status"), /部屋を作れませんでした/);
    assert.equal(client.isDisabled("create"), false);
    assert.equal(client.sockets.length, 1);
  } finally {
    client.dispose();
  }
});

test("作成ボタンを続けて押しても接続は1つだけ", () => {
  const client = startClient();
  try {
    client.submitCreate("Host");
    client.submitCreate("Host");
    assert.equal(client.sockets.length, 1);
  } finally {
    client.dispose();
  }
});

test("招待 URL から開くと部屋コードは入力済みで、名前だけで参加できる", () => {
  const client = startClient({ pathname: "/r/k7m2qx" });
  try {
    assert.equal(client.node("room-id").value, CODE);
    assert.equal(client.node("room-label").hidden, true);
    assert.equal(client.node("create-form").hidden, true);
    assert.match(client.textOf("join-heading"), new RegExp(CODE));
    assert.equal(client.sockets.length, 0, "名前を入れる前に接続した");

    client.submitJoin(client.node("room-id").value, "Guest");
    const socket = client.latestSocket();
    socket.handlers.open?.();
    const join = lastSent(socket, "join");
    assert.equal(join.room_id, CODE);
    // 招待から入った参加者に司会 token は届かない（保存もしない）。
    send(socket, { ...buzzerState({ selfId: "guest" }), resume_token: RESUME_TOKEN });
    assert.equal(saved(client).host_token, undefined);
    assert.equal(client.node("invite").hidden, false, "参加者も招待を配れる");
  } finally {
    client.dispose();
  }
});

test("別の部屋の招待を開いたときは、保存した参加に自動で戻らない", () => {
  const storage = {
    [RESUME_KEY]: JSON.stringify({
      room_id: "OTHER2",
      display_name: "N",
      room_instance_id: INSTANCE,
      resume_token: RESUME_TOKEN,
    }),
  };
  const client = startClient({ pathname: `/r/${CODE}`, storage });
  try {
    assert.equal(client.sockets.length, 0);
    assert.equal(client.node("room-id").value, CODE);
  } finally {
    client.dispose();
  }
});

test("同じ部屋の招待なら保存した参加に自動で戻る", () => {
  const storage = {
    [RESUME_KEY]: JSON.stringify({
      room_id: CODE,
      display_name: "N",
      room_instance_id: INSTANCE,
      resume_token: RESUME_TOKEN,
    }),
  };
  const client = startClient({ pathname: `/r/${CODE}`, storage });
  try {
    assert.equal(client.sockets.length, 1);
    const socket = client.latestSocket();
    socket.handlers.open?.();
    assert.equal(JSON.parse(socket.sent[0]).type, "resume");
  } finally {
    client.dispose();
  }
});

test("room_not_found は理由を出し、再接続せず、部屋を作る導線を出す", () => {
  const client = startClient({ pathname: `/r/${CODE}` });
  try {
    client.submitJoin(CODE, "Guest");
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, { type: "error", code: "room_not_found", message: "x" });
    assert.match(client.textOf("status"), /この部屋は見つかりません/);
    assert.equal(client.pendingTimers(), 0);
    assert.equal(client.node("create-form").hidden, false);
  } finally {
    client.dispose();
  }
});

for (const [code, pattern] of [
  ["room_full", /満員/],
  ["room_unavailable", /混み合って/],
  ["invalid_display_name", /名前は1〜64文字/],
]) {
  test(`${code} の理由を画面に出す（ログを見なくても分かる）`, () => {
    const client = startClient();
    try {
      client.submitJoin(CODE, "Guest");
      const socket = client.latestSocket();
      socket.handlers.open?.();
      send(socket, { type: "error", code, message: "x" });
      assert.equal(client.connectionState(), "disconnected");
      assert.match(client.textOf("status"), pattern);
    } finally {
      client.dispose();
    }
  });
}

test("招待 URL をコピーできたら結果を出す", async () => {
  const copied = [];
  const client = startClient({
    clipboard: {
      writeText: async (text) => {
        copied.push(text);
      },
    },
  });
  try {
    created(client);
    client.click("copy-invite");
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(copied, [`http://127.0.0.1:4000/r/${CODE}`]);
    assert.equal(client.textOf("copy-result"), "招待URLをコピーしました");
  } finally {
    client.dispose();
  }
});

test("コピーできない環境では URL を選択して手でコピーするよう案内する", () => {
  const client = startClient();
  try {
    created(client);
    client.click("copy-invite");
    assert.equal(client.node("invite-url").selected, true);
    assert.match(client.textOf("copy-result"), /コピーできませんでした/);
  } finally {
    client.dispose();
  }
});

test("コピー API が使えない http でも、選択してのコピーでコピーできる", () => {
  const commands = [];
  const client = startClient({
    execCommand: (command) => {
      commands.push(command);
      return true;
    },
  });
  try {
    created(client);
    client.click("copy-invite");
    assert.deepEqual(commands, ["copy"]);
    assert.equal(client.node("invite-url").selected, true);
    assert.equal(client.textOf("copy-result"), "招待URLをコピーしました");
  } finally {
    client.dispose();
  }
});

test("末尾に / が付いた招待 URL も同じ部屋の招待として扱う", () => {
  const client = startClient({ pathname: `/r/${CODE}/` });
  try {
    assert.equal(client.node("room-id").value, CODE);
    assert.equal(client.node("room-label").hidden, true);
  } finally {
    client.dispose();
  }
});

test("サーバが受け付けない長さの部屋コードは招待として扱わない", () => {
  const client = startClient({ pathname: `/r/${"A".repeat(65)}` });
  try {
    assert.notEqual(client.node("room-label").hidden, true, "部屋コード欄が隠れたまま");
    assert.notEqual(client.node("create-form").hidden, true, "作成フォームが隠れたまま");
  } finally {
    client.dispose();
  }
});

test("前回の部屋が終了していたら、新しく作る導線を出す", () => {
  const storage = {
    [RESUME_KEY]: JSON.stringify({
      room_id: CODE,
      display_name: "N",
      room_instance_id: INSTANCE,
      resume_token: RESUME_TOKEN,
    }),
  };
  const client = startClient({ pathname: `/r/${CODE}`, storage });
  try {
    const socket = client.latestSocket();
    socket.handlers.open?.();
    send(socket, { type: "error", code: "room_gone", message: "x" });
    assert.match(client.textOf("status"), /前回の部屋は終了しています/);
    assert.equal(client.node("create-form").hidden, false);
  } finally {
    client.dispose();
  }
});

test("URL が長すぎて QR に収まらないときは、QR と読み取り案内を出さない", () => {
  // 型番10-M の上限（213バイト）を超えるホスト名。
  const host = `${"a".repeat(220)}.example`;
  const client = startClient({ host });
  try {
    created(client);
    assert.equal(client.node("invite-url").value, `http://${host}/r/${CODE}`);
    assert.equal(client.node("invite-qr").hidden, true);
    assert.equal(client.node("invite-qr").children.length, 0);
    assert.doesNotMatch(client.textOf("invite-qr-hint"), /QR/);
  } finally {
    client.dispose();
  }
});

test("QR に収まる URL では QR と読み取り案内を出す", () => {
  const client = startClient();
  try {
    created(client);
    assert.equal(client.node("invite-qr").hidden, false);
    assert.match(client.textOf("invite-qr-hint"), /QR/);
  } finally {
    client.dispose();
  }
});

test("退出すると招待を隠す", () => {
  const client = startClient();
  try {
    created(client);
    client.click("leave");
    assert.equal(client.node("invite").hidden, true);
    assert.equal(saved(client), null);
  } finally {
    client.dispose();
  }
});
