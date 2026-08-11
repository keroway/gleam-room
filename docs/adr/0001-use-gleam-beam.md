# ADR 0001: Use Gleam on the BEAM for the real-time backend

- Status: Accepted
- Date: 2026-08-11

## Context

The project exists primarily to explore where Gleam and the BEAM runtime provide a meaningful architectural advantage rather than merely serving as an alternative language for conventional CRUD development.

The target applications involve many concurrent rooms/connections, isolated state, long-lived processes, message passing, timers, and fault isolation.

## Decision

Use Gleam targeting Erlang/BEAM as the primary backend implementation platform.

Use actor/message-passing patterns for room state and lifecycle rather than shared mutable state.

The expected initial ecosystem is:

- Gleam.
- `gleam_otp` for actor/supervision primitives.
- Mist for HTTP/WebSocket transport.

Exact dependency versions are resolved during implementation and should not be hard-coded into architectural documents unless required.

## Consequences

### Positive

- The architecture exercises BEAM strengths directly.
- Gleam custom types can make protocol and state transitions explicit.
- Lightweight processes provide a natural isolation boundary for rooms.
- OTP supervision concepts are available when lifecycle/failure handling grows.

### Negative

- The ecosystem is smaller than mainstream web stacks.
- Some browser-facing or infrastructure integrations may require Erlang interop or complementary frontend code.
- Contributors may need familiarity with actor/OTP concepts.

## Alternatives considered

### Node.js/TypeScript

A strong pragmatic choice for WebSocket applications, but it would weaken the project's primary objective of learning and validating Gleam/BEAM architecture.

### Elixir/Phoenix

Highly suitable technically, especially Phoenix Channels/LiveView, but the project specifically intends to investigate Gleam's typed language experience on the BEAM.
