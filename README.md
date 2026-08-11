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

## Development commands

```sh
gleam build   # compile
gleam test    # run unit tests
gleam format  # format source
gleam run     # start the HTTP server (default port 4000, override with PORT)
```

Once running, `GET http://localhost:4000/health` returns `200 ok`.

`.github/workflows/ci.yml` runs `gleam format --check`, `gleam build`, and
`gleam test` on every pull request and push to `main`.

### Browser client

Opening `http://localhost:4000/` in a browser serves a minimal HTML/CSS/JS
client for manually exercising room join/presence and buzzer behavior. Enter
a room ID and display name to join, then use the buzzer button; opening the
same room in multiple tabs shows presence and buzz updates propagate to all
of them. It is a thin wire-protocol client with no build tool or framework;
see `src/gleamroom/web.gleam`.

### Manual MVP acceptance procedure

`ws://localhost:4000/ws` accepts WebSocket connections speaking the typed
join/buzz/reset protocol described in
[`docs/mvp.md`](docs/mvp.md#suggested-wire-protocol); see
`src/gleamroom/protocol.gleam` and `src/gleamroom/websocket.gleam`. The
browser client above is the easiest way to exercise it manually. To validate
the full MVP acceptance scenario from
[`docs/mvp.md`](docs/mvp.md#acceptance-scenario) with the server running:

1. Open `http://localhost:4000/` in three browser tabs/windows.
2. Join room `ABCD` in each with a different display name (e.g. Alice, Bob,
   Carol). All three should show the same participant presence.
3. Reset the round, then press buzz in the order Bob, Alice, Carol. All
   three clients should display the identical ordering B → A → C.
4. Press buzz again from Bob. The ordering should not change or duplicate.
5. Reset again; the results should clear on all three clients.
6. Close one tab. The remaining two should reflect that participant leaving.
7. Reopen a tab and rejoin the same room with the same display name. The
   rejoining client receives the current room snapshot; per
   [`docs/mvp.md`](docs/mvp.md#reconnect) this is a new participant
   identity, not a restored one, so the other clients briefly see a
   leave/join rather than a seamless reconnect.

`test/gleamroom/integration_test.gleam` automates this same scenario against
the Registry + Room actor boundary (without opening real sockets); run it
with `gleam test`.

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
