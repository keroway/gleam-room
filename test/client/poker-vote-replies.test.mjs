import { test } from "node:test";
import assert from "node:assert/strict";
import { startClient } from "./harness.mjs";

const module = { modulePath: "src/gleamroom/web_poker.gleam", functionName: "poker_html" };
function setup() {
  const client = startClient(module);
  client.submitJoin();
  const socket = client.latestSocket();
  socket.handlers.open();
  const receive = (message) => socket.handlers.message({ data: JSON.stringify(message) });
  receive({ type: "state", phase: "voting", participants: [
    { participant_id: "p1", display_name: "Alice", has_voted: false },
    { participant_id: "p2", display_name: "Bob", has_voted: false },
  ], votes: [] });
  const vote = (value) => {
    client.click(`card-${value}`);
    return JSON.parse(socket.sent.at(-1)).request_id;
  };
  const reply = (request_id, accepted = true) => receive({ type: "vote_reply", request_id,
    result: accepted ? { type: "vote_registered", participant_id: "p1" }
      : { type: "error", code: "rate_limited", message: "rejected" },
  });
  return { client, receive, vote, reply, socket };
}
function selected(client, value) {
  for (const card of ["5", "8", "13"]) {
    assert.equal(client.getAttribute(`card-${card}`, "aria-pressed"), String(card === value));
  }
}

test("#663: rejection identifies the first 8, not the later accepted 8", () => {
  const { client, receive, vote, reply } = setup();
  try {
    reply(vote("5"));
    const first = vote("8");
    const middle = vote("13");
    const last = vote("8");
    assert.notEqual(first, last);
    receive({ type: "vote_registered", participant_id: "p2" });
    receive({ type: "vote_registered", participant_id: "p1" });
    reply(first, false);
    reply(middle);
    reply(last);
    reply(middle); // duplicate direct reply cannot overwrite the latest vote
    receive({ type: "revealed", votes: [
      { participant_id: "p1", display_name: "Alice", value: "8" },
    ] });
    selected(client, "8");
    assert.deepEqual(client.childTextContents("votes"), ["Alice: 8"]);
  } finally { client.dispose(); }
});

test("#659/#661: rejected reselection preserves the last accepted card", () => {
  const { client, vote, reply } = setup();
  try {
    reply(vote("5"));
    reply(vote("8"));
    reply(vote("5"), false);
    selected(client, "8");
    const rejected = vote("13");
    const accepted = vote("8");
    reply(accepted);
    reply(rejected, false); // delayed rejection cannot undo a newer acceptance
    selected(client, "8");
  } finally { client.dispose(); }
});

test("33 identical rejected votes restore the confirmed value without history guessing", () => {
  const { client, vote, reply } = setup();
  try {
    reply(vote("5"));
    const ids = Array.from({ length: 33 }, () => vote("8"));
    for (const id of ids) reply(id, false);
    selected(client, "5");
  } finally { client.dispose(); }
});

test("vote rejection is correlated even after sending reveal; stale replies after reset are ignored", () => {
  const { client, vote, reply, receive } = setup();
  try {
    reply(vote("5"));
    const rejected = vote("8");
    client.click("reveal");
    reply(rejected, false);
    selected(client, "5");
    const stale = vote("13");
    receive({ type: "round_reset" });
    reply(stale);
    selected(client, null);
    reply(vote("8"));
    selected(client, "8");
  } finally { client.dispose(); }
});

test("reset clears unacknowledged first vote even before has_voted becomes true", () => {
  const { client, vote, reply, receive } = setup();
  try {
    const stale = vote("8");
    receive({ type: "round_reset" });
    reply(stale);
    selected(client, null);
    reply(vote("13"));
    selected(client, "13");
  } finally { client.dispose(); }
});

test("unknown replies do not settle votes and pending memory is bounded", () => {
  const { client, vote, reply, socket } = setup();
  try {
    reply(vote("5")); // 相関応答を受けた状態（新サーバー）にする
    const first = vote("5");
    reply("unknown");
    for (let i = 1; i < 64; i++) vote("8");
    const before = socket.sent.length;
    vote("13");
    assert.equal(socket.sent.length, before);
    reply(first);
    vote("13");
    assert.equal(socket.sent.length, before + 1);
    selected(client, "13");
  } finally { client.dispose(); }
});

