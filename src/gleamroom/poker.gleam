import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string
import gleamroom/call
import logging

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

pub type Message {
  Dispatch(
    command: PokerCommand,
    session: Subject(PokerEvent),
    reply_to: Subject(PokerEvent),
  )
  GetState(reply_to: Subject(PokerState))
  /// 自分が無人なら終了する。`room.gleam`'s `ShutdownIfEmpty` と同じ理由
  /// （#36 / #91）で、判定と停止を 1 メッセージに閉じてレースを防ぐ。
  ShutdownIfEmpty(reply_to: Subject(Bool))
  /// 参加者の接続プロセスが死んだときに届く。`room.gleam`'s `SessionDown`
  /// と同じ理由（#56 / #35）: 接続が死んだのに `Leave` が届かない経路が
  /// 複数あるため、監視で不変条件として塞ぐ。
  SessionDown(pid: process.Pid)
}

/// The actor's own state: the domain `PokerState` plus the set of connected
/// sessions to notify when membership changes. Kept separate from
/// `PokerState` so the pure state transitions stay testable without a
/// process or a notion of "subscriber".
type ActorState {
  ActorState(
    poker: PokerState,
    subscribers: Dict(String, Subject(PokerEvent)),
    /// 監視中の接続プロセス pid → (ParticipantId の文字列表現, Monitor)。
    sessions: Dict(process.Pid, #(String, process.Monitor)),
  )
}

/// Starts one isolated poker room actor with empty state. Each call produces
/// an independent process with its own mailbox, so multiple rooms never
/// share participant state (mirrors `room.gleam`'s `start`, ADR 0002 /
/// ADR 0009).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    // **monitor を使う。link ではない**（`room.gleam`'s `start` と同じ理由、
    // #69）。link は双方向で、接続プロセスが1つ落ちただけで room actor ごと
    // 道連れになる。
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, ..) -> SessionDown(pid)
          process.PortDown(..) -> SessionDown(process.self())
        }
      })
    actor.initialised(ActorState(
      poker: new_state(),
      subscribers: dict.new(),
      sessions: dict.new(),
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message {
    Dispatch(command, session, reply_to) -> {
      let #(next_poker, event) = apply_command(state.poker, command)
      let next_subscribers =
        update_subscribers(state.subscribers, event, session)
      let next_sessions = update_sessions(state.sessions, event, session)
      process.send(reply_to, event)
      broadcast(next_subscribers, except: session, event: event)
      actor.continue(ActorState(
        poker: next_poker,
        subscribers: next_subscribers,
        sessions: next_sessions,
      ))
    }
    GetState(reply_to) -> {
      process.send(reply_to, state.poker)
      actor.continue(state)
    }
    SessionDown(pid) ->
      case dict.get(state.sessions, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(#(participant_key, _monitor)) -> {
          let id = ParticipantId(participant_key)
          let #(next_poker, event) = apply_command(state.poker, Leave(id))
          let next_subscribers = dict.delete(state.subscribers, participant_key)
          broadcast_all(next_subscribers, event)
          case next_poker.participants {
            // 無人になったら自分で止まる（`room.gleam`'s `SessionDown` と
            // 同じ理由、#91）。
            [] -> actor.stop()
            _ ->
              actor.continue(ActorState(
                poker: next_poker,
                subscribers: next_subscribers,
                sessions: dict.delete(state.sessions, pid),
              ))
          }
        }
      }
    ShutdownIfEmpty(reply_to) ->
      case state.poker.participants {
        [] -> {
          process.send(reply_to, True)
          actor.stop()
        }
        _ -> {
          process.send(reply_to, False)
          actor.continue(state)
        }
      }
  }
}

/// 参加時に接続プロセスを監視対象へ入れ、離脱時に外す（`room.gleam`'s
/// `update_sessions` と同じ理由、#56 / #69）。
fn update_sessions(
  sessions: Dict(process.Pid, #(String, process.Monitor)),
  event: PokerEvent,
  session: Subject(PokerEvent),
) -> Dict(process.Pid, #(String, process.Monitor)) {
  case event {
    ParticipantJoined(participant) ->
      case process.subject_owner(session) {
        Ok(pid) -> {
          let monitor = process.monitor(pid)
          dict.insert(sessions, pid, #(
            participant_id_to_string(participant.id),
            monitor,
          ))
        }
        Error(Nil) -> {
          logging.log(
            logging.Warning,
            "subject_owner failed for joining participant, session not monitored: participant_id="
              <> participant_id_to_string(participant.id),
          )
          sessions
        }
      }
    ParticipantLeft(id) -> {
      let key = participant_id_to_string(id)
      dict.each(sessions, fn(_pid, entry) {
        case entry {
          #(participant_key, monitor) if participant_key == key ->
            process.demonitor_process(monitor)
          _ -> Nil
        }
      })
      dict.filter(sessions, fn(_pid, entry) { entry.0 != key })
    }
    JoinRejected(_, _)
    | LeaveRejected(_, _)
    | VoteRegistered(_)
    | VoteRejected(_, _)
    | RoundRevealed(_)
    | RoundReset -> sessions
  }
}

/// 全購読者へ配信する（除外なし）。接続が死んだ参加者の離脱を知らせるのに使う。
fn broadcast_all(
  subscribers: Dict(String, Subject(PokerEvent)),
  event: PokerEvent,
) -> Nil {
  dict.each(subscribers, fn(_key, subscriber) {
    process.send(subscriber, event)
  })
}

fn update_subscribers(
  subscribers: Dict(String, Subject(PokerEvent)),
  event: PokerEvent,
  session: Subject(PokerEvent),
) -> Dict(String, Subject(PokerEvent)) {
  case event {
    ParticipantJoined(participant) ->
      dict.insert(
        subscribers,
        participant_id_to_string(participant.id),
        session,
      )
    ParticipantLeft(id) ->
      dict.delete(subscribers, participant_id_to_string(id))
    JoinRejected(_, _)
    | LeaveRejected(_, _)
    | VoteRegistered(_)
    | VoteRejected(_, _)
    | RoundRevealed(_)
    | RoundReset -> subscribers
  }
}

/// Notifies subscribers about a state change. `VoteRegistered`/
/// `RoundRevealed`/`RoundReset` reach every subscriber, *including* the
/// session that issued the command — mirrors `room.gleam`'s `broadcast`
/// (#143: the issuing session's synchronous `reply_to` can be lost on a
/// `dispatch` timeout, so it must also be reachable asynchronously; reveal
/// is idempotent, so a duplicate delivery is harmless per `apply_reveal`'s
/// doc comment). `ParticipantJoined`/`ParticipantLeft` still exclude/omit
/// the issuer. Rejections are not broadcast: they carry no state change and
/// are only meaningful to the issuing session, which always gets them
/// synchronously through `reply_to`.
fn broadcast(
  subscribers: Dict(String, Subject(PokerEvent)),
  except except_session: Subject(PokerEvent),
  event event: PokerEvent,
) -> Nil {
  case event {
    VoteRegistered(_) | RoundRevealed(_) | RoundReset ->
      broadcast_all(subscribers, event)
    ParticipantJoined(_) | ParticipantLeft(_) ->
      subscribers
      |> dict.to_list
      |> list.each(fn(entry) {
        let #(_, subject) = entry
        case subject == except_session {
          True -> Nil
          False -> process.send(subject, event)
        }
      })
    JoinRejected(_, _) | LeaveRejected(_, _) | VoteRejected(_, _) -> Nil
  }
}

/// Sends a command to a running poker room actor and waits for the
/// resulting event. Mirrors `room.gleam`'s `dispatch` (#33): a stuck actor
/// surfaces as `Error(Nil)` rather than crashing the calling process.
pub fn dispatch(
  subject: Subject(Message),
  command: PokerCommand,
  session: Subject(PokerEvent),
) -> Result(PokerEvent, Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    Dispatch(command, session, _),
    "poker.dispatch",
  )
}

/// Reads the current poker state (participants, votes, phase) from a
/// running poker room actor.
pub fn get_state(subject: Subject(Message)) -> Result(PokerState, Nil) {
  call.try_call(subject, call.default_timeout, GetState, "poker.get_state")
}

/// 無人なら poker room を停止させ、停止したかどうかを返す。`room.gleam`'s
/// `shutdown_if_empty` と同じ理由（#36）で、判定と停止のレースを防ぐ。
pub fn shutdown_if_empty(subject: Subject(Message)) -> Bool {
  case
    call.try_call(
      subject,
      call.default_timeout,
      ShutdownIfEmpty,
      "poker.shutdown_if_empty",
    )
  {
    Ok(stopped) -> stopped
    Error(Nil) -> False
  }
}
