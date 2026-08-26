# Planning Poker

## Objective

Build the second concrete real-time multi-user application on this
repository's Gleam/BEAM architecture. Planning Poker is chosen because it
shares the buzzer's shape (one room, multiple WebSocket clients, a
server-authoritative round) while introducing a requirement the buzzer never
needed: **secrecy until reveal**.

Per ADR 0009, Planning Poker duplicates the buzzer's registry/transport/
client rather than sharing code with it. This document, plus
[`docs/mvp.md`](mvp.md) for the buzzer, are the two data points step 4
(extracting reusable room/presence/lifecycle primitives) will compare before
generalizing anything.

## Primary user flow

1. A user opens the Planning Poker web client.
2. The user enters a room ID and display name.
3. The browser establishes a WebSocket connection to `/poker/ws`.
4. The server joins the participant to the room in the `Voting` phase.
5. Multiple participants can be present concurrently.
6. Each participant casts (or changes) a vote from a fixed card set while the
   round is `Voting`.
7. Other participants see *that* a participant has voted, not the vote value.
8. Any connected participant can trigger reveal, transitioning the room to
   `Revealed`.
9. On reveal, all connected participants receive every cast vote.
10. A reset command clears the current round's votes and returns the room to
    `Voting`.
11. Leaving/disconnecting updates room presence, same as the buzzer.

## Functional requirements

### Room join

- A room is identified by a compact `RoomId` supplied by the client, same as
  the buzzer (ADR-compatible: no auth for the MVP).
- Joining an unknown room may create it lazily, in the `Voting` phase with no
  votes cast.
