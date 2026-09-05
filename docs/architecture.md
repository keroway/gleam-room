# Architecture

## Purpose

The initial architecture exists to validate a simple question: can Gleam/BEAM provide a clean model for many concurrent, isolated, real-time rooms over WebSocket?

The architecture therefore favors explicit actor boundaries and a thin transport layer over feature breadth.

## Initial component model

```text
+-------------------+
| Browser client A  |
+-------------------+
          |
          | WebSocket
          v
+-------------------+
| HTTP / WS server  |
| (Mist)            |
+-------------------+
          |
          | typed command/event translation
          v
+-------------------+
| Room Registry     |
+-------------------+
          |
          | route by RoomId
          v
+-------------------+       +-------------------+
| Room Actor A      |  ...  | Room Actor N      |
+-------------------+       +-------------------+
          |
          | owns room state and event ordering
          v
+-------------------+
| Participants /    |
| subscribers       |
+-------------------+
```

## Responsibility boundaries

### Transport layer

Responsible for:

- Serving the minimal browser client.
- Accepting WebSocket upgrades.
- Decoding client messages.
- Encoding server messages.
- Mapping connection lifecycle events to domain commands.

Not responsible for:

- Deciding buzzer order.
- Owning room state.
- Implementing game rules.

#### WebSocket handshake origin check

Before upgrading a connection, the transport layer rejects the handshake with
`403` unless the request's `Origin` header matches its `Host` header. This
guards against Cross-Site WebSocket Hijacking (CSWSH); see ADR/issue #124 and
`origin_allowed` in `src/gleamroom/websocket.gleam` and
`src/gleamroom/poker_websocket.gleam`.

This means a deployment behind a reverse proxy must ensure the `Host` header
the Gleam process sees still matches the browser's `Origin` (for example by
having the proxy forward the original `Host` rather than rewriting it to an
internal upstream address). If it does not, every WebSocket upgrade is
rejected with `403` and no further protocol-level error code applies — the
connection never reaches the wire protocol described in
[`docs/mvp.md`](mvp.md#suggested-wire-protocol) or
[`docs/planning-poker.md`](planning-poker.md#suggested-wire-protocol).

#### Abuse controls

Beyond the origin check above, the transport and room layers already enforce
basic abuse limits (see the error code table in
[`docs/mvp.md`](mvp.md#suggested-wire-protocol)):

- A per-connection text frame size cap (`max_text_frame_bytes` in
  `src/gleamroom/websocket.gleam`), returning `frame_too_large`.
- A per-connection message rate limit within a heartbeat window
  (`max_messages_per_heartbeat_window` in `src/gleamroom/websocket.gleam`),
  returning `rate_limited`.
- A per-room participant cap (`max_participants` in `src/gleamroom/room.gleam`
  and `src/gleamroom/poker.gleam`).

These are deliberately simple, in-process limits, not the broader compliance
features (e.g. audit logging, IP-based blocking, regulatory certifications)
listed as deferred below.

### Room registry

Responsible for:

- Looking up an active room by `RoomId`.
- Starting a room process when required.
- Avoiding accidental duplicate room processes for the same logical room.
- Providing the transport layer with a room process handle/reference.

The registry is an implementation detail for the MVP, not yet a reusable framework API.

### Room actor

Responsible for the authoritative state of one active room:

- Participant membership/presence.
- Current round state.
- Buzzer ordering.
- Reset transitions.
- Producing domain events to subscribers.

One room should be isolated from failures/state in other rooms.

## Domain model direction

Names may evolve during implementation, but the model should stay explicit and typed.

```text
RoomId
ParticipantId
Participant
RoomState
RoundState
RoomCommand
RoomEvent
```

Example command concepts:

```text
Join(participant)
Leave(participant_id)
Buzz(participant_id)
ResetRound
```

Example event concepts:

```text
ParticipantJoined(...)
ParticipantLeft(...)
BuzzAccepted(...)
RoundReset
StateSnapshot(...)
```

Wire-format types and domain types should not be treated as the same abstraction.

## Ordering semantics

For the buzzer MVP, the server is authoritative for ordering. A client's wall-clock timestamp must not determine the winner because client clocks are not trusted or synchronized.

The room actor processes accepted buzzer commands sequentially and assigns an authoritative order based on arrival sequence. The current implementation does not attach or display any relative timing (`room.BuzzResult` and `protocol.BuzzResult` carry no time field). If relative timing display is added later, it should use a server-side monotonic time source rather than client wall-clock time, since client clocks are not trusted or synchronized.

The MVP does not promise geographically fair competitive timing. Network latency is an explicit limitation of the first version.

## Supervision and lifecycle

The actual BEAM model, matching child add order in `gleamroom.gleam`:

```text
Application supervisor (OneForOne)
  |
  +-- Room registry (buzzer)
  +-- Poker room registry
  +-- Web server
```

Both registries are registered under a name; the web server resolves the buzzer registry through `process.named_subject` on every send rather than capturing a subject at startup. This means a registry restart needs no cooperation from the web server: the next message sent through the named subject reaches the new registry process automatically. `OneForOne` lets each registry and the web server restart independently, so a crash in one does not force-close every live WebSocket connection across every room (see ADR 0008; this replaced an earlier `RestForOne` choice recorded in ADR 0004).

The poker registry is a separate module (`poker_registry.gleam`) duplicating the buzzer registry's structure rather than sharing it, per ADR 0009 — Planning Poker demonstrates whether the shared shape is real before step 4 extracts it. `/health` queries both registries independently and reports `503` if either fails, labeling which one (see README.md for the response format).

Active room processes are not supervised children of the registry. The registry starts each room actor directly (linking to it) and traps its exit signal, then removes the dead entry from its own state; a new room actor is only started lazily on the next lookup. This means room crashes are not automatically restarted by the supervision tree — recovery is registry-driven and deferred.

Exact supervision mechanics should follow the capabilities and idioms of the selected Gleam/OTP packages rather than forcing an abstraction before implementation.

Rooms are ephemeral in the MVP. If a room process terminates and no persistence layer exists, its state is lost by design.

## Frontend

The first UI should be intentionally small and framework-free unless implementation evidence shows that this is counterproductive.

Expected capabilities:

- Enter room identifier and display name.
- Connect to a room.
- Show participants/basic status.
- Large buzzer button.
- Display ordered buzzer results.
- Host/reset control can initially be simplified; authentication is out of scope.

## Persistence

There is no database in the MVP.

Reasons:

- The first experiment is about real-time process/state modeling.
- Ephemeral room state makes lifecycle behavior visible.
- A database would add operational and modeling concerns before persistence requirements exist.

Persistence may later be introduced for durable room metadata, history, or reconnect semantics only after concrete requirements emerge.

## Deferred architecture topics

The following are explicitly deferred:

- Horizontal multi-node routing.
- Distributed Erlang/BEAM clustering.
- External pub/sub or Redis.
- CRDT-based shared documents.
- P2P/WebRTC data channels.
- End-to-end encryption.
- Authentication/authorization.
- Durable event logs.
- Compliance features (e.g. audit logging, IP-based blocking, regulatory
  certifications). See "Abuse controls" above for the basic limits that are
  already implemented.

Each should be introduced through a separate design decision when a concrete product requirement justifies it.
