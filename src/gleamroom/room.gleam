import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

/// Opaque so callers cannot construct a `ParticipantId` except through
/// `participant_id`, keeping room state free of ad-hoc string comparisons.
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

/// One accepted buzz, in the order the Room actor's mailbox processed it.
/// `position` is 1-based and assigned when the buzz is accepted, so it never
/// changes even as later buzzes are appended.
pub type BuzzResult {
  BuzzResult(participant_id: ParticipantId, position: Int)
}

pub type RoomState {
  RoomState(participants: List(Participant), buzzes: List(BuzzResult))
}

pub fn new_state() -> RoomState {
  RoomState(participants: [], buzzes: [])
}

pub type RoomCommand {
  Join(id: ParticipantId, display_name: String)
  Leave(id: ParticipantId)
  Buzz(id: ParticipantId)
  ResetRound
}

pub type JoinRejectReason {
  AlreadyJoined
}

pub type LeaveRejectReason {
  NotJoined
}

pub type BuzzRejectReason {
  BuzzerNotJoined
  AlreadyBuzzed
}

pub type RoomEvent {
  ParticipantJoined(Participant)
  JoinRejected(id: ParticipantId, reason: JoinRejectReason)
  ParticipantLeft(ParticipantId)
  LeaveRejected(id: ParticipantId, reason: LeaveRejectReason)
  BuzzAccepted(id: ParticipantId, position: Int)
  BuzzRejected(id: ParticipantId, reason: BuzzRejectReason)
  RoundReset
}

/// Pure state transition: given the current state and a command, returns the
/// resulting state and the single event produced. Kept free of any actor or
/// transport concern so join/leave semantics are unit-testable without
/// starting a process.
pub fn apply_command(
  state: RoomState,
  command: RoomCommand,
) -> #(RoomState, RoomEvent) {
  case command {
    Join(id, display_name) -> apply_join(state, id, display_name)
    Leave(id) -> apply_leave(state, id)
    Buzz(id) -> apply_buzz(state, id)
    ResetRound -> apply_reset_round(state)
  }
}

fn apply_join(
  state: RoomState,
  id: ParticipantId,
  display_name: String,
) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    Ok(_) -> #(state, JoinRejected(id, AlreadyJoined))
    Error(Nil) -> {
      let participant = Participant(id, display_name)
      let next =
        RoomState(..state, participants: [participant, ..state.participants])
      #(next, ParticipantJoined(participant))
    }
  }
}

fn apply_leave(state: RoomState, id: ParticipantId) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    Error(Nil) -> #(state, LeaveRejected(id, NotJoined))
    Ok(_) -> {
      let remaining = list.filter(state.participants, fn(p) { p.id != id })
      #(RoomState(..state, participants: remaining), ParticipantLeft(id))
    }
  }
}

/// Accepts at most one buzz per participant per round. Ordering comes from
/// the Room actor's mailbox processing order (one command at a time), so no
/// client-supplied or wall-clock timestamp is ever consulted to decide who
/// was first.
fn apply_buzz(state: RoomState, id: ParticipantId) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    Error(Nil) -> #(state, BuzzRejected(id, BuzzerNotJoined))
    Ok(_) ->
      case has_buzzed(state, id) {
        True -> #(state, BuzzRejected(id, AlreadyBuzzed))
        False -> {
          let position = list.length(state.buzzes) + 1
          let next =
            RoomState(..state, buzzes: [
              BuzzResult(id, position),
              ..state.buzzes
            ])
          #(next, BuzzAccepted(id, position))
        }
      }
  }
}

fn apply_reset_round(state: RoomState) -> #(RoomState, RoomEvent) {
  #(RoomState(..state, buzzes: []), RoundReset)
}

fn has_buzzed(state: RoomState, id: ParticipantId) -> Bool {
  list.any(state.buzzes, fn(result) { result.participant_id == id })
}

fn find_participant(
  state: RoomState,
  id: ParticipantId,
) -> Result(Participant, Nil) {
  list.find(state.participants, fn(p) { p.id == id })
}

/// The current participant list, suitable for a transport adapter to turn
/// into a state snapshot for a newly joined or reconnecting client.
pub fn snapshot(state: RoomState) -> List(Participant) {
  state.participants
}

/// The current round's accepted buzzes, oldest (position 1) first.
pub fn buzz_snapshot(state: RoomState) -> List(BuzzResult) {
  list.reverse(state.buzzes)
}

