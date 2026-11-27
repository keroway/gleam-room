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

/// `connected` is False while the participant's connection is gone but the
/// participant is still within the resume grace period (#766). They keep
/// their id, buzzes and place in the list until the grace expires.
pub type Participant {
  Participant(id: ParticipantId, display_name: String, connected: Bool)
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
  )
}

pub fn new_state() -> RoomState {
  RoomState(participants: [], buzzes: [], round_id: 1, revision: 0)
}

/// `Buzz` and `ResetRound` name the round the client saw. A command for any
/// other round is rejected, so a button pressed on an outdated screen cannot
/// affect a newer round (#765).
pub type RoomCommand {
  Join(id: ParticipantId, display_name: String)
  Leave(id: ParticipantId)
  Buzz(id: ParticipantId, round_id: Int)
  ResetRound(round_id: Int)
  /// The participant's connection went away. They stay in the room, marked
  /// disconnected, until they resume or the grace period expires (#766).
  /// Issued only by the actor itself, never accepted through `dispatch`.
  Disconnect(id: ParticipantId)
  /// A disconnected participant attached a new connection (#766). Issued
  /// only by the actor itself.
  Reconnect(id: ParticipantId)
}

pub type JoinRejectReason {
  AlreadyJoined
  InvalidDisplayName
  RoomFull
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
}

pub type ResetRejectReason {
  /// The reset named a round that is not the current one, e.g. another
  /// participant already reset it (#765).
  ResetStaleRound
  /// The reset came from a connection that is not any participant's current
  /// connection, e.g. one replaced by a resume (#766).
  ResetNotJoined
}

/// Accepted events carry the `revision` they produced (#765); rejections
/// carry none because they change nothing.
pub type RoomEvent {
  ParticipantJoined(participant: Participant, revision: Int)
  JoinRejected(id: ParticipantId, reason: JoinRejectReason)
  ParticipantLeft(id: ParticipantId, revision: Int)
  LeaveRejected(id: ParticipantId, reason: LeaveRejectReason)
  BuzzAccepted(
    id: ParticipantId,
    display_name: String,
    position: Int,
    round_id: Int,
    revision: Int,
  )
  BuzzRejected(id: ParticipantId, reason: BuzzRejectReason)
  /// `round_id` is the new round that starts with this reset.
  RoundReset(round_id: Int, revision: Int)
  ResetRejected(reason: ResetRejectReason)
  ParticipantDisconnected(id: ParticipantId, revision: Int)
  ParticipantReconnected(id: ParticipantId, revision: Int)
  /// `Disconnect`/`Reconnect` did not apply (unknown participant, or already
  /// in that state). Never broadcast.
  PresenceRejected(id: ParticipantId)
  /// Sent only to a connection whose participant was resumed by a newer
  /// connection (#766). The receiver must stop using the room. Never
  /// broadcast, and carries no state change.
  SessionReplaced
}

/// A consistent view of the room at one revision: what a joining or
/// resyncing client starts from (#765). `instance_id` tells a room apart from
/// an earlier room with the same code.
pub type Snapshot {
  Snapshot(
    instance_id: String,
    round_id: Int,
    revision: Int,
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
    Join(id, display_name) -> apply_join(state, id, display_name)
    Leave(id) -> apply_leave(state, id)
    Buzz(id, round_id) -> apply_buzz(state, id, round_id)
    ResetRound(round_id) -> apply_reset_round(state, round_id)
    Disconnect(id) -> apply_presence(state, id, False)
    Reconnect(id) -> apply_presence(state, id, True)
  }
}

