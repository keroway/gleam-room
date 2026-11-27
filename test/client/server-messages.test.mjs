// handleServerMessage（web.gleam）が participant_joined / participant_left /
// buzz_accepted / round_reset / error の各分岐を正しく処理することの回帰テスト（#187）。
//
// log() 呼び出しの内容に加えて、childTextContents() で participants/buzzes 要素
// への描画結果も検証する（#389: harness.mjs の replaceChildren スタブが no-op
// だった間は描画内容を一切検証できていなかった）。フィールド参照を取り違えても
// （例: message.participant.participant_id と message.participant_id の混同）ログの内容や
// ハンドラの例外、DOM への描画内容で検知できる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";
import { buzzerState, INSTANCE } from "./buzzer-wire.mjs";

// 状態を変える通知の位置（#765）。join 時の state は revision 1。
const at = (revision) => ({ room_instance_id: INSTANCE, revision });

function joinAndConnect(client, participants = []) {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  socket.handlers.message?.({
    data: JSON.stringify(buzzerState({ participants })),
  });
  return socket;
}

test("state の participants/buzzes に不正な要素があると、connected にならず部分適用しない（#647）", () => {
  for (const body of [
    buzzerState({ participants: [null] }),
    buzzerState({ buzzes: [{ position: "1", display_name: "A" }] }),
  ]) {
    const client = startClient();
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      socket.handlers.message?.({ data: JSON.stringify(body) });

      assert.notEqual(client.connectionState(), "connected");
      assert.ok(
        client.logs.some((line) => line.includes("state message missing expected fields")),
      );
    } finally {
      client.dispose();
    }
  }
});

test("participant_joined は participants に追加されログに残る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "participant_joined",
        ...at(2),
        participant: { participant_id: "p1", display_name: "Alice" },
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

test("participant_joined メッセージが妥当なJSONだが participant フィールド欠落だと、participants を更新せず部分適用状態にならない（#527）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_joined" }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("participant_joined message missing expected fields")),
      "形状不正を示すログが残っていない",
    );
    assert.deepEqual(
      client.childTextContents("participants"),
      [],
      "participant フィールド欠落なのに participants に描画されている",
    );
  } finally {
    client.dispose();
  }
});

test("participant_joined の display_name が欠落・null・数値だと、participants に追加せず警告を残す（#754）", () => {
  for (const displayName of [undefined, null, 5]) {
    const client = startClient();
    try {
      const socket = joinAndConnect(client);
      socket.handlers.message?.({
        data: JSON.stringify({
          type: "participant_joined",
          ...at(2),
          participant: { participant_id: "p2", display_name: displayName },
        }),
      });

      assert.ok(
        client.logs.some((line) => line.includes("participant_joined message missing expected fields")),
        "形状不正を示すログが残っていない",
      );
      assert.deepEqual(client.childTextContents("participants"), []);
    } finally {
      client.dispose();
    }
  }
});

test("participant_left メッセージが妥当なJSONだが participant_id フィールド欠落だと、participants から誤って削除しない（#527）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_left", ...at(2) }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("participant_left message missing expected fields")),
      "形状不正を示すログが残っていない",
    );
    assert.deepEqual(
      client.childTextContents("participants"),
      ["Alice"],
      "participant_id フィールド欠落なのに participants から削除されている",
    );
  } finally {
    client.dispose();
  }
});

test("participant_left はログに残る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_left", ...at(2), participant_id: "p1" }),
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

test("buzz_accepted はログに残り、同じ revision の再配信は無視される（#43, #765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
    const buzz = {
      type: "buzz_accepted",
      ...at(2),
      round_id: 1,
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

test("buzz_accepted メッセージが妥当なJSONだが position/participant_id/display_name のいずれか欠落だと、buzzes を更新せず部分適用状態にならない（#609）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "buzz_accepted",
        ...at(2),
        round_id: 1,
        participant_id: "p1",
        display_name: "Alice",
        // position 欠落
      }),
    });

    assert.ok(
      client.logs.some((line) => line.includes("buzz_accepted message missing expected fields")),
      "形状不正を示すログが残っていない",
    );
    assert.deepEqual(
      client.childTextContents("buzzes"),
      [],
      "position フィールド欠落なのに buzzes に描画されている",
    );
  } finally {
    client.dispose();
  }
});

test("round_reset はログに残る", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "buzz_accepted",
        ...at(2),
        round_id: 1,
        participant_id: "p1",
        display_name: "Alice",
        position: 1,
      }),
    });
    socket.handlers.message?.({ data: JSON.stringify({ type: "round_reset", ...at(3), round_id: 2 }) });

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