test("#673: legacy vote_registered replies never stall card clicks after 64 votes", () => {
  const { client, receive, socket } = setup();
  try {
    for (let i = 0; i < 70; i++) {
      client.click("card-5");
      receive({ type: "vote_registered", participant_id: "p1" });
    }
    const before = socket.sent.length;
    client.click("card-8");
    assert.equal(socket.sent.length, before + 1);
    selected(client, "8");
  } finally { client.dispose(); }
});

test("#675: room_busy for a vote discarded at the pending cap still closes the socket", () => {
  const { client, receive, vote, socket } = setup();
  try {
    const first = vote("5");
    for (let i = 0; i < 64; i++) vote("8");
    receive({ type: "vote_reply", request_id: first,
      result: { type: "error", code: "room_busy", message: "timed out" } });
    assert.equal(socket.readyState, socket.constructor.CLOSED);
  } finally { client.dispose(); }
});

test("#675: room_busy for a vote cleared by reset is still ignored", () => {
  const { client, receive, vote, socket } = setup();
  try {
    const first = vote("5");
    for (let i = 0; i < 64; i++) vote("8");
    receive({ type: "round_reset" });
    receive({ type: "vote_reply", request_id: first,
      result: { type: "error", code: "room_busy", message: "timed out" } });
    assert.notEqual(socket.readyState, socket.constructor.CLOSED);
  } finally { client.dispose(); }
});

test("#695: a vote echo arriving after reset does not restore the voted mark", () => {
  const { client, vote, reply, receive, socket } = setup();
  try {
    reply(vote("8"));
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "vote_registered", participant_id: "p1" });
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("participants"), ["Alice", "Bob"]);
    // a legitimate vote in the new round still marks the participant
    reply(vote("5"));
    assert.deepEqual(client.childTextContents("participants"), ["Alice ✓", "Bob"]);
  } finally { client.dispose(); }
});

test("#732: two success replies before their echoes do not let a late echo restore the voted mark after reset", () => {
  const { client, vote, reply, receive, socket } = setup();
  try {
    const first = vote("5");
    const second = vote("8");
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    reply(first);
    reply(second);
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "vote_registered", participant_id: "p1" });
    receive({ type: "vote_registered", participant_id: "p1" });
    assert.deepEqual(client.childTextContents("participants"), ["Alice", "Bob"]);
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("participants"), ["Alice", "Bob"]);
    // a legitimate vote in the new round still marks the participant
    reply(vote("5"));
    assert.deepEqual(client.childTextContents("participants"), ["Alice ✓", "Bob"]);
  } finally { client.dispose(); }
});

test("#692: a stale revealed echo after reset does not restore the old result", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "8" }] };
    client.click("reveal");
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive(revealed);
    receive({ type: "round_reset" });
    assert.equal(client.isDisabled("card-8"), false);
    assert.deepEqual(client.childTextContents("votes"), []);
    assert.deepEqual(client.childTextContents("participants"), ["Alice", "Bob"]);
    // a genuine reveal in the new round (different content) still applies
    receive({ type: "revealed", votes: [{ participant_id: "p2", display_name: "Bob", value: "5" }] });
    assert.ok(client.childTextContents("votes").some((t) => t.includes("5")));
  } finally { client.dispose(); }
});

test("#734: two accepted Reveals before Reset leave two stale echoes that do not restore the old result", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "8" }] };
    client.click("reveal");
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive(revealed);
    receive(revealed);
    receive({ type: "round_reset" });
    assert.equal(client.isDisabled("card-8"), false);
    assert.deepEqual(client.childTextContents("votes"), []);
    // all stale echoes consumed: a genuine identical Reveal now applies
    receive(revealed);
    assert.ok(client.childTextContents("votes").some((t) => t.includes("8")));
  } finally { client.dispose(); }
});

test("#738: one accepted and one rate-limited Reveal before Reset leave two stale echoes that do not restore the old result", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    client.click("reveal");
    receive(revealed);
    receive({ type: "error", code: "rate_limited", message: "slow down" });
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "round_reset" });
    assert.equal(client.isDisabled("card-8"), false);
    assert.deepEqual(client.childTextContents("votes"), []);
    // the next round's identical Reveal now applies
    receive(revealed);
    assert.equal(client.isDisabled("card-8"), true);
    assert.equal(client.childTextContents("votes").length, 1);
  } finally { client.dispose(); }
});

