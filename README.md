# gleam-room

`gleam-room` is an experimental project for building real-time multi-user applications with Gleam and the BEAM actor model.

Rather than designing a generic framework up front, the project starts with concrete applications and extracts reusable room/session primitives only after repeated patterns become clear.

The first application is a multiplayer buzzer quiz.

## Goals

- Explore actor-oriented real-time application design with Gleam/BEAM.
- Keep room state isolated and explicit.
- Use typed messages at domain boundaries.
- Build a small but convincing end-to-end multiplayer application first.
- Extract reusable room primitives from multiple real applications rather than speculative abstraction.

## Initial MVP

The first vertical slice should allow multiple browser clients to join the same room over WebSocket, press a buzzer, and receive the server-authoritative press order.

MVP capabilities:

- Create or join a room.
- Multiple simultaneous WebSocket clients.
- Participant join/leave presence.
- Buzzer input.
- Server-side ordering of buzzer events.
- Round reset.
- Basic reconnect handling.

Explicitly out of scope for the MVP:

- Authentication and authorization.
- Database persistence.
- CRDT-based editing.
- WebRTC/P2P networking.
- Blockchain.
- Distributed BEAM nodes.
- Rich frontend frameworks.
- Production-grade security/compliance features.

## Architecture direction

```text
Browser clients
      |
   WebSocket
      |
 HTTP/WebSocket transport
      |
  Room Registry
      |
   Room Actor
      |
 Typed domain messages
```

A room should conceptually map to one supervised BEAM process. Transport concerns must stay separate from room-domain logic so the room state machine can be tested without WebSocket connections.

See [`docs/architecture.md`](docs/architecture.md), [`docs/mvp.md`](docs/mvp.md), and [`docs/adr/`](docs/adr/) for the current design decisions.

## Roadmap

1. Multiplayer buzzer prototype.
2. Complete buzzer quiz MVP.
3. Build a second application such as Planning Poker.
4. Extract reusable room/presence/lifecycle primitives.
5. Build a high-frequency crowd-controlled game.
6. Re-evaluate whether the extracted primitives deserve a standalone library/API.

## Development workflow

Development is intentionally issue-driven:

1. Pick one narrowly scoped issue.
2. Read `README.md` and `AGENTS.md` before implementation.
3. Implement the smallest coherent change.
4. Add or update tests.
5. Open a pull request with design notes and validation results.
6. Avoid unrelated refactoring or premature generalization.

## License

MIT. See [`LICENSE`](LICENSE).
