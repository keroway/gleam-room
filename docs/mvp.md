# Multiplayer Buzzer MVP

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

Per ADR 0003, active in-memory Room state is authoritative for the MVP:
reconnect recovers a current snapshot, not a durable event history.

**Participant identity on reconnect (transient, by design):**

- A `ParticipantId` is a cryptographically random, opaque token generated
  fresh for each connection (see `websocket.new_participant_id`), not from
  any client-supplied or persisted token, and not derived from the
  connection's BEAM process identity.
- A dropped connection is therefore indistinguishable, on the server, from a
  participant leaving: when the socket closes, the transport layer dispatches
  `Leave` for that connection's `ParticipantId` and the Room actor removes it
  from presence and from its subscriber set.
- A reconnect is a brand new WebSocket connection sending a new `Join`. It is
  assigned a new `ParticipantId` and appears to already-connected clients as
  a new participant, even if the browser/display name is unchanged. There is
  no server-side correlation between the old and new identity.
- Because the old connection's `Leave` and the new connection's `Join` happen
  on independent processes, their relative order is not guaranteed. Other
  clients may briefly observe both the pre-reconnect and post-reconnect
  identity, or a leave immediately followed by a join, depending on timing.
- The browser client's minimal reconnect strategy (see `web.gleam`) retries
  a fixed, small number of times after an unexpected close, reusing the last
  entered room ID and display name; it does not attempt to preserve or
  restore the previous `ParticipantId`.

## Suggested wire protocol

The exact JSON shape can evolve during implementation. The important requirement is that wire messages are decoded into typed domain commands/events immediately.

Illustrative client messages:

```json
{"type":"join","room_id":"ABCD","display_name":"Alice"}
{"type":"buzz"}
{"type":"reset"}
```

Illustrative server messages:

```json
{"type":"state","participants":[],"buzzes":[{"participant_id":"...","display_name":"Alice","position":1}]}
{"type":"participant_joined","participant":{}}
{"type":"participant_left","participant_id":"..."}
{"type":"buzz_accepted","participant_id":"...","display_name":"Alice","position":1}
{"type":"round_reset"}
{"type":"error","code":"...","message":"..."}
```

Error messages use the following `code` values. Clients should branch on `code`
when they need programmatic handling; `message` is human-readable detail and
may vary for the same code.

| Code | Meaning |
|---|---|
| `invalid_message` | The payload was JSON but did not match a supported client-message shape (e.g. an unknown `type`, or a `join` missing the `room_id`/`display_name` field entirely). |
| `malformed_json` | The payload was not valid JSON. |
| `invalid_room_id` | A `join` request's `room_id` was empty (or all whitespace) after trimming, or exceeded 64 characters/bytes. Takes priority over `invalid_display_name` when both fields are invalid. |
| `invalid_display_name` | A `join` request's `display_name` was empty (or all whitespace) after trimming, or exceeded 64 characters/bytes. |
| `already_joined` | This connection sent `join` after it had already joined a room (checked at the connection layer), or the room's domain layer rejected a `join` for a `ParticipantId` already present in its state. |
| `room_full` | The room rejected a `join` because it already holds the maximum number of participants (64). |
| `already_buzzed` | This participant already buzzed for the current round. |
| `buzzer_not_joined` | This connection has not joined the room yet, so the buzz was rejected. |
| `room_unavailable` | The requested room could not be started or did not respond in time. Whether the connection is closed afterward depends on *when* this occurred (join timeout closes it; buzz/reset timeout keeps it open) and is **not** distinguishable from `code` alone — clients must rely on the actual close event, not this code, to detect disconnection. |
| `not_joined` | This connection sent `buzz` or `reset` before joining a room. |
| `binary_frame` | The connection sent a binary WebSocket frame. Only text frames carry protocol meaning. |
| `rate_limited` | This connection exceeded the maximum number of messages allowed within a heartbeat window (30 messages per 30-second window). |
| `frame_too_large` | An incoming text frame exceeded the maximum accepted byte size (2048 bytes). The connection is closed afterward. |

Do not treat these examples as a reason to expose untyped maps throughout the codebase.

## Health check

`GET /health` reports whether the buzzer room registry (and, once Planning
Poker is running alongside it, the poker room registry) are responsive. It
returns `200 ok buzzer_rooms=<n> buzzer_stuck=<n> poker_rooms=<n>
poker_stuck=<n>` when both answer, or `503` with a per-registry reason
(`buzzer: ...` / `poker: ...`) when either does not. See README.md for the
full response table.

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
