# ADR 0002: Represent each active room as an isolated actor/process

- Status: Accepted
- Date: 2026-08-11

## Context

A room needs to own mutable state such as participants and buzzer ordering while processing concurrent input from multiple WebSocket connections.

Using a shared global state store would obscure the BEAM concurrency model that this project intends to evaluate and would introduce synchronization concerns across unrelated rooms.

## Decision

Represent each active logical room with one isolated BEAM process/actor that owns the authoritative state for that room.

Commands targeting a room are serialized through that process mailbox. The room process produces events/snapshots for connected participants.

A registry or equivalent routing component maps `RoomId` values to active room processes.

## Consequences

### Positive

- Room state has one clear owner.
- Message processing naturally provides deterministic command ordering within one room.
- Failure/state isolation between rooms is straightforward.
- Room lifetime can map naturally to BEAM process lifetime.
- Domain logic can be modeled as explicit state transitions.

### Negative

- State disappears when the room process terminates unless persistence is later added.
- Cross-node room discovery/routing becomes an explicit future problem if the application scales horizontally.
- Hot rooms could eventually require special treatment if one process becomes a throughput bottleneck.

## Notes

This ADR defines a conceptual boundary, not a commitment to a generic public `Room` framework API. Concrete implementation should remain application-specific until reuse is demonstrated by additional applications.
