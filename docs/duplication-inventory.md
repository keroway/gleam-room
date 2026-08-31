# Duplication inventory: buzzer vs Planning Poker

- Status: Informational (no code changes)
- Date: 2026-08-27
- Related: ADR 0009 (`docs/adr/0009-duplicate-before-extracting.md`), issue #284

## Purpose

Roadmap step 3 (Planning Poker) is done. Before step 4 (extracting reusable
room/presence/lifecycle primitives) starts, this document records what
actually turned out to be duplicated between the buzzer and Planning Poker
implementations, and what turned out to differ. ADR 0009 predicted where the
duplication would land; this inventory checks that prediction against the
real code and gives whoever picks up step 4 a starting classification.

This document does not implement any extraction. Per CLAUDE.md's
Generalization rule and ADR 0009's "Future triggers", step 4 should start
from this inventory rather than from the buzzer alone.

## How to read the classification

Each item below is marked:

- **抽出すべき** — logic is domain-independent and duplication is close to
  exact; low risk to generalize.
- **抽出すべきでない** — the two applications differ in shape here on
  purpose; forcing a shared abstraction would fight the domain.
- **判断保留** — duplication exists but generalizing it costs a real design
  change (e.g. losing Gleam's case-exhaustiveness checking, or introducing a
  function-value-injection boundary); worth a dedicated spike before step 4
  commits to an approach.

## 1. Actually duplicated

### 1.1 Registry layer — `registry.gleam` vs `poker_registry.gleam`

**抽出すべき.**

The two registries are the same actor logic with the room message type
substituted:

- `RoomId` opaque type and its accessors (`registry.gleam:16-28`,
  `poker_registry.gleam:17-28`).
- Trapped-exit classification (`exit_to_message`,
  `registry.gleam:180-190`, `poker_registry.gleam:120-130`).
- Actor `build` (trap_exits, `select_trapped_exits`, initial `State`)
  (`registry.gleam:198-228`, `poker_registry.gleam:134-160`).
- `Lookup` capacity check, room startup, and `subject_owner` monitored
  registration (`registry.gleam:252-334`, `poker_registry.gleam:178-242`).
- `RoomDown` ABA-safe dict cleanup (`registry.gleam:335-353`,
  `poker_registry.gleam:243-256`).
- `Release`/`RoomEmptyChecked` async-empty check with ABA guard
  (`registry.gleam:406-465`, `poker_registry.gleam:258-292`).
- `Health`/`RoomProbed` probe tracking with the `probe_in_flight` guard from
  #269 (`registry.gleam:354-399`, `poker_registry.gleam:293-332`).
- Public `health`/`lookup` API delegating to `call.try_call*`
  (`registry.gleam:479-510`, `poker_registry.gleam:336-365`).

The only differences are the room message type parameter and `poker `
prefixes in log strings.

What generalization would need: three function values injected per
registry instance — room startup (`fn() -> actor.StartResult(Subject(a))`),
`shutdown_if_empty` (`fn(Subject(a)) -> Bool`), and a snapshot probe
(`fn(Subject(a)) -> Result(_, Nil)`). The `start_room` path already injects a
comparable function today, so the pattern has precedent in this codebase.

Open question to resolve during extraction: whether `RoomId` should become
one shared type or stay as two independent opaque types (the current
duplication may be incidentally preventing buzzer/poker room ids from being
mixed up at the type level).

### 1.2 `call.gleam` — already shared

**対象外（既に共有済み）.** `call.try_call`, `call.try_call_classified`,
`classify`, and `Failure` live in one module and are imported by both sides
(`registry.gleam:10`, `poker_registry.gleam:10`, `room.gleam:6`,
`poker.gleam:7`). This is the existing precedent for how a shared boundary
in this codebase looks; use it as the template when extracting the registry
layer in 1.1.

### 1.3 Session lifecycle inside the room actor — `room.gleam` vs `poker.gleam`

**判断保留.**

Duplicated infrastructure (not domain state machine):

- `sessions: Dict(process.Pid, #(String, process.Monitor))` and the
  `select_monitors`-based `SessionDown` wiring in `start`
  (`room.gleam:271-302`, `poker.gleam:295-320`).
