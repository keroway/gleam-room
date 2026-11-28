import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleamroom/call
import logging

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

/// A participant's role (#768, ADR 0010). The host runs the questions and
/// does not buzz; a player buzzes. A display is not a participant at all, so
/// it has no role here.
pub type Role {
  Host
  Player
}

/// Where the current question stands (#768, docs/buzzer-session.md
/// "Acceptance phases"). Only the host moves it, except that the first buzz
/// while `Open` locks it and a host who goes away stops acceptance.
pub type Phase {
  /// Not accepting buzzes: before a question, or after it was closed.
  Waiting
  /// Accepting buzzes. The first accepted buzz moves to `Locked`.
  Open
  /// Someone buzzed first and is the answerer (position 1). Later buzzes are
  /// still queued in order.
  Locked
  /// The session ended. Read-only from here on.
  Finished
}

/// `connected` is False while the participant's connection is gone but the
/// participant is still within the resume grace period (#766). They keep
/// their id, buzzes and place in the list until the grace expires.
pub type Participant {
  Participant(
    id: ParticipantId,
    display_name: String,
    connected: Bool,
    role: Role,
  )
}

/// One accepted buzz, in the order the Room actor's mailbox processed it.
/// `position` is 1-based and assigned when the buzz is accepted, so it never
/// changes even as later buzzes are appended. `display_name` is a snapshot
/// taken at accept time (per ADR 0003, buzz history outlives the
/// participant's connection, so it cannot be re-resolved from the current
/// participant list later — see #30).
pub type BuzzResult {
  BuzzResult(participant_id: ParticipantId, display_name: String, position: Int)
}

/// `round_id` identifies the current round (one question) and only grows.
/// `revision` counts accepted state changes and only grows; every accepted
/// event carries the revision it produced, so a client can order events and
/// detect stale or missing ones without comparing contents (#765, ADR 0010).
/// Rejected commands leave both unchanged.
pub type RoomState {
  RoomState(
    participants: List(Participant),
    buzzes: List(BuzzResult),
    round_id: Int,
    revision: Int,
    phase: Phase,
  )
}

pub fn new_state() -> RoomState {
  RoomState(
    participants: [],
    buzzes: [],
    round_id: 1,
    revision: 0,
    phase: Waiting,
  )
}

/// Round-scoped commands name the round the client saw. A command for any
/// other round is rejected, so a button pressed on an outdated screen cannot
/// affect a newer round (#765).
///
/// The host commands (#768) name the participant who sent them (`by`); the
/// room checks that this participant is the host. Who `by` is comes from the
/// connection the command arrived on, never from the client.
pub type RoomCommand {
  Join(id: ParticipantId, display_name: String)
  /// The room's creator joining, or the host coming back after their grace
  /// ran out (#768). Issued only by the actor itself.
  JoinAsHost(id: ParticipantId, display_name: String)
  Leave(id: ParticipantId)
  Buzz(id: ParticipantId, round_id: Int)
  OpenAcceptance(by: ParticipantId, round_id: Int)
  CloseAcceptance(by: ParticipantId, round_id: Int)
  /// Closes the question without an answer (`Waiting`).
  Skip(by: ParticipantId, round_id: Int)
  /// Starts the next question: a new `round_id`, an empty buzz queue,
  /// `Waiting`. Replaces the MVP's `ResetRound`, which anyone could send.
  NextQuestion(by: ParticipantId, round_id: Int)
  /// Gives the host role to a connected player; `by` becomes a player.
  TransferHost(by: ParticipantId, to: ParticipantId)
  EndSession(by: ParticipantId)
  /// The participant's connection went away. They stay in the room, marked
  /// disconnected, until they resume or the grace period expires (#766).
  /// Issued only by the actor itself, never accepted through `dispatch`.
  Disconnect(id: ParticipantId)
  /// A disconnected participant attached a new connection (#766). Issued
  /// only by the actor itself.
  Reconnect(id: ParticipantId)
  /// The host is no longer there to run the question (#768). Acceptance is
  /// not left running without a host: `Open` moves to `Waiting`. With
  /// `include_locked` (the host left for good) `Locked` does too. Issued only
  /// by the actor itself.
  HostAway(include_locked: Bool)
}

pub type JoinRejectReason {
  AlreadyJoined
  InvalidDisplayName
  RoomFull
  /// The session has ended (#768); nobody new can join.
  JoinSessionFinished
}

pub type LeaveRejectReason {
  NotJoined
}

pub type BuzzRejectReason {
  BuzzerNotJoined
  AlreadyBuzzed
  RoundFull
  /// The buzz named a round that is not the current one (#765).
  BuzzStaleRound
  /// The phase is `Waiting`: the host has not opened acceptance (#768).
  NotAccepting
  /// The session has ended (#768).
  BuzzSessionFinished
  /// The host does not buzz (#768).
  HostCannotBuzz
}

/// Why a host command (#768), or an internal transition, was not applied.
pub type CommandRejectReason {
  /// The sender is not the host (a player, or a display).
  Forbidden
  /// The command named a round that is not the current one (#765).
  StaleRound
  /// Not allowed in the current phase, e.g. opening while already `Open`.
  InvalidPhase
  /// The session has ended.
  SessionFinished
  /// `NextQuestion` beyond `max_rounds`.
  SessionFull
  /// `TransferHost` to someone who is not a connected player.
  InvalidTarget
  /// The command came from a connection that is not any participant's
  /// current connection, e.g. one replaced by a resume (#766).
  CommandNotJoined
}

/// Accepted events carry the `revision` they produced (#765); rejections
/// carry none because they change nothing.
pub type RoomEvent {
  ParticipantJoined(participant: Participant, revision: Int)
  JoinRejected(id: ParticipantId, reason: JoinRejectReason)
  ParticipantLeft(id: ParticipantId, revision: Int)
  LeaveRejected(id: ParticipantId, reason: LeaveRejectReason)
  /// `phase` is the phase after this buzz: the first buzz while `Open` locks.
  BuzzAccepted(
    id: ParticipantId,
    display_name: String,
    position: Int,
    round_id: Int,
    phase: Phase,
    revision: Int,
  )
  BuzzRejected(id: ParticipantId, reason: BuzzRejectReason)
  /// `round_id` is the new question that starts with `NextQuestion`. The
  /// phase is `Waiting` and the buzz queue is empty.
  RoundReset(round_id: Int, revision: Int)
  /// The acceptance phase changed (#768) for the current `round_id`.
  PhaseChanged(phase: Phase, round_id: Int, revision: Int)
  /// The host role moved from `from` to `to` (#768).
  HostTransferred(from: ParticipantId, to: ParticipantId, revision: Int)
  CommandRejected(reason: CommandRejectReason)
  ParticipantDisconnected(id: ParticipantId, revision: Int)
  ParticipantReconnected(id: ParticipantId, revision: Int)
  /// `Disconnect`/`Reconnect` did not apply (unknown participant, or already
  /// in that state). Never broadcast.
  PresenceRejected(id: ParticipantId)
  /// Sent only to a connection whose participant was resumed by a newer
  /// connection (#766). The receiver must stop using the room. Never
  /// broadcast, and carries no state change.
  SessionReplaced
  /// Sent only to the connection of the participant who just became host
  /// (#768): the new host token. Never broadcast or logged.
  HostAssigned(host_token: String)
}