test("#740: a stale Reveal echo after a new-round vote does not restore the old result", () => {
  const { client, receive, reply, vote, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    client.click("reset");
    receive(revealed);
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    const voteId = vote("8");
    assert.equal(client.isDisabled("card-8"), false);
    receive(revealed);
    receive({ type: "round_reset" });
    reply(voteId);
    receive({ type: "vote_registered", participant_id: "p1" });
    assert.equal(client.isDisabled("card-8"), false);
    assert.deepEqual(client.childTextContents("votes"), []);
  } finally { client.dispose(); }
});

test("#742: a stale Reveal echo with valued votes after a new-round vote does not restore the old result", () => {
  const { client, receive, vote, reply, socket } = setup();
  try {
    const first = vote("5");
    reply(first);
    receive({ type: "vote_registered", participant_id: "p1" });
    client.click("reveal");
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "5" }] };
    receive(revealed);
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    const voteId = vote("8");
    receive(revealed);
    receive({ type: "round_reset" });
    reply(voteId);
    receive({ type: "vote_registered", participant_id: "p1" });
    assert.equal(client.isDisabled("card-8"), false);
    assert.deepEqual(client.childTextContents("votes"), []);
  } finally { client.dispose(); }
});

test("#752: a Reveal resent right after Reset keeps dropping stale echoes and a rejection does not restore the old result", () => {
  const { client, receive, vote, reply, socket } = setup();
  try {
    const first = vote("8");
    reply(first);
    receive({ type: "vote_registered", participant_id: "p1" });
    client.click("reveal");
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "8" }] };
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    client.click("reveal");
    receive(revealed);
    receive({ type: "round_reset" });
    receive({ type: "error", code: "rate_limited", message: "Too many messages. Please slow down." });
    assert.equal(client.isDisabled("card-8"), false);
    assert.deepEqual(client.childTextContents("votes"), []);
  } finally { client.dispose(); }
});

test("#756: a stale Reveal echo arriving after the next round's Reveal does not overwrite the latest result", () => {
  const { client, receive, reply, vote, socket } = setup();
  try {
    const first = vote("8");
    reply(first);
    receive({ type: "vote_registered", participant_id: "p1" });
    client.click("reveal");
    const old = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "8" }] };
    receive(old);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    const second = vote("13");
    reply(second);
    client.click("reveal");
    receive({ type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "13" }] });
    assert.deepEqual(client.childTextContents("votes"), ["Alice: 13"]);
    receive(old);
    assert.deepEqual(client.childTextContents("votes"), ["Alice: 13"]);
    assert.equal(client.getAttribute("card-13", "aria-pressed"), "true");
  } finally { client.dispose(); }
});

test("#760: stale echoes of two Reveals with different results are all dropped after Reset", () => {
  const { client, receive, vote, reply, socket } = setup();
  try {
    const first = vote("5");
    reply(first);
    receive({ type: "vote_registered", participant_id: "p1" });
    const a = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "5" }, { participant_id: "p2", display_name: "Bob", value: "8" }] };
    const b = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: "5" }] };
    client.click("reveal");
    receive(a);
    client.click("reveal");
    receive(b);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    assert.deepEqual(client.childTextContents("votes"), []);
    receive(a);
    receive({ type: "participant_left", participant_id: "p2" });
    receive(b);
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("votes"), []);
    assert.equal(client.isDisabled("card-5"), false);
  } finally { client.dispose(); }
});

test("#738: a rate-limited Reveal arriving after both echoes of the accepted one is still counted", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    receive({ type: "error", code: "rate_limited", message: "slow down" });
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("votes"), []);
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 1);
  } finally { client.dispose(); }
});

