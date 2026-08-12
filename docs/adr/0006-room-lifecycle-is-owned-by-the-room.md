# ADR 0006: The room decides when it stops; the registry reacts to that

- Status: Accepted
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