/// A consistent view of the room at one revision: what a joining or
/// resyncing client starts from (#765). `instance_id` tells a room apart from
/// an earlier room with the same code.
pub type Snapshot {
  Snapshot(
    instance_id: String,
    round_id: Int,
    revision: Int,
    phase: Phase,
    participants: List(Participant),
    buzzes: List(BuzzResult),
  )
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
    Join(id, display_name) -> apply_join(state, id, display_name, Player)
    JoinAsHost(id, display_name) -> apply_join(state, id, display_name, Host)
    Leave(id) -> apply_leave(state, id)
    Buzz(id, round_id) -> apply_buzz(state, id, round_id)
    OpenAcceptance(by, round_id) ->
      host_command(state, by, round_id, fn(phase) {
        case phase {
          Waiting -> Ok(set_phase(state, Open))
          _ -> Error(InvalidPhase)
        }
      })
    CloseAcceptance(by, round_id) ->
      host_command(state, by, round_id, fn(phase) {
        case phase {
          Open -> Ok(set_phase(state, Waiting))
          _ -> Error(InvalidPhase)
        }
      })
    Skip(by, round_id) ->
      host_command(state, by, round_id, fn(phase) {
        case phase {
          Open | Locked -> Ok(set_phase(state, Waiting))
          _ -> Error(InvalidPhase)
        }
      })
    NextQuestion(by, round_id) ->
      host_command(state, by, round_id, fn(_phase) {
        case state.round_id >= max_rounds {
          True -> Error(SessionFull)
          False -> {
            let next_round = state.round_id + 1
            let revision = next_revision(state)
            Ok(#(
              RoomState(
                ..state,
                buzzes: [],
                round_id: next_round,
                phase: Waiting,
                revision:,
              ),
              RoundReset(next_round, revision),
            ))
          }
        }
      })
    TransferHost(by, to) ->
      host_command(state, by, state.round_id, fn(_phase) {
        apply_transfer_host(state, by, to)
      })
    EndSession(by) ->
      host_command(state, by, state.round_id, fn(_phase) {
        Ok(set_phase(state, Finished))
      })
    Disconnect(id) -> apply_presence(state, id, False)
    Reconnect(id) -> apply_presence(state, id, True)
    HostAway(include_locked) ->
      case state.phase, include_locked {
        Open, _ | Locked, True -> set_phase(state, Waiting)
        _, _ -> #(state, CommandRejected(InvalidPhase))
      }
  }
}

fn next_revision(state: RoomState) -> Int {
  state.revision + 1
}

fn set_phase(state: RoomState, phase: Phase) -> #(RoomState, RoomEvent) {
  let revision = next_revision(state)
  #(
    RoomState(..state, phase:, revision:),
    PhaseChanged(phase, state.round_id, revision),
  )
}

/// The checks every host command shares, in this order: the sender is the
/// host (`Forbidden`), the session is still running (`SessionFinished`), the
/// command names the current round (`StaleRound`). `apply` then checks the
/// phase and produces the change.
fn host_command(
  state: RoomState,
  by: ParticipantId,
  round_id: Int,
  apply: fn(Phase) -> Result(#(RoomState, RoomEvent), CommandRejectReason),
) -> #(RoomState, RoomEvent) {
  let outcome = case find_participant(state, by) {
    Ok(Participant(role: Host, ..)) ->
      case state.phase, round_id == state.round_id {
        Finished, _ -> Error(SessionFinished)
        _, False -> Error(StaleRound)
        phase, True -> apply(phase)
      }
    _ -> Error(Forbidden)
  }
  case outcome {
    Ok(change) -> change
    Error(reason) -> #(state, CommandRejected(reason))
  }
}

fn apply_transfer_host(
  state: RoomState,
  by: ParticipantId,
  to: ParticipantId,
) -> Result(#(RoomState, RoomEvent), CommandRejectReason) {
  case find_participant(state, to) {
    Ok(Participant(role: Player, connected: True, ..)) -> {
      let revision = next_revision(state)
      let participants =
        list.map(state.participants, fn(p) {
          case p.id == to, p.id == by {
            True, _ -> Participant(..p, role: Host)
            _, True -> Participant(..p, role: Player)
            _, _ -> p
          }
        })
      Ok(#(
        RoomState(..state, participants:, revision:),
        HostTransferred(by, to, revision),
      ))
    }
    _ -> Error(InvalidTarget)
  }
}

/// Domain-level ceiling on `display_name`, independent of the WebSocket
/// boundary's own limit in `protocol.join_decoder`. `apply_join` is the only
/// place that constructs a `Participant`, so this is the last line of
/// defense if a future caller (a different transport, a test) reaches it
/// without going through the boundary's validation.
const max_display_name_length = 64

/// Ceiling on a single room's participant count. Without it, a client can
/// open unbounded WebSocket connections against the same `room_id` (each
/// gets a fresh `ParticipantId`) and grow `state.participants` without
/// bound, which drives the O(N) per-event broadcast cost in `broadcast`/
/// `broadcast_all` toward O(N^2) over the room's lifetime (#129).
const max_participants = 64

/// Ceiling on accepted buzzes per round. Leavers keep their result (ADR 0003),
/// so a resident participant plus join/buzz/leave churn could otherwise grow
/// one round's history without bound, and every new joiner's state snapshot
/// carries all of it (#691). Reaching it rejects further buzzes with
/// `RoundFull` until `NextQuestion`; existing positions never change.
const max_buzzes_per_round = 128

/// Ceiling on questions per session (#768, docs/buzzer-session.md "Limits").
/// `NextQuestion` from the last one is rejected with `SessionFull`.
pub const max_rounds = 200

fn apply_join(
  state: RoomState,
  id: ParticipantId,
  display_name: String,
  role: Role,
) -> #(RoomState, RoomEvent) {
  case
    find_participant(state, id),
    is_valid_display_name(display_name),
    list.length(state.participants) >= max_participants
  {
    _, False, _ -> #(state, JoinRejected(id, InvalidDisplayName))
    // Unreachable from the current websocket layer: each connection gets a
    // fresh ParticipantId and dispatches Join at most once, so no live
    // connection can ever collide with an id already in `participants`.
    // Kept as a defensive branch for a future multi-connection/reconnect
    // model where a ParticipantId could be reused (#52).
    Ok(_), True, _ -> #(state, JoinRejected(id, AlreadyJoined))
    Error(Nil), True, _ if state.phase == Finished -> #(
      state,
      JoinRejected(id, JoinSessionFinished),
    )
    Error(Nil), True, True -> #(state, JoinRejected(id, RoomFull))
    Error(Nil), True, False -> {
      let participant = Participant(id, display_name, connected: True, role:)
      let revision = next_revision(state)
      let next =
        RoomState(
          ..state,
          participants: [participant, ..state.participants],
          revision:,
        )
      #(next, ParticipantJoined(participant, revision))
    }
  }
}

