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

ADRs 0004-0007 were **written after the fact** for decisions taken during early
development (supervision, synchronous calls, room lifetime, monitor vs link).
They record what was decided and why, including the mistakes that led to each
decision; see #89 for how the gap was found.

## Development commands

```sh
gleam build   # compile
gleam test    # run unit tests
gleam format  # format source
gleam run     # start the HTTP server (default port 4000, override with PORT)

node --test 'test/client/*.test.mjs'  # browser client reconnect tests
```

Once running, `GET http://localhost:4000/health` asks **both** the buzzer and
poker room registries whether they are responsive:

| registries | response |
|---|---|
| both answer | `200 ok buzzer_rooms=<n> buzzer_stuck=<n> poker_rooms=<n> poker_stuck=<n>` |
| one or both fail | `503 <label>: <reason>` (`;`-joined if both fail) |

Each `<reason>` is one of: `registry down` (process is gone), `registry not
responding` (alive but not answering), or `registry unavailable: <detail>`
(call failed for an unrecognized reason). `<label>` is `buzzer` or `poker`,
naming which registry produced that reason.

The failure bodies differ on purpose: a dead registry means waiting on (or
investigating) the supervisor restart, a wedged one means looking at load and
timeouts, and the third body is what `gleamroom/call.classify` falls back to
when the underlying exception doesn't match either known pattern — it carries
the raw exception text so the operator isn't left guessing. Labeling by
registry matters because buzzer and poker rooms are independent supervised
children — one being unhealthy says nothing about the other.

`stuck` counts room actors that did not answer their registry's last
lightweight probe (a `room.get_snapshot`/`poker.get_state` call fired after
each `/health` request). This probe does not fire on every single `/health`
request, though: if the previous probe round hasn't fully returned yet
(`probe_in_flight` is non-zero), the registry skips firing a new round and
`/health` returns the last completed round's `stuck` count instead (#269 — this
keeps a burst of `/health` polling from piling up unbounded probes in a room
actor's mailbox). Registry responsiveness and individual room responsiveness
are different failure modes with different remedies, so `stuck` is reported
alongside a `200` rather than turning `/health` itself into a `503` — a
wedged room doesn't mean its registry (and thus new joins) is unavailable.

`.github/workflows/ci.yml` runs `gleam format --check`, `gleam build`,
`gleam test`, and the client tests on every pull request and push to `main`.

The client tests use Node's built-in test runner and a small DOM/WebSocket
stub. **No new dependency is introduced** — there is no `package.json` and no
`node_modules`. The browser JS lives inside `web.gleam` as a string, so the
tests extract it from there rather than keeping a second copy.

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
handshake itself is rejected with `403` when the `Origin` header does not
match `Host` (CSWSH protection, see
[`docs/architecture.md`](docs/architecture.md#websocket-handshake-origin-check));
this matters when deploying behind a reverse proxy that rewrites `Host`. The
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

`test/gleamroom/routing_test.gleam` goes one layer further out: it starts the
real supervision tree with `gleamroom.start/1` and sends real HTTP requests to
`/`, `/poker`, `/health`, `/ws`, `/poker/ws`, and an unknown path — including
poker-registry health branches (registry down, timeout, stuck rooms) that get
as much coverage as the buzzer path. mist's `Connection` is opaque, so a
fabricated request cannot exercise the router — only a real server can. This is
what `gleam_httpc` is a dev-dependency for.

### Manual Planning Poker acceptance procedure

`ws://localhost:4000/poker/ws` accepts WebSocket connections speaking the
typed join/vote/reveal/reset protocol described in
[`docs/planning-poker.md`](docs/planning-poker.md#suggested-wire-protocol);
see `src/gleamroom/poker_protocol.gleam` and
`src/gleamroom/poker_websocket.gleam`. Opening `http://localhost:4000/poker`
serves the browser client (`src/gleamroom/web_poker.gleam`), the easiest way
to exercise it manually. To validate the full acceptance scenario from
[`docs/planning-poker.md`](docs/planning-poker.md#acceptance-scenario) with
the server running:

1. Open `http://localhost:4000/poker` in three browser tabs/windows.
2. Join room `PLAN` in each with a different display name (e.g. Alice, Bob,
   Carol). All three should show the same participant presence, none marked
   as having voted.
3. Cast votes from Alice and Bob. All three clients should mark Alice and Bob
   as having voted, without showing either value; Carol should not be marked
   as having voted.
4. Change Bob's vote before reveal. The marked-as-voted state is unaffected
   and no client observes the intermediate value.
5. Trigger reveal from any client. All three should display the same
   revealed votes: Alice's and Bob's final values, and Carol's explicit "no
   vote".
6. Trigger reveal again. The result should not change.
7. Reset the round; all three clients should return to `Voting` with no
   participant marked as having voted.
8. Close one tab. The remaining two should reflect that participant leaving.

`test/gleamroom/poker_integration_test.gleam` automates this same scenario
against the poker Registry + Room actor boundary (without opening real
sockets); run it with `gleam test`.

## Roadmap

1. Multiplayer buzzer prototype. ✅ Done.
2. Complete buzzer quiz MVP. ✅ Done — every requirement in
   [`docs/mvp.md`](docs/mvp.md) (room create/join, multiple WebSocket
   clients, join/leave notifications, buzzer input with server-side
   ordering, round reset, basic reconnect) is implemented and covered by
   `gleam test` (`test/gleamroom/integration_test.gleam` automates the
   [acceptance scenario](docs/mvp.md#acceptance-scenario) end to end) plus
   `test/client/*.test.mjs`.
3. Build a second application, Planning Poker. ✅ Done — every requirement in
   [`docs/planning-poker.md`](docs/planning-poker.md) (room join, per-round
   voting with the values hidden until reveal, reveal, reset, presence,
   reconnect) is implemented and covered by `gleam test`
   (`test/gleamroom/poker_integration_test.gleam` automates the
   [acceptance scenario](docs/planning-poker.md#acceptance-scenario) end to
   end) plus `test/client/*.test.mjs`. See
   [ADR 0009](docs/adr/0009-duplicate-before-extracting.md) for why it
   duplicates rather than shares the buzzer's domain code; see the CLAUDE.md
   Generalization rule below before starting step 4.
4. Extract reusable room/presence/lifecycle primitives.
5. Build a high-frequency crowd-controlled game.
6. Re-evaluate whether the extracted primitives deserve a standalone library/API.

Per CLAUDE.md's Generalization rule, do not begin step 4 from the buzzer
application alone — reusable abstractions are extracted only after step 3
demonstrates the same requirements in a second concrete application.

Start step 4 from [`docs/duplication-inventory.md`](docs/duplication-inventory.md),
which records what actually turned out to be shared vs. different between
the buzzer and Planning Poker implementations.

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
