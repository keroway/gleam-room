import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// Opaque so callers cannot construct a `ParticipantId` except through
/// `participant_id`, mirroring `room.gleam`'s ParticipantId (ADR 0009: Planning
/// Poker duplicates rather than shares the buzzer's domain types).
pub opaque type ParticipantId {
  ParticipantId(String)
}

pub fn participant_id(value: String) -> ParticipantId {
  ParticipantId(value)
}

pub fn participant_id_to_string(id: ParticipantId) -> String {
  let ParticipantId(value) = id
  value
}

pub type Participant {
  Participant(id: ParticipantId, display_name: String)
}

/// The fixed card set from `docs/planning-poker.md`. A custom type (rather
/// than passing the wire strings through) so an invalid card can never reach
/// the domain layer — the wire boundary must reject anything that does not
/// decode to one of these before a `Vote` command is ever constructed.
pub type Card {
  Zero
  One
  Two
  Three
  Five
  Eight
  Thirteen
  TwentyOne
  QuestionMark
  Coffee
}

pub type RoundPhase {
  Voting
  Revealed
}

/// `votes` only holds entries for participants who have cast a vote in the
/// current round. Reveal treats a missing entry as "no vote" rather than
/// requiring every participant to have one.
pub type PokerState {
  PokerState(
    participants: List(Participant),
    votes: Dict(ParticipantId, Card),
    phase: RoundPhase,
  )
}

pub fn new_state() -> PokerState {
  PokerState(participants: [], votes: dict.new(), phase: Voting)
}

pub type PokerCommand {
  Join(id: ParticipantId, display_name: String)
  Leave(id: ParticipantId)
  Vote(id: ParticipantId, card: Card)
  Reveal
  ResetRound
}

pub type JoinRejectReason {
  AlreadyJoined
  InvalidDisplayName
  RoomFull
}

pub type LeaveRejectReason {
  NotJoined
}

pub type VoteRejectReason {
  VoterNotJoined
  RoundAlreadyRevealed
}

/// One participant's revealed vote. `value` is `None` for a participant who
/// never cast a vote this round, represented explicitly rather than omitted
/// from the list (see `docs/planning-poker.md`'s wire protocol section).
pub type RevealedVote {
  RevealedVote(
    participant_id: ParticipantId,
    display_name: String,
    value: Option(Card),
  )
}

pub type PokerEvent {
  ParticipantJoined(Participant)
  JoinRejected(id: ParticipantId, reason: JoinRejectReason)
  ParticipantLeft(ParticipantId)
  LeaveRejected(id: ParticipantId, reason: LeaveRejectReason)
  /// Deliberately carries no vote value (per docs/planning-poker.md's "the
  /// deliberate asymmetry"): only the fact that `id` has voted is public
  /// before reveal.
  VoteRegistered(id: ParticipantId)
  VoteRejected(id: ParticipantId, reason: VoteRejectReason)
  /// Named `RoundRevealed` rather than `Revealed` to avoid colliding with
  /// `RoundPhase`'s `Revealed` constructor in this module's flat namespace;
  /// matches the wire protocol's `round_revealed` message type.
  RoundRevealed(votes: List(RevealedVote))
  RoundReset
}

/// Pure state transition: given the current state and a command, returns the
/// resulting state and the single event produced. Kept free of any actor or
/// transport concern so join/vote/reveal semantics are unit-testable without
/// starting a process.
pub fn apply_command(
  state: PokerState,
  command: PokerCommand,
) -> #(PokerState, PokerEvent) {
  case command {
    Join(id, display_name) -> apply_join(state, id, display_name)
    Leave(id) -> apply_leave(state, id)
    Vote(id, card) -> apply_vote(state, id, card)
    Reveal -> apply_reveal(state)
    ResetRound -> apply_reset_round(state)
  }
}

/// Same ceiling as `room.gleam`'s `max_display_name_length`, kept as a
/// domain-level last line of defense independent of the WebSocket boundary's
/// own limit.
const max_display_name_length = 64

/// Same ceiling as `room.gleam`'s `max_participants`, for the same reason:
/// bounding per-round broadcast cost.
const max_participants = 64