test("同じ revision の round_reset が直接応答と配信で2回届いても1回だけ適用する（#526, #765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "buzz_accepted",
        ...at(2),
        round_id: 1,
        participant_id: "p1",
        display_name: "Alice",
        position: 1,
      }),
    });
    socket.handlers.message?.({ data: JSON.stringify({ type: "round_reset", ...at(3), round_id: 2 }) });
    socket.handlers.message?.({ data: JSON.stringify({ type: "round_reset", ...at(3), round_id: 2 }) });

    const resetLogs = client.logs.filter((line) => line.includes("round reset"));
    assert.equal(resetLogs.length, 1, "自己エコーによる round_reset が二重にログされている");
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
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
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
      data: JSON.stringify({ type: "participant_left", ...at(2), participant_id: "p1" }),
    });
    assert.ok(
      client.logs.some((line) => line.includes("left: p1")),
      "壊れた JSON の後で participants 状態が失われている",
    );
  } finally {
    client.dispose();
  }
});

test("handleServerMessage内で例外が発生すると、握り潰さずerrの内容をログに残す（#552）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);

    // 各 case はフィールド形状ガード済み（#527）のため、実際に例外を起こす
    // には switch(message.type) 自体が失敗する必要がある。"null" は妥当な
    // JSON だが message が null になり、.type 参照で TypeError を投げる。
    socket.handlers.message?.({
      data: "null",
    });

    const failureLog = client.logs.find((line) =>
      line.includes("failed to handle server message"),
    );
    assert.ok(failureLog, "ハンドリング失敗ログが残っていない");
    assert.ok(
      /Cannot read propert/.test(failureLog),
      `err の内容がログに含まれていない: ${failureLog}`,
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
      data: JSON.stringify({ ...buzzerState(), participants: undefined }),
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
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);
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

// room_busy（#570）は buzz/reset タイムアウト由来で、サーバは接続を閉じずに
// 保持する。上の恒久拒否コードと違い、クライアントは close イベントを待たず
// 即座に "未接続" 扱いにはしない — 自動再接続のために close イベントの
// scheduleReconnect() を通す必要があるため（詳細な再接続の検証は
// reconnect.test.mjs 側）。
test("room_busy エラーは即座に接続状態をリセットしない（close イベントを待つ）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "room_busy", message: "busy" }),
    });

    assert.equal(
      client.connectionState(),
      "connected",
      "room_busy 直後に接続状態がリセットされている（close イベントを待たずに切断扱いしている）",
    );
  } finally {
    client.dispose();
  }
});

// already_joined はこの接続が既にroomへ参加済みであることを示すだけで
// join失敗ではないため、room_full等の join拒否コードとは異なり接続状態・
// UIを一切変更しない意図的な設計（#553）。
test("already_joined エラーはログに残るが接続状態・participants描画を変えない", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client, [{ participant_id: "p1", display_name: "Alice" }]);

    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "already_joined", message: "already joined" }),
    });

    assert.equal(client.connectionState(), "connected");
    assert.deepEqual(
      client.childTextContents("participants"),
      ["Alice"],
      "already_joined で既存の participants 描画が壊れている",
    );
  } finally {
    client.dispose();
  }
});

test("revision に欠番があれば適用せず sync を1回だけ要求し、届いた state で追いつく（#765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    const joined = (revision, id) => ({
      data: JSON.stringify({
        type: "participant_joined",
        ...at(revision),
        participant: { participant_id: id, display_name: id },
      }),
    });
    socket.handlers.message?.(joined(3, "late"));
    socket.handlers.message?.(joined(4, "later"));
    assert.deepEqual(client.childTextContents("participants"), []);
    const syncs = socket.sent.map((d) => JSON.parse(d)).filter((m) => m.type === "sync");
    assert.equal(syncs.length, 1, "欠番ごとに sync を重ねて要求している");

    socket.handlers.message?.({
      data: JSON.stringify(buzzerState({
        revision: 4,
        participants: [
          { participant_id: "x", display_name: "x" },
          { participant_id: "late", display_name: "late" },
          { participant_id: "later", display_name: "later" },
        ],
      })),
    });
    socket.handlers.message?.(joined(4, "later"));
    assert.deepEqual(client.childTextContents("participants"), ["x", "late", "later"]);
    socket.handlers.message?.(joined(5, "next"));
    assert.deepEqual(client.childTextContents("participants"), ["x", "late", "later", "next"]);
  } finally {
    client.dispose();
  }
});