fn next_revision(state: RoomState) -> Int {
  state.revision + 1
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
/// `RoundFull` until `ResetRound`; existing positions never change.
const max_buzzes_per_round = 128

fn apply_join(
  state: RoomState,
  id: ParticipantId,
  display_name: String,
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
    Error(Nil), True, True -> #(state, JoinRejected(id, RoomFull))
    Error(Nil), True, False -> {
      let participant = Participant(id, display_name, connected: True)
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
    // Unreachable from the current websocket layer: Leave is only sent from
    // `on_close` when `state.room` holds the handle from a prior successful
    // Join, so the id is always still a participant. Kept as a defensive
    // branch for a future explicit "leave without disconnecting" protocol
    // message, which does not exist yet (#52).
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

/// Accepts at most one buzz per participant per round. Ordering comes from
/// the Room actor's mailbox processing order (one command at a time), so no
/// client-supplied or wall-clock timestamp is ever consulted to decide who
/// was first.
fn apply_buzz(
  state: RoomState,
  id: ParticipantId,
  round_id: Int,
) -> #(RoomState, RoomEvent) {
  case find_participant(state, id) {
    // Unreachable from the current websocket layer: Buzz is only sent when
    // `state.room` holds the handle from a prior successful Join, so the id
    // is always still a participant. Kept as a defensive branch for the same
    // reason as `apply_leave`'s NotJoined branch above (#52).
    Error(Nil) -> #(state, BuzzRejected(id, BuzzerNotJoined))
    Ok(_) if round_id != state.round_id -> #(
      state,
      BuzzRejected(id, BuzzStaleRound),
    )
    Ok(participant) ->
      case has_buzzed(state, id) {
        True -> #(state, BuzzRejected(id, AlreadyBuzzed))
        False ->
          case list.length(state.buzzes) >= max_buzzes_per_round {
            True -> #(state, BuzzRejected(id, RoundFull))
            False -> {
              let position = list.length(state.buzzes) + 1
              let revision = next_revision(state)
              let next =
                RoomState(
                  ..state,
                  buzzes: [
                    BuzzResult(id, participant.display_name, position),
                    ..state.buzzes
                  ],
                  revision:,
                )
              #(
                next,
                BuzzAccepted(
                  id,
                  participant.display_name,
                  position,
                  state.round_id,
                  revision,
                ),
              )
            }
          }
      }
  }
}

/// Only the round the client saw can be reset. Two participants pressing
/// reset at once therefore start exactly one new round; the second gets
/// `ResetStaleRound` instead of wiping the buzzes of the round that just began
/// (#765).
fn apply_reset_round(
  state: RoomState,
  round_id: Int,
) -> #(RoomState, RoomEvent) {
  case round_id == state.round_id {
    False -> #(state, ResetRejected(ResetStaleRound))
    True -> {
      let next_round = state.round_id + 1
      let revision = next_revision(state)
      #(
        RoomState(..state, buzzes: [], round_id: next_round, revision:),
        RoundReset(next_round, revision),
      )
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
    participants: snapshot(state),
    buzzes: buzz_snapshot(state),
  )
}

/// How long a disconnected participant can resume before they are removed
/// (#766, ADR 0010). Counted from when the room learns of the disconnect.
pub const default_participant_grace_ms = 60_000

/// Ceiling on participants a room keeps track of, including those who already
/// left (their token then answers `ResumeExpired`). Departed entries beyond it
/// are dropped oldest first, so churn cannot grow the room without bound
/// (#766, docs/buzzer-session.md "Limits").
const max_tracked_participants = 128

/// The answer to `join`: the event, a snapshot taken in the same mailbox
/// message (#765), and the resume token issued to the joiner (#766). The
/// token is `None` when the join was rejected. It must reach only the joining
/// client: it is never broadcast or logged.
pub type JoinReply {
  JoinReply(
    event: RoomEvent,
    snapshot: Snapshot,
    resume_token: option.Option(String),
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
  JoinWithSnapshot(
    id: ParticipantId,
    display_name: String,
    session: Subject(RoomEvent),
    reply_to: Subject(JoinReply),
  )
  /// 既存の参加者として新しい接続を付け直す（#766）。`instance_id` は
  /// クライアントが前回受け取った room の世代で、違えば `RoomGone`。
  /// 同じ参加者に別の接続が付いていれば、それを `SessionReplaced` で外す。
  Resume(
    token: String,
    instance_id: String,
    session: Subject(RoomEvent),
    reply_to: Subject(ResumeReply),
  )
  /// 接続が閉じた（#766）。`session` がその参加者の現在の接続のときだけ
  /// 切断中にして猶予タイマーを始める。古い接続からの遅れた通知は無視する。
  Detach(id: ParticipantId, session: Subject(RoomEvent))
  /// 猶予タイマーの満了（#766）。`generation` が現在の接続世代と一致し、
  /// まだ切断中のときだけ参加者を外す。復帰後に届いた古いタイマーは無視する。
  GraceExpired(participant_key: String, generation: Int)
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
  )
}

