# ADR 0003: Keep MVP room state ephemeral

- Status: Accepted
- Date: 2026-08-11

## Context

The first milestone is intended to validate real-time room architecture, typed domain messages, WebSocket transport, and BEAM process lifecycle.

Adding a database would introduce schema design, migrations, durable identity, consistency semantics, and operational concerns before the product has a demonstrated persistence requirement.

## Decision

Do not use a database or other durable state store for the buzzer MVP.

Room and round state live only in the active room process. If that process/application terminates, its state may be lost.

Clients joining an active room receive the current in-memory snapshot.

## Consequences

### Positive

- Keeps the first implementation focused on Gleam/BEAM concurrency.
- Makes ownership and lifecycle of room state easy to understand.
- Avoids unnecessary infrastructure and operating cost.
- Allows persistence requirements to emerge from actual product use cases.

### Negative

- Server restart loses all rooms and round state.
- Durable history and cross-session identity are unavailable.
- Reconnect semantics are limited to state still present in the running process.

## Future triggers for revisiting

Revisit this decision when a concrete feature requires one or more of:

- Durable room metadata.
- Match/quiz history.
- Persistent user identity.
- Auditability.
- Recovery after application/node restart.
- Multi-node coordination that cannot be solved cleanly through BEAM topology alone.

Persistence should be designed for those explicit requirements rather than added preemptively.
