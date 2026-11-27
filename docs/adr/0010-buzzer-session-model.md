# ADR 0010: Model a real-use buzzer session: stable participants, roles, and ordered state

- Status: Accepted
- Date: 2026-11-27
- Issue: #763 (parent plan #762)

## Context

The buzzer MVP (`docs/mvp.md`) treats every WebSocket connection as a new
participant, lets anyone reset, and creates a room lazily on the first join.
That was enough to validate the actor model, but not to run a 20-minute quiz
for 5–10 people without a developer standing by (#762):

- A phone that drops for a few seconds comes back as a *different*
  participant, so a buzz or a score cannot follow the person.
- Anyone can reset or advance, and nothing distinguishes the host from the
  audience.
- Clients guess which notification is newer by comparing content; the Poker
  fixes #752〜#761 show how many special cases that produces.
- A room disappears as soon as its last connection closes, so a host who
  reloads the page loses the meeting.

Stages 1b〜3b (#765〜#769) each need part of a new contract. Deciding it piece
by piece in each PR would let the pieces disagree. This ADR fixes the contract;
the detailed tables live in [`docs/buzzer-session.md`](../buzzer-session.md).

## Decision

1. **The room actor stays the single owner (ADR 0002)** of the meeting state:
   room instance, round, revision, participants and their connections, roles,
   acceptance phase, and scores. The transport decodes JSON, holds the socket
   and forwards opaque tokens; it never decides permission or ordering. The
   browser only displays and sends input.

2. **Connection and participant are separate identities.** A `ParticipantId`
   lives for the meeting; each WebSocket attach gets a new connection
   generation. A participant is resumed only by a random resume token returned
   to that client alone — never by display name.

3. **Three roles: Host, Player, Display.** The host capability is issued once,
   to the creator of the room, as a host token. There is no automatic
   promotion of anyone else when the host disconnects; the host either
   resumes with the token or transfers the role explicitly.

4. **Acceptance phases `Waiting / Open / Locked / Finished`**, driven only by
   the host. The first accepted buzz while `Open` locks and selects the
   answerer; later buzzes are still queued in mailbox order. Order means
   server processing order; network latency is not compensated.

5. **Every accepted change gets the next `Revision`** within a
   `RoomInstanceId`; round-scoped commands carry a `RoundId`. Clients order
   state by `(room_instance_id, revision)` and resolve their own requests by
   `request_id`. Rejected commands do not consume a revision.

6. **Scores are derived from recorded judgments**, not incremented counters,
   so a resent or corrected judgment cannot double-count.

7. **Lifetime changes ADR 0006's trigger, not its rule.** A disconnected
   participant is kept for a 60-second grace period, and an empty room stops
   after a 60-second empty-room grace instead of immediately. Both timers
   carry a generation and are checked *inside the room actor*, so judgment and
   action still happen in one message; the registry still only reacts to
   `RoomDown`.

8. **Still no persistence (ADR 0003).** A server restart ends every meeting.
   Results leave the system only through a client-side export.

9. **Versioned protocol, no long-lived compatibility branch.** The new buzzer
   protocol is `v: 2`. The server will accept the MVP protocol (v1) only until
   the first PR that changes the buzzer wire contract (#765) is merged; after
   that, v1 joins are rejected with `client_outdated`, and a v2 client that
   sees a different `server_version` asks the user to reload.

10. **Planning Poker is out of scope.** It keeps its MVP identity and
    permission model; #688 / #694 stay under their own constraints. The
    shared modules (`room_registry`, `wire`, `ws_guard`, `client_js`) may gain
    functions the buzzer needs, but no generic session/permission framework
    is extracted from this work (ADR 0009, CLAUDE.md Generalization rule).

## Consequences

### Positive

- Each follow-up issue implements a part of one contract instead of
  inventing its own.
- Stale notifications are detected by number, not by content.
- A short disconnect no longer changes who a person is, so scores and
  "already buzzed" survive it.
- Host capability cannot be taken by typing the host's name.

### Negative

- Room actors live up to 60 seconds after the last connection, so idle rooms
  count against `MAX_ROOMS` for longer.
- The actor holds secrets (tokens) in memory; logging and broadcast code must
  keep them out (they are never part of `RoomEvent` broadcasts).
- Users with an open v1 tab must reload once when v2 ships.
- The buzzer and Planning Poker diverge further, which makes later
  extraction (README step 4) a separate, larger judgment.

## Relation to earlier ADRs

| ADR | Effect |
|---|---|
| 0002 room per actor | Unchanged; strengthened (more state in the same owner). |
| 0003 no persistence | Unchanged. Restart loss is now a documented user-facing limit. |
| 0006 room owns its lifetime | **Changed trigger**: "empty" now means "no attached connection for the empty-room grace", checked by a generation-tagged timer inside the actor. The registry side is unchanged. |
| 0009 duplicate before extracting | Unchanged. Buzzer-only model. |
