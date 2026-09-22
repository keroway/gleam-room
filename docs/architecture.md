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
`403` if the request carries an `Origin` header that does not match its `Host`
header. This guards against Cross-Site WebSocket Hijacking (CSWSH); see
ADR/issue #124 and `origin_allowed` in `src/gleamroom/websocket.gleam` and
`src/gleamroom/poker_websocket.gleam`.

The match compares **hostname only** — `uri.parse(origin).host` never carries
a scheme or port, so `Origin: http://example.com:4000` is accepted against
`Host: example.com` regardless of scheme or port (see
`origin_header_allowed_matching_origin_with_port_is_allowed_test` in
`test/gleamroom/websocket_test.gleam`). On a host that serves multiple
origins on different ports or schemes, this does not fully prevent CSWSH from
another origin sharing the same hostname (#530).

Requests with **no** `Origin` header are allowed through, not rejected.
Browsers always send `Origin`, but non-browser clients (CLI tools, custom
clients) often do not, and the MVP has no authentication layer to justify
distinguishing them — this is an intentional design decision left open in
#124, fixed by the `origin_header_allowed_missing_origin_is_allowed` test in
`test/gleamroom/websocket_test.gleam` and `poker_websocket_test.gleam`.

This means a deployment behind a reverse proxy must ensure the `Host` header
the Gleam process sees still matches the browser's `Origin` (for example by
having the proxy forward the original `Host` rather than rewriting it to an
internal upstream address). If it does not, every WebSocket upgrade is
rejected with `403` and no further protocol-level error code applies — the
connection never reaches the wire protocol described in
[`docs/mvp.md`](mvp.md#suggested-wire-protocol) or
[`docs/planning-poker.md`](planning-poker.md#suggested-wire-protocol).

#### HTTP response security headers

HTML responses (the join UI for the buzzer and Planning Poker) set
`x-content-type-options: nosniff` to prevent browsers from MIME-sniffing the
response body into an unintended content type. This is a low-cost header
with no functional downside, so there is no reason not to set it.

A `Content-Security-Policy` header is **not** set. `web.gleam` and
`web_poker.gleam` embed their JavaScript/CSS inline (`<style>`/`<script>`
directly in the served HTML, per the "single static HTML document, no build
tooling" design), so a meaningful CSP would need a nonce or hash-based
`script-src`/`style-src` design — deliberately out of MVP scope (#550).
Revisit if this repository ever grows a build step for the embedded client
code (see `docs/duplication-inventory.md`'s §1.6 on the embedded-JS
duplication for related context).

#### Abuse controls

Beyond the origin check above, the transport and room layers already enforce
basic abuse limits (see the error code table in
[`docs/mvp.md`](mvp.md#suggested-wire-protocol)):

- A per-connection text frame size cap (`max_text_frame_bytes` in
  `src/gleamroom/websocket.gleam` and `src/gleamroom/poker_websocket.gleam`),
  returning `frame_too_large`.
- A per-connection message rate limit within a heartbeat window
  (`max_messages_per_heartbeat_window` in `src/gleamroom/websocket.gleam`
  and `src/gleamroom/poker_websocket.gleam`), returning `rate_limited`.
- A per-room participant cap (`max_participants` in `src/gleamroom/room.gleam`
  and `src/gleamroom/poker.gleam`).
- A room count cap per registry (`MAX_ROOMS`, default 1000). The buzzer and
  poker registries are independent processes (see "Room registry" below) and
  each enforces this cap on its own room count, so the process-wide effective
  ceiling is up to 2x `MAX_ROOMS`.

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

The poker registry is a separate module (`poker_registry.gleam`) duplicating the buzzer registry's structure rather than sharing it, per ADR 0009 — Planning Poker demonstrates whether the shared shape is real before step 4 extracts it. One narrow exception exists: `poker_registry.gleam` calls `registry.get_default_max_rooms()` directly instead of keeping its own copy of the default max-rooms value (see `docs/duplication-inventory.md` §1.1). `/health` queries both registries independently and reports `503` if either fails, labeling which one (see README.md for the response format).

Active room processes are not supervised children of the registry. The registry starts each room actor directly (linking to it) and traps its exit signal, then removes the dead entry from its own state; a new room actor is only started lazily on the next lookup. This means room crashes are not automatically restarted by the supervision tree — recovery is registry-driven and deferred.

The link is bidirectional and only the registry traps exits, so the reverse also holds: a registry crash kills every room actor it started, not just its own bookkeeping. `OneForOne` (above) keeps a registry crash from force-closing unrelated WebSocket *connections*, but it does not protect room *state* — every active room's participants/votes/buzzes are lost and clients reconnect into brand-new, empty rooms (see ADR 0008's "Known limitation", #561).

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
