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

以下の行範囲は commit `9670769` 時点のもの。#352 のような後続変更で個々の
節がズレることがあり、1.1 は #381・#382・#513・#524、1.2 は #531、1.3 は
#383・#554、1.4 は #385・#556、1.5 は #542・#543・#544、1.6 は #386・#424・
#555、1.7 は #568 でそのズレ(または baseline からの誤り)を確認しており、
本コミット(2026-09-17)で全節(1.1〜1.7)を再検証・更新した。#387 を受けて
`scripts/check-duplication-inventory-refs.js`(`just check`/CI から実行)が
`file:line` 引用の範囲外参照と、直前に挙げた識別子がその範囲に存在するかを
機械的に検証するようになったが、bullet内の識別子とcode行の対応関係までは
検証しないため、次に着手する人は引用箇所を開いて内容が見出しと一致するか
目視でも確認すること。

### 1.1 Registry layer — `registry.gleam` vs `poker_registry.gleam`

**抽出すべき.**

The two registries are the same actor logic with the room message type
substituted:

- `RoomId` opaque type and its accessors (`registry.gleam:16-27`,
  `poker_registry.gleam:18-28`).
- Trapped-exit classification (`exit_to_message`,
  `registry.gleam:195-205`, `poker_registry.gleam:122-132`).
- Actor `build` (trap_exits, `select_trapped_exits`, initial `State`)
  (`registry.gleam:213-243`, `poker_registry.gleam:136-162`).
- `Lookup` capacity check, room startup, and `subject_owner` monitored
  registration (`registry.gleam:280-366`, `poker_registry.gleam:191-261`).
- `RoomDown` ABA-safe dict cleanup (`registry.gleam:367-390`,
  `poker_registry.gleam:262-281`).
- `Release`/`RoomEmptyChecked` async-empty check with ABA guard
  (`registry.gleam:450-509`, `poker_registry.gleam:283-317`).
- `Health`/`RoomProbed` probe tracking with the `probe_in_flight` guard from
  #269 (`registry.gleam:391-443`, `poker_registry.gleam:318-364`).
- Public `health`/`lookup` API delegating to `call.try_call*`
  (`registry.gleam:523-554`, `poker_registry.gleam:372-397`).

The only differences are the room message type parameter and `poker `
prefixes in log strings.

