// updateCardButtons()（web_poker.gleam）が投票カードボタンの disabled と
// aria-pressed を正しく切り替えることの回帰テスト（#388）。
//
// 受け入れ基準（web_poker.gleam のコメントより）: 投票ボタンは接続中かつ
// reveal 前だけ押せる。reveal 前なら自分の投票は何度でも上書きできるため、
// 選択済みでも無効化はしない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const POKER_MODULE = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };
const CARD_IDS = [
  "card-0",
  "card-1",
  "card-2",
  "card-3",
  "card-5",
  "card-8",
  "card-13",
  "card-21",
  "card-question",
  "card-coffee",
];

function joinAndConnect(client, participants = [], phase = "voting") {
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open?.();
  socket.handlers.message?.({
    data: JSON.stringify({ type: "state", phase, participants }),
  });
  return socket;
}

test("join 直後（state 受信後）はカードが有効で、aria-pressed は全カード false", () => {
  const client = startClient(POKER_MODULE);
  try {
    joinAndConnect(client);

    for (const id of CARD_IDS) {
      assert.equal(client.isDisabled(id), false, `${id} が無効化されている`);
      assert.equal(client.getAttribute(id, "aria-pressed"), "false", `${id} の aria-pressed が false でない`);
    }
  } finally {
    client.dispose();
  }
});

test("投票済みでも reveal 前ならカードは有効なまま、選択したカードだけ aria-pressed=true になる（受け入れ基準）", () => {
  const client = startClient(POKER_MODULE);
  try {
    joinAndConnect(client);

    client.click("card-5");

    assert.equal(client.isDisabled("card-5"), false, "投票済みカードが無効化されている");
    assert.equal(client.getAttribute("card-5", "aria-pressed"), "true", "選択したカードに aria-pressed=true が付いていない");
    assert.equal(client.getAttribute("card-1", "aria-pressed"), "false", "未選択カードの aria-pressed が false でない");

    // reveal 前は選択のやり直しができる（コメントの受け入れ基準そのもの）。
    client.click("card-8");
    assert.equal(client.getAttribute("card-5", "aria-pressed"), "false", "選び直した後も旧選択に aria-pressed=true が残っている");
    assert.equal(client.getAttribute("card-8", "aria-pressed"), "true", "選び直した新選択に aria-pressed=true が付いていない");
    assert.equal(client.isDisabled("card-8"), false, "選び直した後にカードが無効化されている");
  } finally {
    client.dispose();
  }
});

test("revealed になると全カードが無効化される", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client);
    client.click("card-5");

    socket.handlers.message?.({
      data: JSON.stringify({
        type: "revealed",
        votes: [{ participant_id: "p1", display_name: "Alice", value: "5" }],
      }),
    });

    for (const id of CARD_IDS) {
      assert.equal(client.isDisabled(id), true, `revealed 後も ${id} が有効なまま`);
    }
  } finally {
    client.dispose();
  }
});

test("round_reset で再びカードが有効になり、aria-pressed もリセットされる", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client);
    client.click("card-5");
    socket.handlers.message?.({
      data: JSON.stringify({
        type: "revealed",
        votes: [{ participant_id: "p1", display_name: "Alice", value: "5" }],
      }),
    });

    socket.handlers.message?.({ data: JSON.stringify({ type: "round_reset" }) });

    for (const id of CARD_IDS) {
      assert.equal(client.isDisabled(id), false, `round_reset 後も ${id} が無効なまま`);
      assert.equal(client.getAttribute(id, "aria-pressed"), "false", `round_reset 後も ${id} の aria-pressed が true のまま`);
    }
  } finally {
    client.dispose();
  }
});

for (const code of ["round_already_revealed", "voter_not_joined", "invalid_card"]) {
  test(`vote が ${code} で拒否されると ownVote がロールバックされる（#422, #486）`, () => {
    const client = startClient(POKER_MODULE);
    try {
      const socket = joinAndConnect(client);
      client.click("card-5");
      assert.equal(client.getAttribute("card-5", "aria-pressed"), "true", "楽観的反映で aria-pressed=true になっていない");

      socket.handlers.message?.({
        data: JSON.stringify({ type: "error", code, message: "rejected" }),
      });

      assert.equal(client.getAttribute("card-5", "aria-pressed"), "false", "拒否後も ownVote のカードに aria-pressed=true が残っている");
      for (const id of CARD_IDS) {
        assert.equal(client.getAttribute(id, "aria-pressed"), "false", `拒否後も ${id} の aria-pressed が true のまま`);
      }
    } finally {
      client.dispose();
    }
  });
}

test("vote 直後の rate_limited で拒否されると ownVote がロールバックされる（#469）", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client);
    client.click("card-5");
    assert.equal(client.getAttribute("card-5", "aria-pressed"), "true", "楽観的反映で aria-pressed=true になっていない");

    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "rate_limited", message: "rejected" }),
    });

    assert.equal(client.getAttribute("card-5", "aria-pressed"), "false", "rate_limited 後も ownVote のカードに aria-pressed=true が残っている");
  } finally {
    client.dispose();
  }
});

test("vote 以外の直後の rate_limited では ownVote をロールバックしない（#469）", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client);
    client.click("card-5");
    assert.equal(client.getAttribute("card-5", "aria-pressed"), "true", "楽観的反映で aria-pressed=true になっていない");

    client.click("reveal");
    socket.handlers.message?.({
      data: JSON.stringify({ type: "error", code: "rate_limited", message: "rejected" }),
    });

    assert.equal(client.getAttribute("card-5", "aria-pressed"), "true", "reveal の rate_limited で無関係な vote までロールバックされた");
  } finally {
    client.dispose();
  }
});

test("切断されると全カードが無効化される", () => {
  const client = startClient(POKER_MODULE);
  try {
    const socket = joinAndConnect(client);

    socket.handlers.close?.();

    for (const id of CARD_IDS) {
      assert.equal(client.isDisabled(id), true, `切断後も ${id} が有効なまま`);
    }
  } finally {
    client.dispose();
  }
});
