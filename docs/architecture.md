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

The intended BEAM model is:

```text
Application supervisor
  |
  +-- Web server
  +-- Room registry
       |
       +-- active room processes (directly or via an appropriate dynamic lifecycle mechanism)
```

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
- Production abuse controls and compliance features.

Each should be introduced through a separate design decision when a concrete product requirement justifies it.