Update (#391 / PR #399): this section originally assumed the two registries
have no dependency on each other. That is no longer true for the default
capacity value — `poker_registry.gleam` now does `import gleamroom/registry`
and calls `registry.get_default_max_rooms()` directly
(`poker_registry.gleam:12,99,107,170`) instead of keeping its own copy of the
default. This is a narrow, one-value dependency (default max rooms), not a
general one: the actor logic duplication described above is unchanged, and
the function-value-injection need below still applies to the rest of the
registry. It does mean step 4 should not assume "registries have zero
dependency on each other" as a starting premise.

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
(`registry.gleam:10`, `poker_registry.gleam:10`, `room.gleam:7`,
`poker.gleam:7`). This is the existing precedent for how a shared boundary
in this codebase looks; use it as the template when extracting the registry
layer in 1.1.

### 1.3 Session lifecycle inside the room actor — `room.gleam` vs `poker.gleam`

**判断保留.**

Duplicated infrastructure (not domain state machine):

- `sessions: Dict(process.Pid, List(#(String, process.Monitor)))` and the
  `select_monitors`-based `SessionDown` wiring in `start`
  (`room.gleam:277-308`, `poker.gleam:312-337`).
- `update_sessions` (register monitor on `ParticipantJoined`, demonitor +
  remove on `ParticipantLeft`) (`room.gleam:437-498`, `poker.gleam:428-481`).
- `broadcast_all` (`room.gleam:501-508`, `poker.gleam:484-491`).
- `SessionDown` handler (`room.gleam:351-412`, `poker.gleam:365-411`) and
  `ShutdownIfEmpty` handler (`room.gleam:413-424`, `poker.gleam:412-422`).
- Public `dispatch`/`shutdown_if_empty` API delegating through
  `call.try_call` (`room.gleam:572-619`, `poker.gleam:551-598`).
- `apply_join` validation shape: same `max_display_name_length = 64` /
  `max_participants = 64` constants and the same three-way branch
  (`room.gleam:109-140`, `poker.gleam:144-174`); `is_valid_display_name` is
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

Investigated (2026-09-17, #406):

- **No drift found.** Every session-lifecycle-related fix in git/issue
  history landed in both files in the same commit: the ghost-participant
  rejoin fix (#507, commit `7a874a5`) and the `SessionDown` `Error(Nil)`
  debug-log fix (#492, commit `18ffb10`) both touched `room.gleam` and
  `poker.gleam` together. No case was found where a session-lifecycle
  change landed in one room type without the corresponding update in the
  other. `room.gleam`-only commits in this area either predate
  `poker.gleam`'s creation (#287/#288, 2026-08-26) or are buzzer-domain-only
  changes with no poker equivalent to drift against (e.g. `GetState`/#240's
  atomic buzz-snapshot read, `GetBuzzSnapshot` removal/#362).
- **LOC estimate was off.** Summing the cited ranges above gives ~256 lines
  in `room.gleam` and ~225 lines in `poker.gleam`, not the "roughly 100
  lines per module" this section previously estimated (~2.5x understated).
- **Conclusion: stays 判断保留.** The absence of drift so far is evidence
  the duplication hasn't caused a *maintenance* problem yet, but it doesn't
  change the design cost argument above (a generic session-lifecycle module
  still needs an injected `event -> Option(JoinedOrLeft)` conversion that
  weakens Gleam's `case` exhaustiveness guarantee for future event
  variants). The corrected, larger LOC count is a data point in favor of
  extracting if/when someone does a dedicated design spike for the
  conversion-function approach, but on its own it doesn't resolve the
  question this section defers.

### 1.4 Wire protocol boundary — `protocol.gleam` vs `poker_protocol.gleam`

**抽出すべき（部分的）**, for the parts listed below only.

- `RoomId`/`ParticipantId` opaque types and accessors
  (`protocol.gleam:11-31`, `poker_protocol.gleam:14-34`).
- `max_field_length = 64` and `is_valid_field` (trim, 1-64 char/byte check)
  (`protocol.gleam:98-101,135-139`, `poker_protocol.gleam:198,235-239`).
- `validate_join` (room_id-first error precedence)
  (`protocol.gleam:116-133`, `poker_protocol.gleam:216-233`, including the
  comment).
- `decode_client_message`'s `json.UnableToDecode`/error branching shape and
  `ProtocolError` type (`protocol.gleam:64-86`, `poker_protocol.gleam:160-183`
  for `decode_client_message`; `ProtocolError` itself is a separate range on
  the `poker_protocol.gleam` side, `poker_protocol.gleam:143-147`).
- `encode_server_message`'s json-to-string skeleton
  (`protocol.gleam:141-146`, `poker_protocol.gleam:252-256`).

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
- `mark_active`/`record_message` (`websocket.gleam:231-241`,
  `poker_websocket.gleam:202-212`).
- `heartbeat_outcome`/`handle_heartbeat_tick` idle-timeout logic
  (`websocket.gleam:244-287`, `poker_websocket.gleam:215-255`).
- `max_text_frame_bytes = 2048` and `frame_size_outcome`
  (`websocket.gleam:295-307`, `poker_websocket.gleam:258-269`).
- `max_messages_per_heartbeat_window = 30` and `message_rate_outcome`
  (`websocket.gleam:333-360`, `poker_websocket.gleam:286-308`).
- `connection_tag` (PID-based log identifier) (`websocket.gleam:1053-1055`,
  `poker_websocket.gleam:1031-1033`, byte-identical).
- `new_participant_id` (`crypto.strong_random_bytes(16)` + base64url, with
  the same "don't leak the PID" rationale comment) (`websocket.gleam:1073-1076`,
  `poker_websocket.gleam:1036-1039`, byte-identical).

None of the above touch `ConnectionState`'s room-specific fields, so they can
move to a shared module (e.g. `gleamroom/ws_guard`) without a design change
beyond moving code.

Judgment-deferred, larger-scope duplication:

- `release_room` (`websocket.gleam:757-772`,
  `poker_websocket.gleam:740-758`) and the `with_room`/`with_join_reply`/
  `with_room_reply` family (`websocket.gleam:806-926`,
  `poker_websocket.gleam:778-858`) — these encode "how to talk to a room
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
  (`web.gleam:85-113`, `web_poker.gleam:120-148`, byte-identical).
- `log` with `MAX_LOG_ENTRIES = 200` (`web.gleam:115-125`,
  `web_poker.gleam:150-160`, byte-identical).
- `connect`'s WebSocket setup/event-registration skeleton
  (`web.gleam:273-322`, `web_poker.gleam:382-429`).
- `joinForm` submit handler (`web.gleam:324-347`, `web_poker.gleam:431-454`,
  byte-identical).
- `sendIfOpen` (`web.gleam:355-361`, `web_poker.gleam:461-469`,
  byte-identical).
- Server `error` message handling for
  `room_full`/`invalid_room_id`/`invalid_display_name`/`room_unavailable`
  (`web.gleam:229-257`, `web_poker.gleam:330-353`), plus the `room_busy`
  `else if` branch that closes the socket without clearing `lastJoin`
  (`web.gleam:257-266`, `web_poker.gleam:353-359`, added by #570). The
  poker-only `round_already_revealed`/`voter_not_joined` `else if` branch
  (`web_poker.gleam:360-375`) rolls back the optimistic `ownVote` and is
  **not** part of this duplication — buzzer has no equivalent — so it
  should not be counted when comparing the two files' `error` handling.

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
`reconnect.test.mjs` and `poker-reconnect.test.mjs` (`harness.mjs:25`'s
`startClient({ modulePath, functionName })`, `poker-reconnect.test.mjs:8`'s
`POKER_MODULE`). This is a second existing
precedent for how a shared boundary should look.

**解消済み**: the `flapWithoutJoining` helper was byte-identical between
`reconnect.test.mjs:14-24` and `poker-reconnect.test.mjs:11-21`. It has been
extracted to `test/client/harness.mjs`, and both test files now import it
from there (#298, `0323a93`).

**解消済み**: `reconnect.test.mjs` (116 lines) had two test cases not
present in `poker-reconnect.test.mjs` (108 lines) — "error events don't
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
  `None` (`poker_protocol.gleam:105-111`) — poker-only.
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