pub type Message {
  Dispatch(
    command: RoomCommand,
    session: Subject(RoomEvent),
    reply_to: Subject(RoomEvent),
  )
  GetSnapshot(reply_to: Subject(List(Participant)))
  GetBuzzSnapshot(reply_to: Subject(List(BuzzResult)))
  /// 自分が無人なら終了する（#26 / #36）。
  ///
  /// **判定と停止を 1 メッセージに閉じてある。** 呼び出し側が
  /// 「空か確認 → 停止を依頼」と 2 段階で行うと、その隙に join した参加者ごと
  /// 停止させてしまう（#36）。room actor のメールボックスは直列に処理されるため、
  /// 自分で見て自分で止めれば隙間が生まれない。
  ///
  /// 空でなければ何もせず動き続け、`reply_to` に `False` を返す。
  /// registry はこの結果を見て Dict から外すかを決める。
  ShutdownIfEmpty(reply_to: Subject(Bool))
}

/// The actor's own state: the domain `RoomState` plus the set of connected
/// sessions to notify when membership changes. Kept separate from
/// `RoomState` so the pure state transitions stay testable without a
/// process or a notion of "subscriber".
type ActorState {
  ActorState(room: RoomState, subscribers: Dict(String, Subject(RoomEvent)))
}

/// Starts one isolated room actor with empty state. Each call produces an
/// independent process with its own mailbox, so multiple rooms never share
/// participant state (ADR 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new(ActorState(room: new_state(), subscribers: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message {
    Dispatch(command, session, reply_to) -> {
      let #(next_room, event) = apply_command(state.room, command)
      let next_subscribers =
        update_subscribers(state.subscribers, event, session)
      // The caller always gets the event synchronously through `reply_to`;
      // other connected sessions learn about it asynchronously through
      // their own subject so they observe consistent room state.
      process.send(reply_to, event)
      broadcast(next_subscribers, except: session, event: event)
      actor.continue(ActorState(room: next_room, subscribers: next_subscribers))
    }
    GetSnapshot(reply_to) -> {
      process.send(reply_to, snapshot(state.room))
      actor.continue(state)
    }
    GetBuzzSnapshot(reply_to) -> {
      process.send(reply_to, buzz_snapshot(state.room))
      actor.continue(state)
    }
    ShutdownIfEmpty(reply_to) ->
      case state.room.participants {
        [] -> {
          // 先に返してから止める。停止後は誰も返信できない。
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

fn update_subscribers(
  subscribers: Dict(String, Subject(RoomEvent)),
  event: RoomEvent,
  session: Subject(RoomEvent),
) -> Dict(String, Subject(RoomEvent)) {
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
    | BuzzAccepted(_, _)
    | BuzzRejected(_, _)
    | RoundReset -> subscribers
  }
}

/// Notifies every subscriber other than `except` (the session that issued
/// the command, which already received the event synchronously through
/// `dispatch`) about a state change. Rejections are not broadcast: they
/// carry no state change and are only meaningful to the issuing session.
fn broadcast(
  subscribers: Dict(String, Subject(RoomEvent)),
  except except_session: Subject(RoomEvent),
  event event: RoomEvent,
) -> Nil {
  case event {
    ParticipantJoined(_)
    | ParticipantLeft(_)
    | BuzzAccepted(_, _)
    | RoundReset ->
      subscribers
      |> dict.to_list
      |> list.each(fn(entry) {
        let #(_, subject) = entry
        case subject == except_session {
          True -> Nil
          False -> process.send(subject, event)
        }
      })
    JoinRejected(_, _) | LeaveRejected(_, _) | BuzzRejected(_, _) -> Nil
  }
}

/// Sends a command to a running room actor and waits for the resulting
/// event. A 1000ms timeout is used so a stuck actor surfaces as a crash
/// rather than an indefinite hang. `session` identifies the caller's own
/// subject so future events for this room can be delivered asynchronously.
pub fn dispatch(
  subject: Subject(Message),
  command: RoomCommand,
  session: Subject(RoomEvent),
) -> RoomEvent {
  actor.call(subject, waiting: 1000, sending: Dispatch(command, session, _))
}

/// Reads the current participant list from a running room actor.
pub fn get_snapshot(subject: Subject(Message)) -> List(Participant) {
  actor.call(subject, waiting: 1000, sending: GetSnapshot)
}

/// Reads the current round's accepted buzzes from a running room actor.
pub fn get_buzz_snapshot(subject: Subject(Message)) -> List(BuzzResult) {
  actor.call(subject, waiting: 1000, sending: GetBuzzSnapshot)
}

/// 無人なら room を停止させ、停止したかどうかを返す（#36）。
///
/// 判定と停止が room actor の 1 メッセージに閉じているため、呼び出し側が
/// 「空か確認 → 停止を依頼」と 2 段階で行ったときのレースが起きない。
pub fn shutdown_if_empty(subject: Subject(Message)) -> Bool {
  actor.call(subject, waiting: 1000, sending: ShutdownIfEmpty)
}