fn is_valid_display_name(display_name: String) -> Bool {
  string.trim(display_name) != ""
  && string.length(display_name) <= max_display_name_length
  && string.byte_size(display_name) <= max_display_name_length
}

fn apply_leave(state: RoomState, id: ParticipantId) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    // Reached when a connection replaced by a resume sends `leave`; the
    // actor's `authorize` answers that before it gets here (#766).
    Error(Nil) -> #(state, LeaveRejected(id, NotJoined))
    Ok(_) -> {
      let remaining = list.filter(state.participants, fn(p) { p.id != id })
      let revision = next_revision(state)
      #(
        RoomState(..state, participants: remaining, revision:),
        ParticipantLeft(id, revision),
      )
    }
  }
}

/// Accepts at most one buzz per participant per round, and only while the
/// host accepts buzzes (#768). Ordering comes from the Room actor's mailbox
/// processing order (one command at a time), so no client-supplied or
/// wall-clock timestamp is ever consulted to decide who was first. The first
/// accepted buzz while `Open` locks the question; later buzzes are queued.
fn apply_buzz(
  state: RoomState,
  id: ParticipantId,
  round_id: Int,
) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    // Reached when a connection replaced by a resume sends `buzz`; the
    // actor's `authorize` answers that before it gets here (#766).
    Error(Nil) -> #(state, BuzzRejected(id, BuzzerNotJoined))
    Ok(Participant(role: Host, ..)) -> #(
      state,
      BuzzRejected(id, HostCannotBuzz),
    )
    Ok(participant) ->
      case state.phase, round_id == state.round_id {
        Finished, _ -> #(state, BuzzRejected(id, BuzzSessionFinished))
        _, False -> #(state, BuzzRejected(id, BuzzStaleRound))
        Waiting, True -> #(state, BuzzRejected(id, NotAccepting))
        _, True ->
          case
            has_buzzed(state, id),
            list.length(state.buzzes) >= max_buzzes_per_round
          {
            True, _ -> #(state, BuzzRejected(id, AlreadyBuzzed))
            False, True -> #(state, BuzzRejected(id, RoundFull))
            False, False -> {
              let position = list.length(state.buzzes) + 1
              let revision = next_revision(state)
              let phase = case state.phase {
                Open -> Locked
                phase -> phase
              }
              let next =
                RoomState(
                  ..state,
                  buzzes: [
                    BuzzResult(id, participant.display_name, position),
                    ..state.buzzes
                  ],
                  phase:,
                  revision:,
                )
              #(
                next,
                BuzzAccepted(
                  id,
                  participant.display_name,
                  position,
                  state.round_id,
                  phase,
                  revision,
                ),
              )
            }
          }
      }
  }
}

/// Marks a participant connected or disconnected (#766). Only a real change
/// consumes a revision; anything else is `PresenceRejected`.
fn apply_presence(
  state: RoomState,
  id: ParticipantId,
  connected: Bool,
) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    Ok(participant) if participant.connected != connected -> {
      let revision = next_revision(state)
      let participants =
        list.map(state.participants, fn(p) {
          case p.id == id {
            True -> Participant(..p, connected:)
            False -> p
          }
        })
      let event = case connected {
        True -> ParticipantReconnected(id, revision)
        False -> ParticipantDisconnected(id, revision)
      }
      #(RoomState(..state, participants:, revision:), event)
    }
    _ -> #(state, PresenceRejected(id))
  }
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

/// The current participant list, oldest (first joined) first, suitable for
/// a transport adapter to turn into a state snapshot for a newly joined or
/// reconnecting client.
pub fn snapshot(state: RoomState) -> List(Participant) {
  list.reverse(state.participants)
}

/// The current round's accepted buzzes, oldest (position 1) first.
pub fn buzz_snapshot(state: RoomState) -> List(BuzzResult) {
  list.reverse(state.buzzes)
}

/// The whole room at its current revision (#765).
pub fn full_snapshot(state: RoomState, instance_id: String) -> Snapshot {
  Snapshot(
    instance_id:,
    round_id: state.round_id,
    revision: state.revision,
    phase: state.phase,
    participants: snapshot(state),
    buzzes: buzz_snapshot(state),
  )
}

/// How long a disconnected participant can resume before they are removed
/// (#766, ADR 0010). Counted from when the room learns of the disconnect.
pub const default_participant_grace_ms = 60_000

/// How long a room may stay without any participant before it stops itself
/// (#767, ADR 0010). A room created for someone whose first join never
/// arrives (the connection died in between) is reclaimed by this timer.
pub const default_empty_room_grace_ms = 60_000

/// Ceiling on participants a room keeps track of, including those who already
/// left (their token then answers `ResumeExpired`). Departed entries beyond it
/// are dropped oldest first, so churn cannot grow the room without bound
/// (#766, docs/buzzer-session.md "Limits").
const max_tracked_participants = 128

/// Ceiling on displays per room (#768, docs/buzzer-session.md "Limits").
const max_displays = 8

/// The answer to `join`: the event, a snapshot taken in the same mailbox
/// message (#765), the resume token issued to the joiner (#766), and the host
/// token when the joiner is the room's creator (#767). Tokens are `None` when
/// the join was rejected. They must reach only the joining client: they are
/// never broadcast or logged.
pub type JoinReply {
  JoinReply(
    event: RoomEvent,
    snapshot: Snapshot,
    resume_token: option.Option(String),
    host_token: option.Option(String),
  )
}

pub type ResumeRejectReason {
  /// The token names a different room instance, e.g. the room was recreated
  /// or the server restarted.
  RoomGone
  /// The participant left or their grace period expired.
  ResumeExpired
  /// The token was never issued by this room instance (or was dropped by
  /// `max_tracked_participants`).
  InvalidToken
}

/// The answer to `Watch` (#768).
pub type WatchReply {
  Watching(snapshot: Snapshot)
  /// `max_displays` displays are already attached.
  DisplaysFull
}

pub type ResumeReply {
  Resumed(participant_id: ParticipantId, snapshot: Snapshot)
  ResumeRejected(reason: ResumeRejectReason)
}