- A participant supplies a display name.
- The server assigns a `ParticipantId`, transient per connection — identical
  identity model to the buzzer (see `docs/mvp.md`'s Reconnect section); this
  document does not repeat that reasoning.

### Presence

- The room tracks currently connected participants.
- Connected clients receive enough information to render current presence
  and, per participant, whether they have voted in the current round
  (without revealing the value).
- A clean disconnect removes the participant. Abrupt disconnect is handled at
  the WebSocket lifecycle level, same as the buzzer.

### Voting phase

- The room starts a round in the `Voting` phase.
- A participant can cast a vote from a fixed card set (see wire protocol).
- A participant may change their vote any number of times while the round is
  `Voting`. This is the key divergence from the buzzer's buzz-once semantics.
- Votes are not broadcast to other clients while `Voting`; only the fact that
  a participant has voted is broadcast.
- Casting a vote after `Revealed` (before the next reset) is rejected.

### Reveal

- Any connected participant can request reveal (no host role for the MVP,
  matching the buzzer's reset authorization stance).
- Reveal transitions the room from `Voting` to `Revealed`.
- On reveal, the room broadcasts every participant's vote, including
  participants who did not vote (represented explicitly, not omitted).
- Reveal is idempotent while already `Revealed`: a repeat request has no
  effect beyond returning the same result.

### Reset

- A reset clears all cast votes and returns the room to `Voting`, regardless
  of whether it was called from `Voting` or `Revealed`.
- No authenticated host privileges are required for the MVP, matching the
  buzzer's stance in `docs/mvp.md`.

### Reconnect

Same transient-identity model as the buzzer's Reconnect section in
`docs/mvp.md`: a reconnect is a new `Join` with a new `ParticipantId`, not a
resumption of the previous connection's identity. On join/rejoin, the server
sends the current room snapshot, including the current phase (`Voting` or
`Revealed`) and, if `Revealed`, every already-cast vote.

## Suggested wire protocol

The exact JSON shape can evolve during implementation. As with the buzzer,
wire messages must be decoded into typed domain commands/events immediately,
not passed through as untyped maps.

Client messages:

```json
{"type":"join","room_id":"ABCD","display_name":"Alice"}
{"type":"vote","value":"5"}
{"type":"reveal"}
{"type":"reset"}
```

The vote card set for the MVP is a fixed enumeration:
`"0"`, `"1"`, `"2"`, `"3"`, `"5"`, `"8"`, `"13"`, `"21"`, `"?"`, `"coffee"`.

Server messages:

```json
{"type":"state","phase":"voting","participants":[{"participant_id":"...","display_name":"Alice","has_voted":true}]}
{"type":"participant_joined","participant":{"participant_id":"...","display_name":"Alice","has_voted":false}}
{"type":"participant_left","participant_id":"..."}
{"type":"vote_registered","participant_id":"..."}
{"type":"revealed","votes":[{"participant_id":"...","display_name":"Alice","value":"5"}]}
{"type":"round_reset"}
{"type":"error","code":"...","message":"..."}
```

Note the deliberate asymmetry: `vote_registered` carries only
`participant_id` (presence of a vote, not its value); `revealed` carries
every participant's `value`, including participants who never voted
(represented with an explicit `null` value rather than omitted from the
list).

Error codes reuse the buzzer's shared codes where the underlying condition is
identical, and add phase-specific ones:

| Code | Meaning |
|---|---|
| `invalid_message` | The payload was JSON but did not match a supported client-message shape. |
| `malformed_json` | The payload was not valid JSON. |
| `invalid_room_id` | A `join` request's `room_id` was empty/whitespace-only after trimming, or exceeded 64 characters/bytes. |
| `invalid_display_name` | A `join` request's `display_name` was empty/whitespace-only after trimming, or exceeded 64 characters/bytes. |
| `already_joined` | This connection sent `join` after already joining, or the domain layer rejected a `join` for a `ParticipantId` already present. |
| `room_full` | The room rejected a `join` because it already holds the maximum number of participants. |
| `not_joined` | This connection sent `vote`, `reveal`, or `reset` before joining a room. |
| `invalid_card` | The `vote` message's `value` is not a member of the fixed card set. |
| `already_revealed` | A `vote` was rejected because the round is `Revealed`; the client must wait for `reset`. |
| `not_voting_phase` | Reserved for a command restricted to the `Voting` phase; unused until a phase-gated command beyond `vote` exists. |
| `room_unavailable` | The requested room could not be started or did not respond in time. |
| `binary_frame` | The connection sent a binary WebSocket frame. |
| `rate_limited` | This connection exceeded the maximum number of messages allowed within a heartbeat window. |
| `frame_too_large` | An incoming text frame exceeded the maximum accepted byte size. The connection is closed afterward. |

Do not treat these examples as a reason to expose untyped maps throughout the
codebase.

## Differences from the buzzer

These are the requirements that justify Planning Poker as a genuinely
different second application, not a relabeled buzzer:

- **Secrecy until reveal.** The buzzer never withholds information from
  connected clients; Planning Poker's core mechanic depends on it.
- **Vote changes before reveal.** The buzzer accepts at most one buzz per
  round per participant; Planning Poker allows unlimited re-votes while
  `Voting`.
- **Explicit two-phase round state (`Voting` / `Revealed`).** The buzzer has
  an implicit "open round" with no separate reveal step — reset is its only
  phase transition. Planning Poker's domain state must model phase
  explicitly and reject/allow commands based on it (`vote` only in `Voting`;
  `reveal` is idempotent in `Revealed`).

## Health check

`GET /health` queries the poker room registry alongside the buzzer one and
reports `200 ok buzzer_rooms=<n> buzzer_stuck=<n> poker_rooms=<n>
poker_stuck=<n>` when both answer, or `503` with a per-registry reason
(`buzzer: ...` / `poker: ...`, `;`-joined if both fail) otherwise. This keeps
the poker registry's health from being silently invisible to whatever is
polling `/health` (see `docs/mvp.md` and README.md for the full format).

## Non-functional requirements

Same as the buzzer's non-functional requirements in `docs/mvp.md`:
domain logic unit-testable without opening sockets, no shared mutable state
across rooms, one room crashing must not terminate unrelated rooms, invalid
wire messages must not crash the room process, and the implementation should
stay small enough to understand as a learning project.

## Acceptance scenario

Using three browser tabs/windows:

1. All three join room `ABCD` with different display names.
2. All three see the other participants, none marked as having voted.
3. A and B cast votes; all three clients see A and B marked as having voted,
   with no vote values shown. C is not marked as having voted.
4. B changes their vote before reveal; the marked-as-voted state is
   unaffected (still true) and no client observes the intermediate value.
5. Any participant triggers reveal.
6. All three clients display the same revealed votes: A's and B's final
   values, and C's explicit "no vote" value.
7. A repeat reveal request has no visible effect.
8. Reset clears the round; all three clients return to `Voting` with no
   participant marked as having voted.
9. Close one client; remaining clients eventually reflect that participant
   leaving.

## Explicit non-goals

- Estimation statistics (average, consensus detection, outlier highlighting).
- Multiple concurrent estimation items/backlog integration.
- Timers/auto-reveal.
- Host/admin authorization for reveal or reset.
- User accounts.
- Persistent rooms/history.
- Cross-node room routing.
- Mobile-native apps.
- Custom/configurable card sets.

These may become later product features, but are not part of validating the
architecture against a second application with genuinely different
requirements.
