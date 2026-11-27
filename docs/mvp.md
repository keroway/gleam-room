# Multiplayer Buzzer MVP

> **Scope note (2026-11, #763).** This document describes the MVP as built
> and still running. Its non-goals (no authorization, connection-scoped
> participants, anyone may reset) are the MVP's scope, not a permanent
> decision for the buzzer. The real-use buzzer contract that replaces parts
> of it is [ADR 0010](adr/0010-buzzer-session-model.md) /
> [`docs/buzzer-session.md`](buzzer-session.md); each part takes effect only
> when its implementing issue (#765〜#769) lands.

## Objective

Validate the end-to-end architecture for a real-time multi-user room on Gleam/BEAM.

The MVP is successful when multiple independent browser clients can join the same logical room, press a buzzer, and observe one server-authoritative ordering of presses.

## Primary user flow

1. A user opens the web client.
2. The user enters a room ID and display name.
3. The browser establishes a WebSocket connection.
4. The server joins the participant to the room.
5. Multiple participants can be present concurrently.
6. During an open round, each participant can press the buzzer once.
7. The room assigns buzzer positions in the order commands are accepted.
8. All connected participants receive the updated ordered result.
9. A reset command clears the current round and allows buzzing again.
10. Leaving/disconnecting updates room presence.

## Functional requirements

### Room join

- A room is identified by a compact `RoomId` supplied by the client for the MVP.
- Joining an unknown room may create it lazily.
- A participant supplies a display name.
- The server assigns or confirms a participant identifier suitable for the connection/session model.

### Presence

- The room tracks currently connected participants.
- Connected clients receive enough information to render current presence.
- A clean disconnect removes the participant.
- Abrupt disconnect behavior should be handled at least at WebSocket lifecycle level.

### Buzzer round

- A participant can have at most one accepted buzz per round.
- The room actor determines accepted order.
- Duplicate buzzes from the same participant during the same round are ignored or rejected explicitly.
- All clients receive the same ordered result.
- Client-provided timestamps do not determine the winner.

### Reset

- A reset clears accepted buzzes for the current room.
- The next accepted buzz becomes position 1.
- The initial MVP does not require authenticated host privileges; the command may be available to any connected participant until authorization is designed.

### Reconnect

The MVP needs basic reconnect handling, not durable sessions.

At minimum:

- A reconnecting browser can rejoin the same room.
- The server can send the current room snapshot after join/rejoin.
- Durable identity across browser restarts is not required.

The browser clients wait at most 10 seconds from starting a connection until the
first `state` (join success). On timeout they discard that socket and go through
the same bounded automatic reconnect as a close (#696).

Per ADR 0003, active in-memory Room state is authoritative for the MVP:
reconnect recovers a current snapshot, not a durable event history.

**Participant identity on reconnect (since #766):** a short disconnect no
longer changes who a person is. The full contract is in
[`docs/buzzer-session.md`](buzzer-session.md#connections-disconnect-and-resume-766).

- The `state` that answers a successful `join` carries a `resume_token`
  (128-bit random), sent only to that client. The browser keeps it, with the
  room id, display name and `room_instance_id`, in `sessionStorage`: a reload
  of the same tab resumes, a new tab joins as a new person.
- When a socket closes (or the connection process dies, or the heartbeat
  times out) the room marks the participant **disconnected** instead of
  removing them, and others receive `participant_disconnected`. Their id,
  buzzes and place in the list are kept for a 60-second grace period.
- A reconnect sends `resume` with the token. Within the grace period the
  participant gets back the same `ParticipantId` and a fresh `state`; others
  receive `participant_reconnected` (no leave/join pair). If the participant
  was already attached elsewhere (for example a duplicated tab), the newest
  connection wins and the older one receives `session_replaced` and is
  closed; that client stops reconnecting.
- Commands, a late close and grace timers from a connection that is no
  longer the participant's current one are ignored by the room.
- When the grace period expires the participant is removed
  (`participant_left`); their recorded buzzes stay. The token then answers
  `resume_expired`. The room stops when its last participant's grace
  expires, or at once when no participant is left at all (ADR 0006 as
  amended by ADR 0010).
- `{"type":"leave"}` (the page's **Leave** button) removes the participant
  at once, invalidates the token and closes the connection. Closing the tab
  is not a leave.
- A `resume` that cannot be honored is answered with `room_gone` (different
  room instance, e.g. after a server restart), `resume_expired` or
  `invalid_token`. The page discards the token, shows the reason and lets
  the user join as a new participant; it does not reconnect automatically.
- A display name alone never restores a participant.
- The browser client's reconnect strategy (see `client_js.gleam`) retries a
  fixed, small number of times after an unexpected close, sending `resume`
  when it holds a token for that room and name, `join` otherwise.
- A `room_busy` error (see the error code table below) also triggers this
  same reconnect path: the client closes the connection itself instead of
  waiting for the server to do so (#570).

### Idle heartbeat timeout

Each connection is closed if no frame arrives *from its own client* within a
30-second heartbeat window (see `heartbeat_interval_ms` in
`websocket.gleam`/`poker_websocket.gleam`), so the actual grace is 30–60
seconds. Room broadcasts and successful sends do **not** count as liveness: a
connection that stops responding is removed in bounded time even while other
participants stay active (#764; this replaces #581's "broadcast keeps a silent
connection alive").

To stay connected while nobody does anything (reading a question aloud,
discussing a card), the browser client sends an application-level keepalive
`{"type":"ping"}` every 15 seconds from the moment the socket opens, and the
server answers `{"type":"pong"}`. Browsers cannot send WebSocket ping frames,
hence the JSON message. A `ping` never reaches the room actor.

- Up to 4 pings per heartbeat window do not consume the 30-message rate
  budget; pings beyond that are counted as ordinary messages, so a ping flood
  ends in `rate_limited` like any other flood. Frame size limits still apply.
- The client's ping timer is stopped on close, join timeout and permanent
  rejection, and an older socket's timer never sends on the current socket.
- If the browser throttles timers (for example a background tab) and the
  server closes the connection, the reconnect strategy above resumes the
  same participant automatically (#766).

## Suggested wire protocol

The exact JSON shape can evolve during implementation. The important requirement is that wire messages are decoded into typed domain commands/events immediately.

`room_id` is trimmed and uppercased server-side before use as the room
identifier, so `"abcd"`, `"ABCD"`, and `"AbCd"` all resolve to the same room.

Since #765 the buzzer speaks protocol version 2 (contract:
[`docs/buzzer-session.md`](buzzer-session.md#revision-and-stale-notifications-765)).
Client messages:

```json
{"type":"join","v":2,"room_id":"ABCD","display_name":"Alice"}
{"type":"resume","v":2,"room_id":"ABCD","room_instance_id":"...","resume_token":"..."}
{"type":"leave"}
{"type":"buzz","round_id":1,"request_id":"7"}
{"type":"reset","round_id":1,"request_id":"8"}
{"type":"sync"}
{"type":"ping"}
```

- `round_id` names the round the client saw; a command for any other round
  is rejected with `stale_round`, so two people pressing reset at once start
  exactly one new round.
- `request_id` (optional, 1–64 characters) only correlates the direct reply.
- `sync` asks for a fresh `state` after the client detected a missing
  revision. It counts toward the normal rate limit.

Server messages:

```json
{"type":"state","protocol_version":2,"room_instance_id":"...","self_id":"...","round_id":1,"revision":3,"participants":[{"participant_id":"...","display_name":"Alice","connected":true}],"buzzes":[{"participant_id":"...","display_name":"Alice","position":1}],"resume_token":"..."}
{"type":"participant_joined","room_instance_id":"...","revision":4,"participant":{}}
{"type":"participant_left","room_instance_id":"...","revision":5,"participant_id":"..."}
{"type":"participant_disconnected","room_instance_id":"...","revision":6,"participant_id":"..."}
{"type":"participant_reconnected","room_instance_id":"...","revision":7,"participant_id":"..."}
{"type":"buzz_accepted","room_instance_id":"...","revision":6,"round_id":1,"participant_id":"...","display_name":"Alice","position":1}
{"type":"round_reset","room_instance_id":"...","revision":7,"round_id":2}
{"type":"reply","request_id":"7","result":{"type":"buzz_accepted","...":"..."}}
{"type":"error","code":"...","message":"..."}
```

- Every state change carries the room's `room_instance_id` and the
  `revision` it produced. The client applies a change only when the instance
  matches its last `state` and the revision is exactly the next one; an
  older or equal revision is a duplicate (for example the direct reply and
  the broadcast of the same buzz) and is ignored; a gap makes the client send
  `sync` once and wait for the new `state`.
- The `state` sent on join is taken in the same room-actor message as the
  join itself, so every later broadcast on that connection is newer than it.
- A buzz/reset with a `request_id` is answered with `reply`, wrapping either
  the accepted change or the `error`. Errors raised before decoding
  (`rate_limited`, `invalid_message`, …) are also wrapped when the frame
  carried a readable `request_id`.

Error messages use the following `code` values. Clients should branch on `code`
when they need programmatic handling; `message` is human-readable detail and
may vary for the same code.

| Code | Meaning |
|---|---|
| `invalid_message` | The payload was JSON but did not match a supported client-message shape (e.g. an unknown `type`, or a `join` missing the `room_id`/`display_name` field entirely). |
| `malformed_json` | The payload was not valid JSON. |
| `invalid_room_id` | A `join` request's `room_id` was empty (or all whitespace) after trimming, or exceeded 64 characters/bytes. Takes priority over `invalid_display_name` when both fields are invalid. |
| `invalid_display_name` | A `join` request's `display_name` was empty (or all whitespace) after trimming, or exceeded 64 characters/bytes. |
| `already_joined` | This connection sent `join` after it had already joined a room (checked at the connection layer), or the room's domain layer rejected a `join` for a `ParticipantId` already present in its state (that domain-layer branch is a defensive one, unreachable from the current websocket layer because each connection gets a fresh `ParticipantId`). |
| `room_full` | The room rejected a `join` because it already holds the maximum number of participants (64). |
| `already_buzzed` | This participant already buzzed for the current round. |
| `round_full` | The current round already holds the maximum number of accepted buzzes (128, counting buzzes by participants who have since left). Further `buzz` messages are rejected until the round is reset; existing positions are unchanged (#691). |
| `buzzer_not_joined` | A `buzz` came from a connection that is not this participant's current connection (e.g. one already replaced by a `resume`), or for a participant no longer in the room (#766). |
| `room_unavailable` | The room could not be started, the server is at its `MAX_ROOMS` capacity (the `message` then says so; retrying will not help until another room ends), or a `join` did not get a reply in time. The connection is *not* closed when the room could not be started; it *is* closed (by the server) when a `join` reply timed out — clients must rely on the actual close event, not this code, to detect disconnection. |
| `room_busy` | An already-joined connection's `buzz`/`reset` did not get a reply in time. The connection is kept open, but the server has reset this session to "not joined" — the client must reconnect and re-join before sending another `buzz`/`reset` (see "Reconnect" above, #570). |
| `not_joined` | This connection sent `buzz`, `reset`, `sync` or `leave` before joining a room. |
| `room_gone` | A `resume` named a room instance that no longer exists (the room ended or the server restarted) (#766). Join as a new participant. |
| `resume_expired` | A `resume` named a participant who left or whose grace period expired (#766). Join as a new participant. |
| `invalid_token` | A `resume` carried a token this room never issued, or a malformed token/instance (#766). Join as a new participant. |
| `session_replaced` | The same participant resumed on another connection; this one is closed (#766). The client must not reconnect automatically. |
| `binary_frame` | The connection sent a binary WebSocket frame. Only text frames carry protocol meaning. |
| `rate_limited` | This connection exceeded the maximum number of messages allowed within a heartbeat window (30 messages per 30-second window). |
| `stale_round` | A `buzz` or `reset` named a round that is no longer current (#765). Nothing changed; the client already has or will receive the newer round. |
| `client_outdated` | A `join` or `resume` did not carry `"v": 2`. The server closes the connection; the page must be reloaded (#765). A v2 page also asks for a reload when a `state` carries a different `protocol_version`. |
| `frame_too_large` | An incoming text frame exceeded the maximum accepted byte size (2048 bytes). The connection is closed afterward (WebSocket close code 4000, reason `frame_too_large`, for logs/proxies; clients should still decide by this `code`). |

Do not treat these examples as a reason to expose untyped maps throughout the codebase.

## Health check

`GET /health` reports whether the buzzer room registry and the poker room
registry are responsive. It returns `200 ok buzzer_rooms=<n> buzzer_stuck=<n>
poker_rooms=<n> poker_stuck=<n>` when both answer, or `503` with a
per-registry reason (`buzzer: ...` / `poker: ...`) when either does not. See
README.md for the full response table.

## Non-functional requirements

- Domain logic must be unit-testable without opening sockets.
- Multiple rooms must not share mutable room state.
- One room crashing should not intentionally terminate unrelated rooms.
- Invalid wire messages must not crash the room process.
- Logging should make connection and room lifecycle understandable during development.
- The implementation should stay small enough to understand as a Gleam/BEAM learning project.

## Acceptance scenario

Using three browser tabs/windows:

1. All three join room `ABCD` with different display names.
2. All three see the other participants.
3. Reset the round.
4. Press buzz in the order B, A, C.
5. All three clients display the identical ordering B → A → C.
6. A second buzz from B does not change the current ordering.
7. Reset clears the results on all clients.
8. Close one client; remaining clients eventually reflect that participant leaving.

## Explicit non-goals

- Fairness compensation for Internet latency.
- Anti-cheat controls.
- User accounts.
- Host/admin authorization.
- Persistent rooms/history.
- Cross-node room routing.
- Mobile-native apps.
- Rich quiz question management.
- Scores across multiple questions.

These may become later product features, but are not part of the architecture validation MVP.