pub type Message {
  Dispatch(
    command: RoomCommand,
    session: Subject(RoomEvent),
    reply_to: Subject(RoomEvent),
  )
  GetSnapshot(reply_to: Subject(List(Participant)))
  /// `GetSnapshot` と buzz のスナップショットを合わせて 1 メッセージで返す（#121）。
  ///
  /// 呼び出し側が participants と buzzes を 2 回の独立した call で別々に
  /// 取得すると、その間に他の接続の Join/Leave/Buzz/Reset が割り込み、
  /// 互いに取得時点がずれたスナップショットの組み合わせになりうる。
  /// 同一メッセージ処理内で両方を読めば、常に同じ `state.room` 由来になる。
  GetState(reply_to: Subject(Snapshot))
  /// `Join` と参加直後のスナップショットを 1 メッセージで返す（#765）。
  ///
  /// 以前は join の応答を受けてから別の `GetState` で状態を取り直しており、
  /// その間に他の接続の変更が割り込むと、スナップショットに含まれる変更が
  /// 購読済みのメールボックスにも届いて二重に適用されうるうえ（#43）、
  /// どこまでがスナップショットに入っているかをクライアントが判別できなかった。
  /// 同じ処理の中で join・購読・スナップショット取得を行えば、以後に届く
  /// 配信は必ずスナップショットの revision より新しい。
  ///
  /// `as_host` は部屋を作った接続の最初の join だけが True にする（#767）。
  /// まだ司会がいなければ、その参加者に司会 token を発行する。招待から
  /// 入る join は常に False なので、招待 URL から司会にはなれない。
  JoinWithSnapshot(
    id: ParticipantId,
    display_name: String,
    session: Subject(RoomEvent),
    as_host: Bool,
    reply_to: Subject(JoinReply),
  )
  /// 既存の参加者として新しい接続を付け直す（#766）。`instance_id` は
  /// クライアントが前回受け取った room の世代で、違えば `RoomGone`。
  /// 同じ参加者に別の接続が付いていれば、それを `SessionReplaced` で外す。
  ///
  /// `host_token` が現在の司会 token と一致すれば、司会として戻る（#768）。
  /// 司会は参加者の猶予に縛られず、猶予切れで一覧から外れた後でも、部屋が
  /// 続いている限り戻れる。一致しなければ `token`（resume token）で判定する。
  Resume(
    token: String,
    host_token: option.Option(String),
    instance_id: String,
    session: Subject(RoomEvent),
    reply_to: Subject(ResumeReply),
  )
  /// 会場表示として配信を受け始める（#768）。参加者ではないので一覧に
  /// 載らず、token も持たない。上限は `max_displays`。
  Watch(session: Subject(RoomEvent), reply_to: Subject(WatchReply))
  /// 会場表示の接続が閉じた（#768）。
  Unwatch(session: Subject(RoomEvent))
  /// 接続が閉じた（#766）。`session` がその参加者の現在の接続のときだけ
  /// 切断中にして猶予タイマーを始める。古い接続からの遅れた通知は無視する。
  Detach(id: ParticipantId, session: Subject(RoomEvent))
  /// 猶予タイマーの満了（#766）。`generation` が現在の接続世代と一致し、
  /// まだ切断中のときだけ参加者を外す。復帰後に届いた古いタイマーは無視する。
  GraceExpired(participant_key: String, generation: Int)
  /// 起動から `empty_room_grace_ms` 経った（#767）。その時点で参加者が
  /// 1人もいなければ止まる。作成直後の join が届かなかった部屋の回収で、
  /// 一度でも参加者がいた部屋は、最後の退出・猶予切れの時点で既に止まって
  /// いる。
  EmptyRoomGrace
  /// 自分が無人なら終了する（#26 / #36）。
  ///
  /// **判定と停止を 1 メッセージに閉じてある。** 呼び出し側が
  /// 「空か確認 → 停止を依頼」と 2 段階で行うと、その隙に join した参加者ごと
  /// 停止させてしまう（#36）。room actor のメールボックスは直列に処理されるため、
  /// 自分で見て自分で止めれば隙間が生まれない。
  ///
  /// 切断中（猶予内）の参加者も「居る」に数える（#766）。空でなければ何も
  /// せず動き続け、`reply_to` に `False` を返す。
  /// registry はこの結果を見て Dict から外すかを決める。
  ShutdownIfEmpty(reply_to: Subject(Bool))
  /// 参加者の接続プロセスが死んだときに届く（#56 / #35）。
  ///
  /// 接続が死んだのに `Detach` が届かない経路が複数ある:
  ///
  ///   - `Join` がタイムアウトし、**遅れて成立した**（接続側は自分が参加者だと
  ///     知らないので Detach を送れない、#33）
  ///   - 接続プロセスがクラッシュした
  ///   - 突然の切断で `on_close` が走らなかった（#35）
  ///
  /// どの経路でも `Detach` と同じく切断中にして猶予を始める（#766）。
  /// 以前はここで即座に退出させていた。
  SessionDown(pid: process.Pid)
}

/// The connection currently attached to a participant. `monitor` is `None`
/// only if the session's owner could not be resolved (then a crash of that
/// connection is noticed only through `Detach`).
type Attachment {
  Attachment(
    session: Subject(RoomEvent),
    monitor: option.Option(#(process.Pid, process.Monitor)),
  )
}

/// Per-participant bookkeeping the pure `RoomState` does not need (#766).
type Member {
  Member(
    id: ParticipantId,
    /// Proves "I am this participant" on resume. Never broadcast or logged.
    token: String,
    /// Bumped on every attach. A grace timer only acts on its own generation.
    generation: Int,
    attachment: option.Option(Attachment),
    /// Left explicitly or grace expired: the token answers `ResumeExpired`.
    departed: Bool,
    /// Issue order, so the oldest departed entries are dropped first.
    issued: Int,
  )
}

/// The actor's own state: the domain `RoomState` plus the connections and
/// tokens behind each participant. Kept separate from `RoomState` so the pure
/// state transitions stay testable without a process.
type ActorState {
  ActorState(
    /// 猶予タイマーを自分宛てに送るための subject（#766）。
    self: Subject(Message),
    /// この actor の生存期間を表す乱数（#765）。同じ部屋コードで作り直された
    /// room の配信を、クライアントが前の room のものと取り違えないようにする。
    instance_id: String,
    room: RoomState,
    participant_grace_ms: Int,
    /// ParticipantId の文字列表現 → Member。退出済みも
    /// `max_tracked_participants` まで残す。
    members: Dict(String, Member),
    /// resume token → ParticipantId の文字列表現。
    tokens: Dict(String, String),
    next_issue: Int,
    /// 司会の席（#767 / #768）。司会が一覧から外れても（猶予切れ・退出）
    /// 席は残り、token を持つ人が戻れる。token は配信・スナップショット・
    /// ログには出さない。
    host: option.Option(HostSeat),
    /// 会場表示の接続（#768）。参加者ではないので `members` とは別に持つ。
    displays: List(Attachment),
  )
}

/// The host capability of this room instance (#767, #768, ADR 0010). Which
/// participant holds the role is in `RoomState` (`Participant.role`); the
/// seat keeps what is needed to come back after leaving the list: the token
/// and the name to rejoin under.
type HostSeat {
  HostSeat(token: String, participant_key: String, display_name: String)
}

/// Starts one isolated room actor with empty state. Each call produces an
/// independent process with its own mailbox, so multiple rooms never share
/// participant state (ADR 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  start_with_timings(default_participant_grace_ms, default_empty_room_grace_ms)
}

