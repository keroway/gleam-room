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

Planning Poker initially got its own registry, transport, wire protocol, and
browser client, implemented independently of the buzzer's, with no code shared
between `registry.gleam` / `websocket.gleam` / `protocol.gleam` / `web.gleam`
and their Planning Poker equivalents. This was the decision at the time of
writing; the Update sections below record what was extracted afterwards.

The two applications may look similar. That similarity is the data step 4
needs; collapsing it prematurely would destroy the evidence.

Update (#391 / PR #399): one narrow exception existed. `poker_registry.gleam`
imports `gleamroom/registry` and calls `registry.get_default_max_rooms()`
directly instead of keeping its own copy of the default max-rooms value
(`poker_registry.gleam:79,87,127`). This was a one-value dependency on the
default capacity, not a general one. See `docs/duplication-inventory.md` §1.1
for the full analysis.

Update (#586 / #587 / #588 / #589): once both applications were working, the
shared pieces were extracted and the original no-sharing statement above no
longer describes the code. Both apps now share:

- `room_registry.gleam` — the registries' actor logic (#586);
- `wire.gleam` — wire-boundary parsing helpers used by `protocol.gleam` and
  `poker_protocol.gleam` (#587);
- `ws_guard.gleam` — transport-level frame guards used by `websocket.gleam`
  and `poker_websocket.gleam` (#588);
- `client_js.gleam` — the `shared` browser JS used by `web.gleam` and
  `web_poker.gleam` (#589).

Still app-specific: domain modules and phase machines, wire message
vocabularies, the `ConnectionEvent`/registry types, and the per-app HTML and
client logic. No general room framework has been extracted; see CLAUDE.md's
Generalization rule and `docs/duplication-inventory.md` for the current
boundary.

## Consequences

### Positive

- Planning Poker's domain requirements (phase machine, vote secrecy) can be
  modeled directly, without contorting a buzzer-shaped abstraction to fit
  them.
- Step 4's extraction, when it happens, is grounded in two working
  implementations instead of one implementation plus a guess.
- Each application's room actor keeps its own supervised failure domain,
  consistent with ADR 0002 and ADR 0008 — no coupling is introduced between
  the buzzer's and Planning Poker's registries or supervisors beyond the
  shared modules listed in the Updates above (which share code, not actors).

### Negative

- While the code was independent, a bug fixed in one application's
  transport/registry code (e.g. a framing edge case) did not automatically
  apply to the other and had to be ported by hand. This no longer holds for
  the extracted modules (`room_registry`, `wire`, `ws_guard`, `client_js`):
  a fix there applies to both apps. Only the app-specific parts listed in the
  Update above still need per-app handling.
- Identical logic (e.g. WebSocket frame validation) existed in two places
  until #586〜#589 extracted it.

## Future triggers for revisiting

The original trigger — both applications having working registries,
transports, and clients — has been met, and #586〜#589 acted on it. Revisit
further extraction (a general room framework) only on its own merits, per
CLAUDE.md's Generalization rule, once the remaining app-specific pieces are
shown to share requirements in real code.