test("#720: after the stale reveal echo is dropped, another participant's identical Reveal still shows", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive(revealed); // late echo of the old reveal: dropped
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("votes"), []);
    receive(revealed); // Bob reveals the next round
    assert.equal(client.childTextContents("votes").length, 1);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#712: an unvoted Reveal-Reset-Reveal still shows the second round result", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("votes"), []);
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 1);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#716: another participant's unvoted Reveal after my Reveal-Reset still shows", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("votes"), []);
    // Bob reveals the next round; this client sends no reveal
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 1);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#718: a rejected Reveal resend does not make another participant's next Reveal a stale echo", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    client.click("reveal");
    receive({ type: "error", code: "rate_limited", message: "Too many messages. Please slow down." });
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "round_reset" });
    assert.deepEqual(client.childTextContents("votes"), []);
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 1);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#726: a Reveal rejection arriving after a Reset was sent is not counted as an unarrived echo", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [{ participant_id: "p1", display_name: "Alice", value: null }] };
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    client.click("reveal");
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    const limited = { type: "error", code: "rate_limited", message: "Too many messages. Please slow down." };
    receive(limited);
    receive({ type: "vote_reply", request_id: resetId, result: limited });
    receive({ type: "round_reset" });
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 1);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#728: a Reveal rejection arriving after a vote was sent is not counted as an unarrived echo", () => {
  const { client, receive, socket } = setup();
  try {
    const limited = { type: "error", code: "rate_limited", message: "slow down" };
    const revealed = { type: "revealed", votes: [
      { participant_id: "p1", display_name: "Alice", value: null },
      { participant_id: "p2", display_name: "Bob", value: null },
    ] };
    client.click("reveal");
    client.click("card-8");
    const voteId = JSON.parse(socket.sent.at(-1)).request_id;
    receive(limited);
    receive({ type: "vote_reply", request_id: voteId, result: limited });
    receive(revealed); // Bob reveals
    receive({ type: "round_reset" });
    receive(revealed); // Bob reveals the next round
    assert.equal(client.childTextContents("votes").length, 2);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#750: another participant's Reveal arriving before our Reveal rejection does not drop the next round's Reveal", () => {
  const { client, receive } = setup();
  try {
    const revealed = { type: "revealed", votes: [
      { participant_id: "p1", display_name: "Alice", value: null },
      { participant_id: "p2", display_name: "Bob", value: null },
    ] };
    client.click("reveal");
    receive(revealed); // Bob's reveal, not our reply
    receive({ type: "error", code: "rate_limited", message: "Too many messages. Please slow down." });
    receive({ type: "round_reset" });
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 2);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#730: two unanswered Reveal resends both rejected do not make the next Reveal a stale echo", () => {
  const { client, receive, socket } = setup();
  try {
    const revealed = { type: "revealed", votes: [
      { participant_id: "p1", display_name: "Alice", value: null },
      { participant_id: "p2", display_name: "Bob", value: null },
    ] };
    const limited = { type: "error", code: "rate_limited", message: "Too many messages" };
    client.click("reveal");
    receive(revealed);
    receive(revealed);
    client.click("reveal");
    client.click("reveal");
    receive(limited);
    receive(limited);
    client.click("reset");
    const resetId = JSON.parse(socket.sent.at(-1)).request_id;
    receive({ type: "vote_reply", request_id: resetId, result: { type: "round_reset" } });
    receive({ type: "round_reset" });
    receive(revealed);
    assert.equal(client.childTextContents("votes").length, 2);
    assert.equal(client.isDisabled("card-8"), true);
  } finally { client.dispose(); }
});

test("#693: a success reply for a vote evicted at the 65th vote keeps the selection", () => {
  const { client, receive, socket } = setup();
  try {
    for (let i = 0; i < 65; i++) client.click("card-8");
    const ids = socket.sent.map((m) => JSON.parse(m)).filter((m) => m.type === "vote").map((m) => m.request_id);
    receive({ type: "vote_reply", request_id: ids[0], result: { type: "vote_registered", participant_id: "p1" } });
    receive({ type: "vote_registered", participant_id: "p1" });
    for (const id of ids.slice(1)) {
      receive({ type: "vote_reply", request_id: id,
        result: { type: "error", code: "rate_limited", message: "Too many messages. Please slow down." } });
    }
    selected(client, "8");
    assert.deepEqual(client.childTextContents("participants"), ["Alice ✓", "Bob"]);
  } finally { client.dispose(); }
});