/// `start` with a different resume grace period. Production always uses
/// `start`; tests use this to observe grace expiry without waiting a minute.
pub fn start_with_grace(
  participant_grace_ms: Int,
) -> actor.StartResult(Subject(Message)) {
  start_with_timings(participant_grace_ms, default_empty_room_grace_ms)
}

/// `start` with both grace periods replaced. Test-only, like
/// `start_with_grace` (#767).
pub fn start_with_timings(
  participant_grace_ms: Int,
  empty_room_grace_ms: Int,
) -> actor.StartResult(Subject(Message)) {
  start_room(participant_grace_ms, empty_room_grace_ms, new_state())
}

/// `start_with_grace` with acceptance already `Open` and no host. Test-only
/// (#768): tests about buzz ordering, presence and resume can buzz without
/// first seating a host and opening a question.
pub fn start_accepting_with_grace(
  participant_grace_ms: Int,
) -> actor.StartResult(Subject(Message)) {
  start_room(
    participant_grace_ms,
    default_empty_room_grace_ms,
    RoomState(..new_state(), phase: Open),
  )
}

fn start_room(
  participant_grace_ms: Int,
  empty_room_grace_ms: Int,
  initial: RoomState,
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    // 接続プロセスの死を signal ではなくメッセージとして受ける（#56）。
    // **monitor を使う。link ではない**（#69）。
    // link は双方向で、「クラッシュしたプロセスにリンクされたプロセスも
    // クラッシュする」。接続プロセスが 1 つ落ちただけで room actor ごと死に、
    // 同室の全参加者が道連れになる。monitor は片方向で、対象の終了を
    // メッセージとして受け取るだけ。
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, ..) -> SessionDown(pid)
          // Port は監視していない。自分の pid を返せば一致する接続が
          // 無いので実質 no-op になる。
          process.PortDown(..) -> SessionDown(process.self())
        }
      })
    // 作られたまま誰も参加しない部屋を回収する（#767）。
    process.send_after(subject, empty_room_grace_ms, EmptyRoomGrace)
    actor.initialised(
      ActorState(
        self: subject,
        instance_id: random_string(),
        room: initial,
        participant_grace_ms:,
        members: dict.new(),
        tokens: dict.new(),
        next_issue: 0,
        host: option.None,
        displays: [],
      ),
    )
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// 128-bit random, URL-safe. Used for the room instance id and the resume and
/// host tokens.
fn random_string() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base64_url_encode(False)
}

