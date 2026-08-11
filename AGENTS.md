# AGENTS.md

## Project goal

This repository explores real-time multi-user applications using Gleam and the BEAM actor model.

The first application is a multiplayer buzzer quiz. The long-term goal is to extract reusable room/session primitives from concrete applications after repeated patterns have been validated.

## Core principles

- Gleam/BEAM concurrency is the primary architectural focus.
- Prefer actors and message passing over shared mutable state.
- One active room should conceptually map to one supervised process.
- Keep the initial architecture simple and observable.
- Do not introduce a database unless persistence is actually required.
- Do not introduce distributed BEAM, WebRTC/P2P, CRDTs, or blockchain prematurely.
- Build concrete applications before generalizing abstractions.
- Separate transport concerns from domain logic.

## MVP scope

The MVP must support:

- Create or join a room.
- Multiple WebSocket clients in one room.
- Join and leave notifications.
- Buzzer input.
- Server-side ordering of buzzer events.
- Reset round.
- Basic reconnect handling.

The MVP explicitly does **not** include:

- Authentication or authorization.
- Database persistence.
- CRDT.
- WebRTC/P2P.
- Blockchain.
- Distributed BEAM nodes.
- Rich frontend frameworks.
- Production-grade authorization/compliance controls.

## Architecture constraints

```text
Browser
  |
WebSocket
  |
Transport layer
  |
Room Registry
  |
Room Actor
  |
Typed domain state/messages
```

- Room-domain behavior must be testable without a live WebSocket connection.
- External data must be parsed/validated at the boundary and converted to typed domain values immediately.
- Domain code must not depend directly on browser-specific or HTTP-specific concepts unless unavoidable.
- Prefer explicit custom types for commands, events, identifiers, and state.

## Coding rules

- Prefer small, cohesive Gleam modules.
- Use Gleam custom types for domain modeling.
- Avoid `Dynamic` except at external boundaries where decoding requires it.
- Keep side effects at the edges.
- Avoid speculative abstractions and generic frameworks.
- Avoid global mutable state.
- Add tests for state transitions and ordering behavior.
- Add comments only where intent or a non-obvious invariant needs explanation.
- Keep public APIs small until a second concrete application proves reuse.

## Dependency policy

- Prefer established Gleam packages with a clear maintenance story.
- Keep the dependency set minimal.
- The expected initial stack is Gleam on BEAM, `gleam_otp` for actors/supervision, and Mist for HTTP/WebSocket transport.
- Do not add a frontend framework for the first vertical slice unless an issue explicitly calls for it.

## Agent workflow

Before implementing an issue:

1. Read `README.md`, `AGENTS.md`, and the relevant ADRs.
2. Read the issue completely, including acceptance criteria and non-goals.
3. Inspect the existing implementation before proposing structural changes.
4. Implement the smallest coherent change satisfying the issue.
5. Add or update tests.
6. Run formatter and tests before completion.
7. Update documentation only if behavior or architecture changed.
8. Summarize design decisions, validation, and known limitations in the PR.

## Pull request expectations

A PR should include:

- What changed.
- Why the chosen design fits the issue and ADRs.
- Tests/commands run.
- Any intentionally deferred concerns.

Do not combine unrelated issues in one PR unless explicitly requested.

## Generalization rule

Do not create a generic room framework from the buzzer application alone. Reusable abstractions should be extracted only after at least one additional application (for example Planning Poker) demonstrates the same requirements.