- `update_sessions` (register monitor on `ParticipantJoined`, demonitor +
  remove on `ParticipantLeft`) (`room.gleam:412-459`, `poker.gleam:381-423`).
- `broadcast_all` (`room.gleam:462-469`, `poker.gleam:426-433`).
- `SessionDown` handler (`room.gleam:349-387`, `poker.gleam:344-364`) and
  `ShutdownIfEmpty` handler (`room.gleam:388-399`, `poker.gleam:365-376`).
- Public `dispatch`/`shutdown_if_empty` API delegating through
  `call.try_call` (`room.gleam:533-592`, `poker.gleam:493-526`).
- `apply_join` validation shape: same `max_display_name_length = 64` /
  `max_participants = 64` constants and the same three-way branch
  (`room.gleam:108-139`, `poker.gleam:144-174`); `is_valid_display_name` is
  identical.

Why this is deferred rather than classified "抽出すべき": generalizing it
means expressing "this event is a join/leave" independently of each
application's full event type. Gleam's `case` exhaustiveness check today
guarantees that adding a new event variant to `RoomEvent`/`PokerEvent` forces
every consumer to handle it. A generic session-lifecycle module would need
either a conversion function (`event -> Option(JoinedOrLeft)`) injected per
application, or some other indirection — either way, that guarantee weakens
for whoever adds the next event variant.

To resolve before committing to an approach:

- Check whether an event was ever added to one room type without the
  corresponding session-lifecycle update landing in the other (git/issue
  history) — evidence that the current duplication is already causing
  drift, not just LOC duplication.
- Estimate the actual line count this would remove (roughly 100 lines per
  module today) against the design cost of the injected conversion.

### 1.4 Wire protocol boundary — `protocol.gleam` vs `poker_protocol.gleam`

**抽出すべき（部分的）**, for the parts listed below only.

- `RoomId`/`ParticipantId` opaque types and accessors
  (`protocol.gleam:11-31`, `poker_protocol.gleam:14-34`).
- `max_field_length = 64` and `is_valid_field` (trim, 1-64 char/byte check)
  (`protocol.gleam:98-101,135-139`, `poker_protocol.gleam:187,224-228`).
- `validate_join` (room_id-first error precedence)
  (`protocol.gleam:116-133`, `poker_protocol.gleam:205-222`, including the
  comment).
- `decode_client_message`'s `json.UnableToDecode`/error branching shape and
  `ProtocolError` type (`protocol.gleam:64-86`, `poker_protocol.gleam:132-171`).
- `encode_server_message`'s json-to-string skeleton
  (`protocol.gleam:141-146`, `poker_protocol.gleam:241-246`).

This is pure string validation with no domain knowledge attached, which
makes it the lowest-risk extraction candidate alongside the registry layer.

**抽出すべきでない** for `ClientMessage`/`ServerMessage` variants themselves
(`Join`/`Buzz`/`Reset` vs `Join`/`Vote`/`Reveal`/`Reset`), `Card`, and
`RoundPhase` — these are the wire-level expression of each application's
actual domain and are the reason the two protocols exist separately.

### 1.5 WebSocket transport — `websocket.gleam` vs `poker_websocket.gleam`

**抽出すべき** for the domain-independent transport-guard functions;
**判断保留** for the room-interaction skeleton.

Domain-independent and duplicated near-exactly (already commented in the
source as "same value, same reason"):

- `heartbeat_interval_ms = 30_000` (`websocket.gleam:56`,
  `poker_websocket.gleam:47`).
- `origin_allowed`/`origin_header_allowed` (`websocket.gleam:100-119`,
  `poker_websocket.gleam:85-102`).
- `on_init` heartbeat subject + `send_after` scheduling
  (`websocket.gleam:121-138`, `poker_websocket.gleam:104-124`).
- `mark_active`/`record_message` (`websocket.gleam:225-235`,
  `poker_websocket.gleam:197-202`).
- `heartbeat_outcome`/`handle_heartbeat_tick` idle-timeout logic
  (`websocket.gleam:238-281`, `poker_websocket.gleam:224-238`).
