# ADR 0006: The room decides when it stops; the registry reacts to that

- Status: Accepted (trigger amended by [ADR 0010](0010-buzzer-session-model.md), implemented in #766)
- Date: 2026-08-12
- Recorded retroactively for #26, #36, #39, and #91.

## Context

An empty room should not stay resident, and its registry entry should not
outlive it. The first implementation had the WebSocket layer do this:

1. ask the room for a snapshot,
2. if it was empty, ask the registry to release and stop it.

Those are two messages to two processes. Between them, another connection could
`lookup` the same room and join it. The room was then stopped **with a
participant inside**, and that participant was left in a room nobody else could
reach.

A subject-equality guard was added against the ABA case (the actor being
replaced), which made the design look protected while this window stayed open.

## Decision

**Judgment and action live in one message handled by the room itself.**

- `ShutdownIfEmpty` makes the room check its own participant list and stop in
  the same handler, replying *before* it stops. The caller removes the registry
  entry only if the room actually stopped.
- When a session process dies and that leaves the room empty, the room stops
  itself (#91). It cannot notify the registry — it does not know it.
- The registry traps exits and treats a room's termination (`RoomDown`) as the
  signal to drop the entry. This works for crashes **and for normal stops**;
  that was verified rather than assumed.

## Consequences

### Positive

- No cross-process window between "is it empty" and "stop it".
- One cleanup path serves crashes, normal stops, and dead sessions.
- The room needs no reference to the registry.

### Negative

- The registry learns about removal asynchronously; a `lookup` racing with a
  stop can observe the dying subject. Callers already tolerate that through
  ADR 0005.
- A stopped room's subject may still be held by a client; the next call fails
  and a fresh room is created on the next `lookup`.

## Notes

A guard written against one race only stops that race. The subject-equality
check was correct and still did not cover the case above, because it answered
"is this the same actor?" and the open question was "did someone join since I
looked?".

## Amendment (ADR 0010, #766)

For the buzzer, a closed connection no longer means a participant left. The
room keeps a disconnected participant for a resume grace period (60 s) and
checks a generation-tagged `GraceExpired` timer **inside the actor**, so the
rule of this ADR still holds: the room judges and acts in one message.

- A dead session marks its participant disconnected; it no longer empties
  the room by itself.
- When the last participant's grace expires, the room stops itself, and the
  registry drops it on `RoomDown` as before.
- `ShutdownIfEmpty` counts participants within grace as present, so a
  `Release` cannot stop a room someone may still resume.
- A room with no participants at all (everyone left explicitly, or a lazily
  created room whose join was rejected) still stops immediately through
  `Release`. A separate empty-room timer is not needed until rooms can exist
  without participants (explicit creation, #767).

## Amendment (ADR 0010, #767)

Buzzer rooms are now created explicitly (`create`), so a room can exist
before anyone has joined it. The room schedules one `EmptyRoomGrace`
message to itself when it starts (60 s); if it still has no participant when
that message arrives, it stops itself in that same message. This reclaims a
room whose creator's first join never arrived. Joining an unknown code no
longer creates a room, so the "a fresh room is created on the next `lookup`"
consequence above no longer applies to the buzzer's WebSocket path.

Planning Poker keeps the original trigger.