test("別の部屋世代（同じ部屋コードの作り直し前）の通知は適用しない（#765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "participant_joined",
        room_instance_id: "older-room",
        revision: 2,
        participant: { participant_id: "ghost", display_name: "Ghost" },
      }),
    });
    assert.deepEqual(client.childTextContents("participants"), []);
  } finally {
    client.dispose();
  }
});

test("revision の無い旧形式の通知は適用せず警告を残す（#765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "participant_joined",
        participant: { participant_id: "p2", display_name: "Bob" },
      }),
    });
    assert.deepEqual(client.childTextContents("participants"), []);
    assert.ok(client.logs.some((line) => line.includes("participant_joined message missing expected fields")));
  } finally {
    client.dispose();
  }
});

for (const [name, deliver] of [
  ["state の protocol_version が違う", (socket) =>
    socket.handlers.message?.({ data: JSON.stringify(buzzerState({ protocolVersion: 3 })) })],
  ["client_outdated エラー", (socket) =>
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "client_outdated", message: "reload" }),
    })],
]) {
  test(`${name}ときは再読み込みを促し、自動再接続しない（#765）`, () => {
    const client = startClient();
    try {
      client.submitJoin();
      const socket = client.latestSocket();
      socket.handlers.open?.();
      deliver(socket);
      socket.handlers.close?.();

      assert.equal(client.connectionState(), "outdated");
      assert.ok(client.isDisabled("join"));
      assert.ok(client.logs.some((line) => line.includes("ページを再読み込みしてください")));
      assert.equal(client.runTimers(), 0, "再接続を予約している");
    } finally {
      client.dispose();
    }
  });
}

// sync 自体がレート制限で拒否されても取り直せる（#765 レビュー指摘）。
// 拒否のまま待機し続けると、以後の欠番でも sync を送れず古い表示が残る。
test("sync が rate_limited で拒否されたら間隔を広げて取り直し、上限で止める（#765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    const syncs = () => socket.sent.map((d) => JSON.parse(d)).filter((m) => m.type === "sync");
    const reject = (requestId) =>
      socket.handlers.message?.({
        data: JSON.stringify({
          type: "reply",
          request_id: requestId,
          result: { type: "error", code: "rate_limited", message: "slow down" },
        }),
      });
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "participant_left",
        ...at(3),
        participant_id: "gone",
      }),
    });
    assert.equal(syncs().length, 1);
    assert.equal(typeof syncs()[0].request_id, "string", "sync に request_id が無い");

    // 拒否ごとに1回だけ遅延再送し、上限（3回）を超えたら止める。最後の
    // 再試行はレート制限の窓（30秒）が回復した後になる。
    const delays = [2000, 8000, 32000];
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      reject(syncs().at(-1).request_id);
      assert.deepEqual(client.timerDelays(), [delays[attempt - 1]],
        `${attempt}回目の拒否で再試行を予約していない`);
      if (attempt === 1) {
        // 予約中の欠番では sync を重ねない（タイマーが上書きされて取り消せなくなる）。
        socket.handlers.message?.({
          data: JSON.stringify({ type: "participant_left", ...at(4), participant_id: "gone" }),
        });
        assert.equal(syncs().length, 1, "再試行の予約中に sync を重ねて送った");
      }
      client.runTimers();
      assert.equal(syncs().length, attempt + 1);
    }
    reject(syncs().at(-1).request_id);
    assert.equal(client.pendingTimers(), 0, "上限を超えても再試行を続けている");

    // 待機は解けているので、次の欠番では再び sync を送れる。
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_left", ...at(6), participant_id: "gone" }),
    });
    assert.equal(syncs().length, 5, "拒否後の欠番で sync を送れない");
  } finally {
    client.dispose();
  }
});

test("sync の再試行待ちは切断で取り消す（#765）", () => {
  const client = startClient();
  try {
    const socket = joinAndConnect(client);
    socket.handlers.message?.({
      data: JSON.stringify({ type: "participant_left", ...at(3), participant_id: "gone" }),
    });
    const sync = socket.sent.map((d) => JSON.parse(d)).find((m) => m.type === "sync");
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "reply",
        request_id: sync.request_id,
        result: { type: "error", code: "rate_limited", message: "slow down" },
      }),
    });
    assert.deepEqual(client.timerDelays(), [2000]);
    socket.handlers.close?.();
    assert.ok(!client.timerDelays().includes(2000), "切断後も sync の再試行が残っている");
  } finally {
    client.dispose();
  }
});
