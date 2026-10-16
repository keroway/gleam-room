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