fn apply_join(
  state: PokerState,
  id: ParticipantId,
  display_name: String,
) -> #(PokerState, PokerEvent) {
  case
    find_participant(state, id),
    is_valid_display_name(display_name),
    list.length(state.participants) >= max_participants
  {
    _, False, _ -> #(state, JoinRejected(id, InvalidDisplayName))
    // Unreachable from the current websocket layer: each connection gets a
    // fresh ParticipantId and dispatches Join at most once, so no live
    // connection can ever collide with an id already in `participants`.
    // Kept as a defensive branch, mirroring `room.gleam`'s `apply_join`.
    Ok(_), True, _ -> #(state, JoinRejected(id, AlreadyJoined))
    Error(Nil), True, True -> #(state, JoinRejected(id, RoomFull))
    Error(Nil), True, False -> {
      let participant = Participant(id, display_name)
      let next =
        PokerState(..state, participants: [participant, ..state.participants])
      #(next, ParticipantJoined(participant))
    }
  }
}

fn is_valid_display_name(display_name: String) -> Bool {
  string.trim(display_name) != ""
  && string.length(display_name) <= max_display_name_length
  && string.byte_size(display_name) <= max_display_name_length
}

fn apply_leave(
  state: PokerState,
  id: ParticipantId,
) -> #(PokerState, PokerEvent) {
  case find_participant(state, id) {
    // Unreachable from the current websocket layer, mirroring
    // `room.gleam`'s `apply_leave`. Kept as a defensive branch.
    Error(Nil) -> #(state, LeaveRejected(id, NotJoined))
    Ok(_) -> {
      let remaining = list.filter(state.participants, fn(p) { p.id != id })
      // Drop the departed participant's vote too: reveal only ever reports
      // votes for currently present participants (see `apply_reveal`), so a
      // stale entry would just leak until the next reset.
      let next =
        PokerState(
          ..state,
          participants: remaining,
          votes: dict.delete(state.votes, id),
        )
      #(next, ParticipantLeft(id))
    }
  }
}

/// A participant may cast a vote any number of times while `Voting`; each
/// call overwrites the previous value, so only the last vote is kept.
fn apply_vote(
  state: PokerState,
  id: ParticipantId,
  card: Card,
) -> #(PokerState, PokerEvent) {
  case find_participant(state, id), state.phase {
    // Unreachable from the current websocket layer, mirroring
    // `room.gleam`'s `apply_buzz`. Kept as a defensive branch.
    Error(Nil), _ -> #(state, VoteRejected(id, VoterNotJoined))
    Ok(_), Revealed -> #(state, VoteRejected(id, RoundAlreadyRevealed))
    Ok(_), Voting -> {
      let next = PokerState(..state, votes: dict.insert(state.votes, id, card))
      #(next, VoteRegistered(id))
    }
  }
}

/// Idempotent while already `Revealed`: since neither `votes` nor
/// `participants` change here, recomputing the revealed list on a repeat
/// request naturally returns the same result without any extra branching.
fn apply_reveal(state: PokerState) -> #(PokerState, PokerEvent) {
  let next = PokerState(..state, phase: Revealed)
  let votes =
    state.participants
    |> list.reverse
    |> list.map(fn(participant) {
      RevealedVote(
        participant.id,
        participant.display_name,
        dict.get(state.votes, participant.id) |> option.from_result,
      )
    })
  #(next, RoundRevealed(votes))
}

fn apply_reset_round(state: PokerState) -> #(PokerState, PokerEvent) {
  #(PokerState(..state, votes: dict.new(), phase: Voting), RoundReset)
}

fn find_participant(
  state: PokerState,
  id: ParticipantId,
) -> Result(Participant, Nil) {
  list.find(state.participants, fn(p) { p.id == id })
}

/// The current participant list, oldest (first joined) first, suitable for a
/// transport adapter to turn into a state snapshot for a newly joined or
/// reconnecting client.
pub fn snapshot(state: PokerState) -> List(Participant) {
  list.reverse(state.participants)
}

/// Whether `id` has cast a vote in the current round, without exposing the
/// value — the presence-only signal a `state`/`vote_cast` wire message needs
/// before reveal.
pub fn has_voted(state: PokerState, id: ParticipantId) -> Bool {
  dict.has_key(state.votes, id)
}