- `max_text_frame_bytes = 2048` and `frame_size_outcome`
  (`websocket.gleam:283-304`, `poker_websocket.gleam:252-263`).
- `max_messages_per_heartbeat_window = 30` and `message_rate_outcome`
  (`websocket.gleam:314-348`, `poker_websocket.gleam:275-294`).
- `connection_tag` (PID-based log identifier) (`websocket.gleam:936-938`,
  `poker_websocket.gleam:924-926`, byte-identical).
- `new_participant_id` (`crypto.strong_random_bytes(16)` + base64url, with
  the same "don't leak the PID" rationale comment) (`websocket.gleam:940-959`,
  `poker_websocket.gleam:929-931`, byte-identical).

None of the above touch `ConnectionState`'s room-specific fields, so they can
move to a shared module (e.g. `gleamroom/ws_guard`) without a design change
beyond moving code.

Judgment-deferred, larger-scope duplication:

- `release_room` (`websocket.gleam:683-698`,
  `poker_websocket.gleam` near 665) and the `with_room`/`with_join_reply`/
  `with_room_reply` family (`websocket.gleam:722-822`,
  `poker_websocket.gleam:702-796`) — these encode "how to talk to a room
  actor" but reference the concrete `room.Message`/`poker.Message`,
  `room.ParticipantId`/room event subject types via `ConnectionState`.
  Generalizing this needs a room-operations interface (dispatch function,
  leave-command constructor, `shutdown_if_empty`) injected as function
  values, similar in shape to the registry work in 1.1 but larger because it
  spans the `mist.websocket` callback shape (`on_init`/`on_close`/
  `handle_message`). Treat as a follow-up spike, not bundled with the
  low-risk transport-guard extraction above.

**抽出すべきでない**: `handle_join`'s constructed `State` payload shape,
`handle_buzz`/`handle_reset` vs `handle_vote`/`handle_reveal`/`handle_reset`
themselves, `room_event_to_server_message`'s variant mapping, and
`VoteRejectReason`'s `RoundAlreadyRevealed` (no buzzer equivalent) — these
are the actual command/event surface of each application.

### 1.6 Embedded browser client JS — `web.gleam` vs `web_poker.gleam`

**抽出すべき, as a separate concern from 1.1–1.5** — this duplication is not
expressible in Gleam's type system since it is duplicated JS string
literals, not Gleam code.

- `cancelReconnect`/`scheduleReconnect`, including the shared
  `RECONNECT_DELAY_MS = 1500` / `MAX_RECONNECT_ATTEMPTS = 5` constants
  (`web.gleam:85-113`, `web_poker.gleam:118-146`, byte-identical).
- `log` with `MAX_LOG_ENTRIES = 200` (`web.gleam:115-125`,
  `web_poker.gleam:148-158`, byte-identical).
- `connect`'s WebSocket setup/event-registration skeleton
  (`web.gleam:231-274`, `web_poker.gleam:285-325`).
- `joinForm` submit handler (`web.gleam:276-290`, `web_poker.gleam:327-341`,
  byte-identical).
- `sendIfOpen` (`web.gleam:292-298`, `web_poker.gleam:343-349`,
  byte-identical).
- Server `error` message handling for
  `room_full`/`invalid_room_id`/`invalid_display_name`/`room_unavailable`
  (`web.gleam:199-225`, `web_poker.gleam:258-279`).

Extracting this conflicts with the current "single static HTML document, no
build tooling" design noted in both files' headers (`web.gleam:1-6`,
`web_poker.gleam:1-8`); any extraction here needs its own decision about how
a shared JS snippet gets assembled into two Gleam string-embedded documents
without introducing a build step. Flag this as a distinct sub-problem from
the Gleam-side extraction in step 4, not the same mechanism.

**抽出すべきでない**: card-selection UI (`cards` array,
`updateCardButtons`), vote/reveal rendering (`renderVotes`, `has_voted`
display), and phase-driven UI state (`voting`/`revealed`) — Planning
Poker-specific, no buzzer equivalent.

### 1.7 Client-side tests — `test/client/*.mjs`

