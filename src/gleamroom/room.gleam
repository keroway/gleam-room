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

pub type RoomState {
  RoomState(participants: List(Participant))
}

pub fn new_state() -> RoomState {
  RoomState(participants: [])
}

pub type RoomCommand {
  Join(id: ParticipantId, display_name: String)
  Leave(id: ParticipantId)
}

pub type JoinRejectReason {
  AlreadyJoined
}

pub type LeaveRejectReason {
  NotJoined
}

pub type RoomEvent {
  ParticipantJoined(Participant)
  JoinRejected(id: ParticipantId, reason: JoinRejectReason)
  ParticipantLeft(ParticipantId)
  LeaveRejected(id: ParticipantId, reason: LeaveRejectReason)
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
      let next = RoomState(participants: [participant, ..state.participants])
      #(next, ParticipantJoined(participant))
    }
  }
}

fn apply_leave(state: RoomState, id: ParticipantId) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    Error(Nil) -> #(state, LeaveRejected(id, NotJoined))
    Ok(_) -> {
      let remaining = list.filter(state.participants, fn(p) { p.id != id })
      #(RoomState(participants: remaining), ParticipantLeft(id))
    }
  }
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

pub type Message {
  Dispatch(command: RoomCommand, reply_to: Subject(RoomEvent))
  GetSnapshot(reply_to: Subject(List(Participant)))
}

/// Starts one isolated room actor with empty state. Each call produces an
/// independent process with its own mailbox, so multiple rooms never share
/// participant state (ADR 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new(new_state())
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: RoomState,
  message: Message,
) -> actor.Next(RoomState, Message) {
  case message {
    Dispatch(command, reply_to) -> {
      let #(next, event) = apply_command(state, command)
      process.send(reply_to, event)
      actor.continue(next)
    }
    GetSnapshot(reply_to) -> {
      process.send(reply_to, snapshot(state))
      actor.continue(state)
    }
  }
}

/// Sends a command to a running room actor and waits for the resulting
/// event. A 1000ms timeout is used so a stuck actor surfaces as a crash
/// rather than an indefinite hang.
pub fn dispatch(subject: Subject(Message), command: RoomCommand) -> RoomEvent {
  actor.call(subject, waiting: 1000, sending: Dispatch(command, _))
}

/// Reads the current participant list from a running room actor.
pub fn get_snapshot(subject: Subject(Message)) -> List(Participant) {
  actor.call(subject, waiting: 1000, sending: GetSnapshot)
}