/// Starts one isolated room actor with empty state. Each call produces an
/// independent process with its own mailbox, so multiple rooms never share
/// participant state (ADR 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  start_with_grace(default_participant_grace_ms)
}

/// `start` with a different resume grace period. Production always uses
/// `start`; tests use this to observe grace expiry without waiting a minute.
pub fn start_with_grace(
  participant_grace_ms: Int,
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
    actor.initialised(ActorState(
      self: subject,
      instance_id: random_string(),
      room: new_state(),
      participant_grace_ms:,
      members: dict.new(),
      tokens: dict.new(),
      next_issue: 0,
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

/// 128-bit random, URL-safe. Used for the room instance id and resume tokens.
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
    JoinWithSnapshot(id, display_name, session, reply_to) -> {
      let #(next_state, event) =
        run_command(state, Join(id, display_name), session)
      let resume_token = case event {
        ParticipantJoined(participant, _) ->
          dict.get(next_state.members, participant_id_to_string(participant.id))
          |> option.from_result
          |> option.map(fn(member) { member.token })
        _ -> option.None
      }
      process.send(
        reply_to,
        JoinReply(
          event,
          full_snapshot(next_state.room, next_state.instance_id),
          resume_token,
        ),
      )
      actor.continue(next_state)
    }
    Resume(token, instance_id, session, reply_to) -> {
      let #(next_state, reply) = resume(state, token, instance_id, session)
      process.send(reply_to, reply)
      actor.continue(next_state)
    }
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
    GetSnapshot(reply_to) -> {
      process.send(reply_to, snapshot(state.room))
      actor.continue(state)
    }
    GetState(reply_to) -> {
      process.send(reply_to, full_snapshot(state.room, state.instance_id))
      actor.continue(state)
    }
    SessionDown(pid) -> {
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
fn authorize(
  state: ActorState,
  command: RoomCommand,
  session: Subject(RoomEvent),
) -> Result(Nil, RoomEvent) {
  case command {
    Join(..) -> Ok(Nil)
    Leave(id) ->
      case is_current_session(state, id, session) {
        True -> Ok(Nil)
        False -> Error(LeaveRejected(id, NotJoined))
      }
    Buzz(id, _) ->
      case is_current_session(state, id, session) {
        True -> Ok(Nil)
        False -> Error(BuzzRejected(id, BuzzerNotJoined))
      }
    ResetRound(_) ->
      case
        dict.values(state.members)
        |> list.any(fn(member) { has_session(member, session) })
      {
        True -> Ok(Nil)
        False -> Error(ResetRejected(ResetNotJoined))
      }
    Disconnect(id) | Reconnect(id) -> Error(PresenceRejected(id))
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
  #(state, event)
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
        |> list.filter(fn(member) { member.departed })
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
      state
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
  instance_id: String,
  session: Subject(RoomEvent),
) -> #(ActorState, ResumeReply) {
  let member = case instance_id == state.instance_id {
    False -> Error(RoomGone)
    True ->
      case
        dict.get(state.tokens, token)
        |> result.try(dict.get(state.members, _))
      {
        Error(Nil) -> Error(InvalidToken)
        Ok(Member(departed: True, ..)) -> Error(ResumeExpired)
        Ok(member) -> Ok(member)
      }
  }
  case member {
    Error(reason) -> #(state, ResumeRejected(reason))
    Ok(member) -> {
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
    BuzzAccepted(..) | RoundReset(..) ->
      broadcast_to_attached(state, option.None, event)
    ParticipantJoined(..)
    | ParticipantLeft(..)
    | ParticipantDisconnected(..)
    | ParticipantReconnected(..) ->
      broadcast_to_attached(state, option.Some(except_session), event)
    JoinRejected(_, _)
    | LeaveRejected(_, _)
    | BuzzRejected(_, _)
    | ResetRejected(_)
    | PresenceRejected(_)
    | SessionReplaced -> Nil
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
    JoinWithSnapshot(id, display_name, session, _),
    "room.join",
  )
}

/// Re-attaches an existing participant to the connection owning `session`
/// (#766). See `Resume`.
pub fn resume_session(
  subject: Subject(Message),
  token: String,
  instance_id: String,
  session: Subject(RoomEvent),
) -> Result(ResumeReply, Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    Resume(token, instance_id, session, _),
    "room.resume",
  )
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