**対象外（既に共有済み）** for `extract.mjs`/`harness.mjs` — already
parameterized via `{modulePath, functionName}` and reused from both
`reconnect.test.mjs` and `poker-reconnect.test.mjs` (`harness.mjs:8`,
`poker-reconnect.test.mjs:8`'s `POKER_MODULE`). This is a second existing
precedent for how a shared boundary should look.

**解消済み**: the `flapWithoutJoining` helper was byte-identical between
`reconnect.test.mjs:14-24` and `poker-reconnect.test.mjs:11-21`. It has been
extracted to `test/client/harness.mjs`, and both test files now import it
from there (#298, `0323a93`).

**解消済み**: `reconnect.test.mjs` (124 lines) had two test cases not
present in `poker-reconnect.test.mjs` (77 lines) — "error events don't
throw" and "no pending reconnect timer while connected". This coverage gap
has been backfilled; `poker-reconnect.test.mjs` now has matching test cases
for both (#295).

## 2. Actually not duplicated

- **Domain state machine itself.** `room.gleam`'s `apply_buzz` (first-buzz-
  wins, `AlreadyBuzzed`) and `poker.gleam`'s `apply_vote`/`apply_reveal`
  (votes are overwritable pre-reveal, phase-gated) are different state
  machines. `RoomState` holds `participants` + `buzzes`; `PokerState` holds
  `participants` + `votes: Dict` + `phase: RoundPhase` (`poker.gleam:55-61`).
- **Wire message types.** `ClientMessage`'s `Buzz`/`Reset` vs
  `Vote(Card)`/`Reveal`/`Reset`; `ServerMessage`'s
  `State(participants, buzzes)` vs
  `State(phase, participants: List(ParticipantView))`.
- **The phase concept.** `RoundPhase` (`Voting`/`Revealed`) has no buzzer
  counterpart, nor does `VoteRejectReason`'s `RoundAlreadyRevealed`.
- **The vote-secrecy design.** `ParticipantView`'s `has_voted: Bool` (no
  vote value exposed, `poker_protocol.gleam:95-100`) and the
  `VoteRegistered` event's "deliberately carries no vote value" comment
  (`poker.gleam:106-109`) — this asymmetry is the whole point of Planning
  Poker and has no buzzer equivalent to extract against.
- **`RevealedVote.value: Option(Card)`** including non-voters as explicit
  `None` (`poker_protocol.gleam:102-104`) — poker-only.
- **`Card` type and its wire string mapping**
  (`poker_protocol.gleam:39-81`) — poker-only, 10 variants.

## 3. Summary table

| Item | Verdict |
|---|---|
| Registry layer (`registry.gleam`/`poker_registry.gleam`) | 抽出すべき |
| `call.gleam` | 対象外（既に共有） |
| Room actor session lifecycle (`update_sessions`/`broadcast_all`/`SessionDown`/`ShutdownIfEmpty`) | 判断保留 |
| Room actor domain transitions (`apply_*`, state types) | 抽出すべきでない |
| Protocol: `RoomId`/`ParticipantId`/`max_field_length`/`validate_join` | 抽出すべき |
| Protocol: `ClientMessage`/`ServerMessage`/`Card`/`RoundPhase` | 抽出すべきでない |
| WebSocket: heartbeat/frame size/rate limit/origin/`connection_tag`/`new_participant_id` | 抽出すべき |
| WebSocket: `release_room`/`with_room*` room-interaction skeleton | 判断保留 |
| Embedded JS: reconnect/log/`sendIfOpen`/error handling | 抽出すべき（別カテゴリとして扱う） |
| Embedded JS: card/vote UI | 抽出すべきでない |
| `test/client/extract.mjs`/`harness.mjs` | 対象外（既に共有） |
| `test/client`: `flapWithoutJoining` helper | 解消済み（#298） |
| `test/client`: reconnect test coverage asymmetry | 解消済み（#295） |

Whoever starts step 4 should read this table alongside the cited line
ranges in section 1 before deciding what to extract first. The lowest-risk,
highest-confidence starting points are the registry layer (1.1), the
protocol validation helpers (1.4), and the transport guard functions (1.5);
the session-lifecycle and room-interaction-skeleton items are judgment
calls that likely deserve their own spike before committing to a shared
abstraction shape.
