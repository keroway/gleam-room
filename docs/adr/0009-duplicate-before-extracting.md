# ADR 0009: Duplicate the buzzer's registry/transport/client for Planning Poker

- Status: Accepted
- Date: 2026-08-26

## Context

Roadmap step 3 (see `README.md`) is to build a second concrete application,
Planning Poker, on top of the architecture validated by the buzzer MVP
(`docs/mvp.md`). Step 4 is to extract reusable room/presence/lifecycle
primitives — but only after a second application demonstrates the same
requirements, per CLAUDE.md's Generalization rule.

The buzzer already has a working room registry (`registry.gleam`), WebSocket
transport (`websocket.gleam`), wire protocol (`protocol.gleam`), and browser
client (`web.gleam`). Planning Poker needs conceptually similar
infrastructure: a registry of rooms, a WebSocket transport, a wire protocol,
and a browser client. It would be possible to generalize these buzzer modules
now and have Planning Poker consume the generalized version instead of
writing its own.

Doing that now would mean designing the shared abstraction from a sample size
of one application. The buzzer's specific requirements (buzz-once-per-round,
no secrecy, no phase machine) have not yet been tested against a
requirement that actually differs — Planning Poker's vote secrecy and
change-before-reveal semantics (see `docs/planning-poker.md`'s "Differences
from the buzzer" section). Any shared abstraction built before that test
would be a guess about what varies and what doesn't.

## Decision

Planning Poker gets its own registry, transport, wire protocol, and browser
client, implemented independently of the buzzer's. No code is shared between
`registry.gleam` / `websocket.gleam` / `protocol.gleam` / `web.gleam` and
their Planning Poker equivalents.

The two applications may look similar. That similarity is the data step 4
needs; collapsing it prematurely would destroy the evidence.

## Consequences

### Positive

- Planning Poker's domain requirements (phase machine, vote secrecy) can be
  modeled directly, without contorting a buzzer-shaped abstraction to fit
  them.
- Step 4's extraction, when it happens, is grounded in two working
  implementations instead of one implementation plus a guess.
- Each application's room actor keeps its own supervised failure domain,
  consistent with ADR 0002 and ADR 0008 — no coupling is introduced between
  the buzzer's and Planning Poker's registries or supervisors.

### Negative

- A bug fixed in one application's transport/registry code (e.g. a framing
  edge case) will not automatically apply to the other; each fix must be
  ported by hand if it applies to both.
- Some genuinely identical logic (e.g. WebSocket frame validation) will exist
  in two places until step 4 extracts it.

## Future triggers for revisiting

Revisit this decision — and begin step 4's extraction — once Planning
Poker's implementation is complete enough to compare against the buzzer:
specifically, once both applications have working registries, transports,
and clients, and the actually-shared vs. actually-different pieces between
them are visible in real code rather than anticipated in a design document.