fn handle_message(
  state: ActorState,
  message: Message,
) -> actor.Next(ActorState, Message) {
  case message {
    Dispatch(command, session, reply_to) -> {
      let #(next_state, event) = case authorize(state, command, session) {
        Ok(Nil) -> run_command(state, command, session)
        Error(rejection) -> #(state, rejection)
      }
      process.send(reply_to, event)
      actor.continue(next_state)
    }
    JoinWithSnapshot(id, display_name, session, as_host, reply_to) -> {
      // 司会の席が空いているときの作成者の join だけが司会になる（#767 / #768）。
      let as_host = as_host && state.host == option.None
      let command = case as_host {
        True -> JoinAsHost(id, display_name)
        False -> Join(id, display_name)
      }
      let #(next_state, event) = run_command(state, command, session)
      let #(next_state, resume_token, host_token) = case event {
        ParticipantJoined(participant, _) -> {
          let key = participant_id_to_string(participant.id)
          let resume_token =
            dict.get(next_state.members, key)
            |> option.from_result
            |> option.map(fn(member) { member.token })
          let #(next_state, host_token) = case as_host {
            True -> {
              let token = random_string()
              #(
                ActorState(
                  ..next_state,
                  host: option.Some(HostSeat(
                    token:,
                    participant_key: key,
                    display_name: participant.display_name,
                  )),
                ),
                option.Some(token),
              )
            }
            False -> #(next_state, option.None)
          }
          #(next_state, resume_token, host_token)
        }
        _ -> #(next_state, option.None, option.None)
      }
      process.send(
        reply_to,
        JoinReply(
          event,
          full_snapshot(next_state.room, next_state.instance_id),
          resume_token,
          host_token,
        ),
      )
      actor.continue(next_state)
    }
    Resume(token, host_token, instance_id, session, reply_to) -> {
      let #(next_state, reply) =
        resume(state, token, host_token, instance_id, session)
      process.send(reply_to, reply)
      actor.continue(next_state)
    }
    Watch(session, reply_to) ->
      case list.length(state.displays) >= max_displays {
        True -> {
          process.send(reply_to, DisplaysFull)
          actor.continue(state)
        }
        False -> {
          let attachment = attach(session, "display")
          let state =
            ActorState(..state, displays: [attachment, ..state.displays])
          process.send(
            reply_to,
            Watching(full_snapshot(state.room, state.instance_id)),
          )
          actor.continue(state)
        }
      }
    Unwatch(session) ->
      actor.continue(
        remove_displays(state, fn(display) { display.session == session }),
      )
    Detach(id, session) -> {
      let key = participant_id_to_string(id)
      case dict.get(state.members, key) {
        Ok(Member(attachment: option.Some(attachment), ..))
          if attachment.session == session
        -> actor.continue(disconnect(state, key))
        // 既に別の接続へ付け替わったか、退出済み。古い接続の遅れた通知。
        _ -> actor.continue(state)
      }
    }
    GraceExpired(key, generation) ->
      case dict.get(state.members, key) {
        Ok(Member(departed: False, attachment: option.None, ..) as member)
          if member.generation == generation
        -> {
          let next_state = depart(state, member)
          case next_state.room.participants {
            // 最後の参加者の猶予が切れた。誰も戻れないので自分で止まる
            // （#91 / #766）。registry は `RoomDown` で登録を外す。判定と
            // 停止が 1 メッセージに閉じているので join と競合しない。
            [] -> actor.stop()
            _ -> actor.continue(next_state)
          }
        }
        // 復帰済み・退出済み・別世代のタイマー。
        _ -> actor.continue(state)
      }
    EmptyRoomGrace ->
      case state.room.participants {
        // 判定と停止が 1 メッセージに閉じているので join と競合しない。
        // registry は `RoomDown` で登録を外す（ADR 0006）。
        [] -> actor.stop()
        _ -> actor.continue(state)
      }
    GetSnapshot(reply_to) -> {
      process.send(reply_to, snapshot(state.room))
      actor.continue(state)
    }
    GetState(reply_to) -> {
      process.send(reply_to, full_snapshot(state.room, state.instance_id))
      actor.continue(state)
    }
    SessionDown(pid) -> {
      let state =
        remove_displays(state, fn(display) {
          case display.monitor {
            option.Some(#(owner, _)) -> owner == pid
            option.None -> False
          }
        })
      let keys =
        state.members
        |> dict.values
        |> list.filter_map(fn(member) {
          case member.attachment {
            option.Some(Attachment(monitor: option.Some(#(owner, _)), ..))
              if owner == pid
            -> Ok(participant_id_to_string(member.id))
            _ -> Error(Nil)
          }
        })
      case keys {
        // 既に付け替え・退出で監視を外した接続の Down が遅れて届いただけ。
        [] -> {
          logging.log(
            logging.Debug,
            "SessionDown for untracked pid, ignoring: pid="
              <> string.inspect(pid),
          )
          actor.continue(state)
        }
        // 同じ接続プロセスが複数の参加者を持ちうる（#459）。全員を切断中にする。
        _ -> actor.continue(list.fold(keys, state, disconnect))
      }
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

/// A command is accepted only from the participant's current connection
/// (#766). A connection replaced by a resume, or one whose participant has
/// left, cannot buzz, reset or leave on the participant's behalf.
/// `Disconnect`/`Reconnect` are the actor's own transitions and are never
/// accepted from outside.
///
/// A display's connection is not a participant: every command from it is
/// `Forbidden` (#768). Whether the sender may run a host command is decided
/// afterwards by `apply_command`, from the sender's role.
fn authorize(
  state: ActorState,
  command: RoomCommand,
  session: Subject(RoomEvent),
) -> Result(Nil, RoomEvent) {
  let is_display =
    list.any(state.displays, fn(display) { display.session == session })
  case command, is_display {
    Join(..), _ -> Ok(Nil)
    // 内部の遷移。外から送られても受け付けない。
    JoinAsHost(..), _ | HostAway(..), _ -> Error(CommandRejected(Forbidden))
    Disconnect(id), _ | Reconnect(id), _ -> Error(PresenceRejected(id))
    _, True -> Error(CommandRejected(Forbidden))
    Leave(id), False ->
      case is_current_session(state, id, session) {
        True -> Ok(Nil)
        False -> Error(LeaveRejected(id, NotJoined))
      }
    Buzz(id, _), False ->
      case is_current_session(state, id, session) {
        True -> Ok(Nil)
        False -> Error(BuzzRejected(id, BuzzerNotJoined))
      }
    OpenAcceptance(by, _), False
    | CloseAcceptance(by, _), False
    | Skip(by, _), False
    | NextQuestion(by, _), False
    | TransferHost(by, _), False
    | EndSession(by), False
    ->
      case is_current_session(state, by, session) {
        True -> Ok(Nil)
        False -> Error(CommandRejected(CommandNotJoined))
      }
  }
}

fn is_current_session(
  state: ActorState,
  id: ParticipantId,
  session: Subject(RoomEvent),
) -> Bool {
  case dict.get(state.members, participant_id_to_string(id)) {
    Ok(member) -> has_session(member, session)
    Error(Nil) -> False
  }
}

fn has_session(member: Member, session: Subject(RoomEvent)) -> Bool {
  case member.attachment {
    option.Some(attachment) -> attachment.session == session
    option.None -> False
  }
}

/// Applies a command, then updates members and broadcasts, all while handling
/// one mailbox message. The caller sends the reply.
///
/// The caller normally gets the event synchronously through `reply_to`, but
/// `reply_to` is a throwaway subject created per call (`dispatch`'s
/// `call.try_call`): if the caller already gave up on a timeout, that send is
/// silently lost. For `BuzzAccepted`/`RoundReset`, the issuing session is
/// therefore also included in `broadcast` (not excluded), so a late-arriving
/// result still reaches the caller asynchronously through its own subject
/// (#143). Both copies carry the same `revision`, so a client applies the
/// change once (#765). `ParticipantJoined` keeps excluding the issuer: the
/// joiner gets a snapshot that already contains its own join.
fn run_command(
  state: ActorState,
  command: RoomCommand,
  session: Subject(RoomEvent),
) -> #(ActorState, RoomEvent) {
  let #(next_room, event) = apply_command(state.room, command)
  let state = ActorState(..state, room: next_room)
  let state = case event {
    ParticipantJoined(participant, _) ->
      issue_member(state, participant, session)
    ParticipantLeft(id, _) ->
      case dict.get(state.members, participant_id_to_string(id)) {
        Ok(member) -> mark_departed(state, member)
        Error(Nil) -> state
      }
    _ -> state
  }
  broadcast(state, except: session, event: event)
  let state = case event {
    // 司会が自分で退出したら、受付を開いたままにしない（#768）。
    ParticipantLeft(id, _) if command == Leave(id) ->
      case is_seated_host(state, id) {
        True -> host_away(state, True)
        False -> state
      }
    // 役割が移ったことを全員に知らせてから、新しい司会に token を渡す。
    HostTransferred(_, to, _) -> seat_host(state, to)
    _ -> state
  }
  #(state, event)
}

/// Whether `id` holds the host seat (#768). The seat survives the host
/// leaving the participant list, so this is not the same as having the
/// `Host` role in `RoomState`.
fn is_seated_host(state: ActorState, id: ParticipantId) -> Bool {
  case state.host {
    option.Some(seat) -> seat.participant_key == participant_id_to_string(id)
    option.None -> False
  }
}

/// Stops acceptance because the host is gone (#768) and tells everyone.
fn host_away(state: ActorState, include_locked: Bool) -> ActorState {
  case apply_command(state.room, HostAway(include_locked)) {
    #(next_room, PhaseChanged(..) as event) -> {
      let state = ActorState(..state, room: next_room)
      broadcast_to_attached(state, option.None, event)
      state
    }
    _ -> state
  }
}

/// Moves the host seat to `to` with a fresh token and sends it to `to`'s
/// connection only (#768). The previous token stops working.
fn seat_host(state: ActorState, to: ParticipantId) -> ActorState {
  let key = participant_id_to_string(to)
  let display_name =
    list.find(state.room.participants, fn(p) { p.id == to })
    |> result.map(fn(p) { p.display_name })
    |> result.unwrap("")
  let token = random_string()
  case dict.get(state.members, key) {
    Ok(Member(attachment: option.Some(attachment), ..)) ->
      process.send(attachment.session, HostAssigned(token))
    _ -> Nil
  }
  ActorState(
    ..state,
    host: option.Some(HostSeat(token:, participant_key: key, display_name:)),
  )
}

fn remove_displays(
  state: ActorState,
  matches: fn(Attachment) -> Bool,
) -> ActorState {
  let #(removed, kept) = list.partition(state.displays, matches)
  list.each(removed, fn(display) { release_attachment(option.Some(display)) })
  ActorState(..state, displays: kept)
}

/// Registers a newly joined participant: a fresh token, generation 1, and a
/// monitor on the joining connection (#56 / #766).
fn issue_member(
  state: ActorState,
  participant: Participant,
  session: Subject(RoomEvent),
) -> ActorState {
  let key = participant_id_to_string(participant.id)
  let token = random_string()
  let member =
    Member(
      id: participant.id,
      token:,
      generation: 1,
      attachment: option.Some(attach(session, key)),
      departed: False,
      issued: state.next_issue,
    )
  ActorState(
    ..state,
    members: dict.insert(state.members, key, member),
    tokens: dict.insert(state.tokens, token, key),
    next_issue: state.next_issue + 1,
  )
  |> drop_oldest_departed
}

/// Keeps at most `max_tracked_participants` entries by dropping the oldest
/// departed ones. Active participants are capped lower (`max_participants`),
/// so there is always a departed entry to drop.
fn drop_oldest_departed(state: ActorState) -> ActorState {
  case dict.size(state.members) > max_tracked_participants {
    False -> state
    True -> {
      let oldest =
        state.members
        |> dict.values
        // 司会の席の参加者は、一覧から外れていても戻れるので消さない（#768）。
        |> list.filter(fn(member) {
          member.departed && !is_seated_host(state, member.id)
        })
        |> list.sort(fn(a, b) { int.compare(a.issued, b.issued) })
        |> list.first
      case oldest {
        Ok(member) ->
          ActorState(
            ..state,
            members: dict.delete(
              state.members,
              participant_id_to_string(member.id),
            ),
            tokens: dict.delete(state.tokens, member.token),
          )
          |> drop_oldest_departed
        Error(Nil) -> state
      }
    }
  }
}

/// 接続を監視して付ける（#56 / #69）。
///
/// **`process.monitor` を使う。`process.link` ではない**（#69）。link は双方向で、
/// 接続プロセスが 1 つクラッシュすると room actor ごと道連れになり、同室の
/// 全参加者が落ちる。monitor は対象の終了をメッセージで受け取るだけで、
/// 監視元は影響を受けない。
fn attach(session: Subject(RoomEvent), key: String) -> Attachment {
  case process.subject_owner(session) {
    Ok(pid) ->
      Attachment(session:, monitor: option.Some(#(pid, process.monitor(pid))))
    // 所有者が引けないのは想定外だが、監視できないだけで参加は成立する。
    // 切断は Detach でしか分からない参加者になるので、ログだけは残す。
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "subject_owner failed for attaching participant, session not monitored: participant_id="
          <> key,
      )
      Attachment(session:, monitor: option.None)
    }
  }
}

/// 監視を解除する（#69）。残すと、付け替え・退出の後に古い接続プロセスが
/// 終了したとき、無関係な Down 通知が届く。
fn release_attachment(attachment: option.Option(Attachment)) -> Nil {
  case attachment {
    option.Some(Attachment(monitor: option.Some(#(_, monitor)), ..)) ->
      process.demonitor_process(monitor)
    _ -> Nil
  }
}

fn mark_departed(state: ActorState, member: Member) -> ActorState {
  release_attachment(member.attachment)
  let member = Member(..member, attachment: option.None, departed: True)
  ActorState(
    ..state,
    members: dict.insert(
      state.members,
      participant_id_to_string(member.id),
      member,
    ),
  )
}

/// The participant's current connection went away: keep them, marked
/// disconnected, and start a grace timer for this generation (#766).
fn disconnect(state: ActorState, key: String) -> ActorState {
  case dict.get(state.members, key) {
    Ok(member) -> {
      release_attachment(member.attachment)
      let member = Member(..member, attachment: option.None)
      let #(next_room, event) = apply_command(state.room, Disconnect(member.id))
      let state =
        ActorState(
          ..state,
          room: next_room,
          members: dict.insert(state.members, key, member),
        )
      broadcast_to_attached(state, option.None, event)
      process.send_after(
        state.self,
        state.participant_grace_ms,
        GraceExpired(key, member.generation),
      )
      // 司会が切れたら、受付中のまま放置しない（#768）。回答者が決まった
      // 後（Locked）はそのまま残し、戻った司会が続けられるようにする。
      case is_seated_host(state, member.id) {
        True -> host_away(state, False)
        False -> state
      }
    }
    Error(Nil) -> state
  }
}

/// The grace period ran out: remove the participant from presence. Their
/// buzzes stay (ADR 0003, #30) and their token now answers `ResumeExpired`.
fn depart(state: ActorState, member: Member) -> ActorState {
  let #(next_room, event) = apply_command(state.room, Leave(member.id))
  let state = mark_departed(ActorState(..state, room: next_room), member)
  broadcast_to_attached(state, option.None, event)
  state
}

fn resume(
  state: ActorState,
  token: String,
  host_token: option.Option(String),
  instance_id: String,
  session: Subject(RoomEvent),
) -> #(ActorState, ResumeReply) {
  let seat = case state.host, host_token {
    option.Some(seat), option.Some(given) if seat.token == given ->
      option.Some(seat)
    _, _ -> option.None
  }
  let member = case instance_id == state.instance_id, seat {
    False, _ -> Error(RoomGone)
    // 司会は猶予が切れて一覧から外れていても、席の token で戻れる（#768）。
    True, option.Some(seat) ->
      case dict.get(state.members, seat.participant_key) {
        Ok(Member(departed: True, ..) as member) ->
          rejoin_host(state, member, seat, session)
        Ok(member) -> Ok(#(state, member))
        Error(Nil) -> Error(InvalidToken)
      }
    True, option.None ->
      case
        dict.get(state.tokens, token)
        |> result.try(dict.get(state.members, _))
      {
        Error(Nil) -> Error(InvalidToken)
        Ok(Member(departed: True, ..)) -> Error(ResumeExpired)
        Ok(member) -> Ok(#(state, member))
      }
  }
  case member {
    Error(reason) -> #(state, ResumeRejected(reason))
    Ok(#(state, member)) -> {
      let key = participant_id_to_string(member.id)
      // 同じ参加者に付いている接続（複製したタブなど）は外す。新しい方が勝つ。
      case member.attachment {
        option.Some(old) if old.session != session -> {
          release_attachment(member.attachment)
          process.send(old.session, SessionReplaced)
        }
        option.Some(_) -> release_attachment(member.attachment)
        option.None -> Nil
      }
      let member =
        Member(
          ..member,
          generation: member.generation + 1,
          attachment: option.Some(attach(session, key)),
        )
      let state =
        ActorState(..state, members: dict.insert(state.members, key, member))
      // 切断中だった場合だけ状態が変わる。接続中のまま付け替えた場合は
      // 他の参加者から見て何も変わっていない。
      let state = case apply_command(state.room, Reconnect(member.id)) {
        #(next_room, ParticipantReconnected(..) as event) -> {
          let state = ActorState(..state, room: next_room)
          broadcast_to_attached(state, option.Some(session), event)
          state
        }
        _ -> state
      }
      #(state, Resumed(member.id, full_snapshot(state.room, state.instance_id)))
    }
  }
}

/// Puts the host back on the participant list after their grace ran out or
/// they left (#768). The rest of `resume` then attaches the connection.
fn rejoin_host(
  state: ActorState,
  member: Member,
  seat: HostSeat,
  session: Subject(RoomEvent),
) -> Result(#(ActorState, Member), ResumeRejectReason) {
  case apply_command(state.room, JoinAsHost(member.id, seat.display_name)) {
    #(next_room, ParticipantJoined(..) as event) -> {
      let member = Member(..member, departed: False)
      let state =
        ActorState(
          ..state,
          room: next_room,
          members: dict.insert(state.members, seat.participant_key, member),
        )
      broadcast_to_attached(state, option.Some(session), event)
      Ok(#(state, member))
    }
    // 満員・終了済みなど。司会として戻れる場所が無い。
    _ -> Error(ResumeExpired)
  }
}

/// Notifies attached connections about a state change. `BuzzAccepted`/
/// `RoundReset` reach every connection, *including* the one that issued the
/// command (#143: the issuing session's synchronous `reply_to` can be lost on
/// a `dispatch` timeout, so it must also be reachable asynchronously).
/// `ParticipantJoined`/`ParticipantLeft` exclude the issuer (the joiner gets a
/// snapshot; a leaver is no longer attached). Rejections are not broadcast:
/// they carry no state change and are only meaningful to the issuing
/// session, which always gets them synchronously through `reply_to`.
fn broadcast(
  state: ActorState,
  except except_session: Subject(RoomEvent),
  event event: RoomEvent,
) -> Nil {
  case event {
    BuzzAccepted(..)
    | RoundReset(..)
    | PhaseChanged(..)
    | HostTransferred(..) -> broadcast_to_attached(state, option.None, event)
    ParticipantJoined(..)
    | ParticipantLeft(..)
    | ParticipantDisconnected(..)
    | ParticipantReconnected(..) ->
      broadcast_to_attached(state, option.Some(except_session), event)
    JoinRejected(_, _)
    | LeaveRejected(_, _)
    | BuzzRejected(_, _)
    | CommandRejected(_)
    | PresenceRejected(_)
    | SessionReplaced
    | HostAssigned(_) -> Nil
  }
}

fn broadcast_to_attached(
  state: ActorState,
  except: option.Option(Subject(RoomEvent)),
  event: RoomEvent,
) -> Nil {
  dict.each(state.members, fn(_key, member) {
    case member.attachment {
      option.Some(Attachment(session:, ..)) ->
        case except == option.Some(session) {
          True -> Nil
          False -> process.send(session, event)
        }
      option.None -> Nil
    }
  })
  // 会場表示は何も送らないので、自分の操作の配信を除く必要は無い（#768）。
  list.each(state.displays, fn(display) { process.send(display.session, event) })
}

/// Sends a command to a running room actor and waits for the resulting
/// event. A 1000ms timeout is used so a stuck actor surfaces as a crash
/// rather than an indefinite hang. `session` identifies the caller's own
/// subject so future events for this room can be delivered asynchronously.
/// コマンドを送り、結果のイベントを待つ。
///
/// アクターが応答しない場合は `Error(Nil)`（#33）。以前は `actor.call` を
/// 直接呼んでおり、タイムアウトで**呼び出し元プロセスごとクラッシュ**していた。
pub fn dispatch(
  subject: Subject(Message),
  command: RoomCommand,
  session: Subject(RoomEvent),
) -> Result(RoomEvent, Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    Dispatch(command, session, _),
    "room.dispatch",
  )
}

/// Reads the current participant list from a running room actor.
pub fn get_snapshot(
  subject: Subject(Message),
) -> Result(List(Participant), Nil) {
  call.try_call(subject, call.default_timeout, GetSnapshot, "room.get_snapshot")
}

/// Reads the whole room at its current revision in one call, so participants
/// and buzzes reflect the same `RoomState` (#121, #765).
pub fn get_state(subject: Subject(Message)) -> Result(Snapshot, Nil) {
  call.try_call(subject, call.default_timeout, GetState, "room.get_state")
}

/// Joins and returns the resulting event together with a snapshot taken in
/// the same mailbox message (#765) and the joiner's resume token (#766).
/// See `JoinWithSnapshot`.
pub fn join(
  subject: Subject(Message),
  id: ParticipantId,
  display_name: String,
  session: Subject(RoomEvent),
) -> Result(JoinReply, Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    JoinWithSnapshot(id, display_name, session, False, _),
    "room.join",
  )
}

/// `join` for the connection that just created the room (#767): the joiner
/// also gets the host token if the room has no host yet.
pub fn join_as_creator(
  subject: Subject(Message),
  id: ParticipantId,
  display_name: String,
  session: Subject(RoomEvent),
) -> Result(JoinReply, Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    JoinWithSnapshot(id, display_name, session, True, _),
    "room.join",
  )
}

/// Re-attaches an existing participant to the connection owning `session`
/// (#766). See `Resume`.
pub fn resume_session(
  subject: Subject(Message),
  token: String,
  host_token: option.Option(String),
  instance_id: String,
  session: Subject(RoomEvent),
) -> Result(ResumeReply, Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    Resume(token, host_token, instance_id, session, _),
    "room.resume",
  )
}

/// Starts receiving the room's changes as a display (#768). See `Watch`.
pub fn watch(
  subject: Subject(Message),
  session: Subject(RoomEvent),
) -> Result(WatchReply, Nil) {
  call.try_call(subject, call.default_timeout, Watch(session, _), "room.watch")
}

/// Tells the room that a display's connection closed (#768). Asynchronous,
/// like `detach`.
pub fn unwatch(subject: Subject(Message), session: Subject(RoomEvent)) -> Nil {
  process.send(subject, Unwatch(session))
}

/// Tells the room that the connection owning `session` closed (#766).
/// Asynchronous: a closing connection has nothing to wait for, and a stale
/// `Detach` is ignored by the room.
pub fn detach(
  subject: Subject(Message),
  id: ParticipantId,
  session: Subject(RoomEvent),
) -> Nil {
  process.send(subject, Detach(id, session))
}

/// 無人なら room を停止させ、停止したかどうかを返す（#36）。
///
/// 判定と停止が room actor の 1 メッセージに閉じているため、呼び出し側が
/// 「空か確認 → 停止を依頼」と 2 段階で行ったときのレースが起きない。
/// 応答しない room は「停止しなかった」扱いにする（#33）。
/// registry の登録を外さないので、死んだ room は #39 の経路で片付く。
pub fn shutdown_if_empty(subject: Subject(Message)) -> Bool {
  case
    call.try_call(
      subject,
      call.default_timeout,
      ShutdownIfEmpty,
      "room.shutdown_if_empty",
    )
  {
    Ok(stopped) -> stopped
    Error(Nil) -> False
  }
}
