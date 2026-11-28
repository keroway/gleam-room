# Multiplayer Buzzer MVP

> **Scope note (2026-11, #763).** This document describes the MVP as built
> and still running. Its non-goals (no authorization, connection-scoped
> participants, anyone may reset) were the MVP's scope, not a permanent
> decision for the buzzer. The real-use buzzer contract that replaces parts
> of it is [ADR 0010](adr/0010-buzzer-session-model.md) /
> [`docs/buzzer-session.md`](buzzer-session.md); each part takes effect only
> when its implementing issue (#765〜#769) lands.

## Objective

Validate the end-to-end architecture for a real-time multi-user room on Gleam/BEAM.

The MVP is successful when multiple independent browser clients can join the same logical room, press a buzzer, and observe one server-authoritative ordering of presses.

## Primary user flow

1. A user opens the web client. One person creates a room (#767) and shares
   the invite URL or QR code; the others open it.
2. The user enters a display name (the room comes from the invite URL, or is
   typed as a room code).
3. The browser establishes a WebSocket connection.
4. The server joins the participant to the room.
5. Multiple participants can be present concurrently.
6. The creator is the host (#768). The host opens acceptance; while it is
   open, each player can press the buzzer once. The host does not buzz.
7. The room assigns buzzer positions in the order commands are accepted. The
   first accepted buzz locks the question and names the answerer.
8. All connected participants receive the updated ordered result.
9. The host's "next question" clears the buzzes and waits for the next
   opening.
10. Leaving/disconnecting updates room presence.

## Functional requirements

### Room join

- A room is identified by a room code. Since #767 the server issues it when
  someone creates a room (`create`): 6 characters from
  `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no `I`/`O`/`0`/`1`), drawn from a
  cryptographic random source.
- Joining or resuming an unknown code never creates a room (#767): `join`
  answers `room_not_found`, `resume` answers `room_gone`. Before #767 a join
  created the room lazily.
- The invite URL is `/r/<room code>`. It serves the same page, which joins
  that room after the user enters a name. It carries only the room code,
  never a token.
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

### Host, players and displays (#768)

The MVP's reset, which anyone could send, is gone. Roles and phases follow
[`docs/buzzer-session.md`](buzzer-session.md#roles-and-permissions):

- The room's creator is the **host**: opens and closes acceptance, skips a
  question, moves to the next question, hands the role to a connected player
  and ends the session. The room checks every one of these commands; hiding
  the buttons is only a guide.
- **Players** buzz, only while acceptance is open (`open`) or after the
  first buzz locked the question (`locked`; later buzzes are queued).
- A **display** (`/r/<room code>/display`) shows the phase, the answerer and
  the order in large type. It is not a participant and cannot send commands.
- "Next question" (`next_question`) clears the accepted buzzes; the next
  accepted buzz becomes position 1.

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
  amended by ADR 0010). A room nobody joined within 60 seconds of its
  creation also stops (#767).
- `{"type":"leave"}` (the page's **Leave** button) removes the participant
  at once, invalidates the token and closes the connection. Closing the tab
  is not a leave.
- A `resume` that cannot be honored is answered with `room_gone` (no room
  with that code, or a different room instance, e.g. after a server restart), `resume_expired` or
  `invalid_token`. The page discards the token, shows the reason and lets
  the user join as a new participant; it does not reconnect automatically.
- A display name alone never restores a participant.
- The browser client's reconnect strategy (see `client_js.gleam`) retries a
  fixed, small number of times after an unexpected close, sending `resume`
  when it holds a token for that room and name, `join` otherwise. A `create`
  whose reply never arrived is not resent (it could create a second room);
  the page asks the user to press "部屋を作る" again (#767).
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
{"type":"create","v":2,"display_name":"Alice"}
{"type":"join","v":2,"room_id":"ABCD","display_name":"Alice"}
{"type":"resume","v":2,"room_id":"ABCD","room_instance_id":"...","resume_token":"...","host_token":"..."}
{"type":"watch","v":2,"room_id":"ABCD"}
{"type":"leave"}
{"type":"buzz","round_id":1,"request_id":"7"}
{"type":"open","round_id":1,"request_id":"8"}
{"type":"close","round_id":1}
{"type":"skip","round_id":1}
{"type":"next_question","round_id":1}
{"type":"transfer_host","participant_id":"..."}
{"type":"end_session"}
{"type":"sync"}
{"type":"ping"}
```

- `create` (#767) makes a new room and joins it as its creator, who becomes
  the host (#768). The reply is the usual `state` plus `room_id` (the issued
  code) and `host_token`.
- `resume` carries `host_token` only from the host's browser (#768). A
  matching host token brings the host back even after its grace period ran
  out; otherwise `resume_token` decides as before.
- `watch` (#768) attaches a display. Its `state` has `self_role: "display"`
  and no `self_id`; every command it sends is answered `forbidden`.
- `open`/`close`/`skip`/`next_question`/`transfer_host`/`end_session` are the
  host's commands (#768). From anyone else they are answered `forbidden`.
- `round_id` names the round the client saw; a command for any other round
  is rejected with `stale_round`, so a double click or a resend of
  `next_question` starts exactly one new question.
- `request_id` (optional, 1–64 characters) only correlates the direct reply.
- `sync` asks for a fresh `state` after the client detected a missing
  revision. It counts toward the normal rate limit.

Server messages:

```json
{"type":"state","protocol_version":2,"room_instance_id":"...","self_role":"host","round_id":1,"revision":3,"phase":"waiting","participants":[{"participant_id":"...","display_name":"Alice","connected":true,"role":"host"}],"buzzes":[{"participant_id":"...","display_name":"Alice","position":1}],"self_id":"...","resume_token":"...","room_id":"K7M2QX","host_token":"..."}
{"type":"participant_joined","room_instance_id":"...","revision":4,"participant":{}}
{"type":"participant_left","room_instance_id":"...","revision":5,"participant_id":"..."}
{"type":"participant_disconnected","room_instance_id":"...","revision":6,"participant_id":"..."}
{"type":"participant_reconnected","room_instance_id":"...","revision":7,"participant_id":"..."}
{"type":"buzz_accepted","phase":"locked","room_instance_id":"...","revision":6,"round_id":1,"participant_id":"...","display_name":"Alice","position":1}
{"type":"round_reset","room_instance_id":"...","revision":7,"round_id":2}
{"type":"phase_changed","room_instance_id":"...","revision":8,"round_id":2,"phase":"open"}
{"type":"host_transferred","room_instance_id":"...","revision":9,"from":"...","to":"..."}
{"type":"host_assigned","host_token":"..."}
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
- `resume_token` is present only in the reply to the participant's own
  `join`/`create`; `room_id` and `host_token` only in the reply to `create`
  (#767). After `transfer_host`, the new host alone receives
  `host_assigned` with a fresh host token, and the previous one stops
  working (#768).
- `phase` is `waiting`, `open`, `locked` or `finished` (#768). `round_reset`
  (the host's next question) always starts in `waiting` with no buzzes.
- Participants carry `role` (`host` or `player`).
- A command with a `request_id` is answered with `reply`, wrapping either
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
| `invalid_display_name` | A `join` or `create` request's `display_name` was empty (or all whitespace) after trimming, or exceeded 64 characters/bytes. |
| `already_joined` | This connection sent `join`, `create` or `resume` after it had already joined a room (checked at the connection layer), or the room's domain layer rejected a `join` for a `ParticipantId` already present in its state (that domain-layer branch is a defensive one, unreachable from the current websocket layer because each connection gets a fresh `ParticipantId`). |
| `room_not_found` | A `join` named a room code that has no room (it ended, or the code is wrong). No room is created (#767). The connection stays open. |
| `room_full` | The room rejected a `join` because it already holds the maximum number of participants (64). |
| `already_buzzed` | This participant already buzzed for the current round. |
| `round_full` | The current round already holds the maximum number of accepted buzzes (128, counting buzzes by participants who have since left). Further `buzz` messages are rejected until the next question; existing positions are unchanged (#691). |
| `buzzer_not_joined` | A `buzz` came from a connection that is not this participant's current connection (e.g. one already replaced by a `resume`), or for a participant no longer in the room (#766). |
| `room_unavailable` | A `create` could not start a room, the server is at its `MAX_ROOMS` capacity (the `message` then says so; retrying will not help until another room ends), or a `join` did not get a reply in time. The connection is *not* closed when the room could not be started; it *is* closed (by the server) when a `join` reply timed out — clients must rely on the actual close event, not this code, to detect disconnection. |
| `room_busy` | An already-joined connection's command did not get a reply in time. The connection is kept open, but the server has reset this session to "not joined" — the client must reconnect and re-join before sending another command (see "Reconnect" above, #570). |
| `not_joined` | This connection sent a command, `sync` or `leave` before joining a room, or from a connection already replaced by a `resume`. |
| `not_accepting` | A `buzz` arrived while the phase is `waiting` (#768). |
| `forbidden` | The sender's role cannot do that (#768): a player or display sent a host command, a display buzzed, or the host buzzed. |
| `invalid_phase` | A host command is not possible in the current phase, e.g. `open` while already open, `close` after the first buzz (#768). |
| `session_finished` | The host ended the session (#768). Joining, buzzing and host commands are rejected; a resume still works so the results stay visible. |
| `session_full` | `next_question` beyond the 200-question limit (#768). |
| `invalid_target` | `transfer_host` named someone who is not a connected player (#768). |
| `displays_full` | A `watch` for a room that already has 8 displays (#768). |
| `room_gone` | A `resume` named a room code with no room, or a room instance that no longer exists (the room ended or the server restarted) (#766, #767). Join as a new participant. |
| `resume_expired` | A `resume` named a participant who left or whose grace period expired (#766). Join as a new participant. |
| `invalid_token` | A `resume` carried a token this room never issued, or a malformed token/instance (#766). Join as a new participant. |
| `session_replaced` | The same participant resumed on another connection; this one is closed (#766). The client must not reconnect automatically. |
| `binary_frame` | The connection sent a binary WebSocket frame. Only text frames carry protocol meaning. |
| `rate_limited` | This connection exceeded the maximum number of messages allowed within a heartbeat window (30 messages per 30-second window). |
| `stale_round` | A `buzz` or host command named a round that is no longer current (#765). Nothing changed; the client already has or will receive the newer round. |
| `client_outdated` | A `join`, `create` or `resume` did not carry `"v": 2`. The server closes the connection; the page must be reloaded (#765). A v2 page also asks for a reload when a `state` carries a different `protocol_version`. |
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

1. The host creates a room; three players open its invite URL. Everyone uses
   a different display name. A fifth tab opens the display URL.
2. Everyone sees the other participants; the host is marked as host.
3. Buzzing before the host opens acceptance does nothing. The host opens.
4. Press buzz in the order B, A, C.
5. All clients and the display show the identical ordering B → A → C, and B
   as the answerer.
6. A second buzz from B does not change the current ordering.
7. The host's "next question" clears the results on all clients.
8. Close one client; remaining clients eventually reflect that participant leaving.

## Explicit non-goals

- Fairness compensation for Internet latency.
- Anti-cheat controls.
- User accounts.
- Host/admin authentication (the host role of #768 is a capability token,
  not an account).
- Persistent rooms/history.
- Cross-node room routing.
- Mobile-native apps.
- Rich quiz question management.
- Scores across multiple questions.

These may become later product features, but are not part of the architecture validation MVP.
