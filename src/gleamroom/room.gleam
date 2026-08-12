import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleamroom/call

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
  /// 参加者の接続プロセスが死んだときに届く（#56 / #35）。
  ///
  /// 参加者は WebSocket の接続プロセスと 1 対 1 で対応する。接続が死んだのに
  /// Leave が届かない経路が複数ある:
  ///
  ///   - `Join` がタイムアウトし、**遅れて成立した**（接続側は自分が参加者だと
  ///     知らないので Leave を送れない、#33）
  ///   - 接続プロセスがクラッシュした
  ///   - 突然の切断で `on_close` が走らなかった（#35）
  ///
  /// 原因ごとに塞ぐより「**接続が死んだら参加者も消える**」という不変条件を
  /// 1 つ置くほうが確実。監視は join を受けた時点で張る。
  SessionDown(pid: process.Pid)
}

/// The actor's own state: the domain `RoomState` plus the set of connected
/// sessions to notify when membership changes. Kept separate from
/// `RoomState` so the pure state transitions stay testable without a
/// process or a notion of "subscriber".
type ActorState {
  ActorState(
    room: RoomState,
    subscribers: Dict(String, Subject(RoomEvent)),
    /// 監視中の接続プロセス pid → (ParticipantId の文字列表現, Monitor)（#56 / #69）。
    ///
    /// Down メッセージは pid しか運ばないため逆引きが要る。Monitor を併せて
    /// 持つのは、離脱時に `demonitor_process` で解除するため。解除しないと
    /// Leave 後も監視が残り、その接続プロセスが後から終了したときに
    /// 無関係な Down 通知が届く。
    sessions: Dict(process.Pid, #(String, process.Monitor)),
  )
}

/// Starts one isolated room actor with empty state. Each call produces an
/// independent process with its own mailbox, so multiple rooms never share
/// participant state (ADR 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    // 接続プロセスの死を signal ではなくメッセージとして受ける（#56）。
    // trap しないと、監視対象の異常終了が room を道連れにする。
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
          // Port は監視していない。自分の pid を返せば sessions に一致する
          // エントリが無いので実質 no-op になる。
          process.PortDown(..) -> SessionDown(process.self())
        }
      })
    actor.initialised(ActorState(
      room: new_state(),
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
      let #(next_room, event) = apply_command(state.room, command)
      let next_subscribers =
        update_subscribers(state.subscribers, event, session)
      let next_sessions = update_sessions(state.sessions, event, session)
      // The caller always gets the event synchronously through `reply_to`;
      // other connected sessions learn about it asynchronously through
      // their own subject so they observe consistent room state.
      process.send(reply_to, event)
      broadcast(next_subscribers, except: session, event: event)
      actor.continue(ActorState(
        room: next_room,
        subscribers: next_subscribers,
        sessions: next_sessions,
      ))
    }
    GetSnapshot(reply_to) -> {
      process.send(reply_to, snapshot(state.room))
      actor.continue(state)
    }
    GetBuzzSnapshot(reply_to) -> {
      process.send(reply_to, buzz_snapshot(state.room))
      actor.continue(state)
    }
    SessionDown(pid) ->
      case dict.get(state.sessions, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(#(participant_key, _monitor)) -> {
          // 接続が死んだ参加者を Leave 相当で片付ける（#56）。
          // 通常の Leave と同じ経路を通すので、他の参加者にも
          // ParticipantLeft が配信される。
          let id = ParticipantId(participant_key)
          let #(next_room, event) = apply_command(state.room, Leave(id))
          let next_subscribers = dict.delete(state.subscribers, participant_key)
          broadcast_all(next_subscribers, event)
          case next_room.participants {
            // **無人になったら自分で止まる（#91）。**
            //
            // 参加者が抜ける経路は 2 つある。通常の切断は websocket の
            // `on_close` が `registry.Release` を送って掃除するが、
            // **突然の切断で `on_close` が走らなかった場合はここしか通らない**
            // （#35 がこの経路を導入した理由そのもの）。room actor は自分を
            // 登録している registry を知らないので Release は送れず、
            // 放置すると空の room actor と registry の Dict エントリが
            // 再起動まで残る。
            //
            // 止まれば registry の `RoomDown`（#39 の trap_exits 経路）が
            // 拾って登録を外す。**正常停止でも RoomDown が発火することは
            // 実際に確かめた**（クラッシュ時だけの経路ではない）。
            //
            // 判定と停止を **1 メッセージに閉じている**ので、`ShutdownIfEmpty`
            // （#36）と同じ理由でレースが無い。room のメールボックスは直列なので、
            // 空だと判定した瞬間に join が割り込むことはない。
            [] -> actor.stop()
            _ ->
              actor.continue(ActorState(
                room: next_room,
                subscribers: next_subscribers,
                sessions: dict.delete(state.sessions, pid),
              ))
          }
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

/// 参加時に接続プロセスを監視対象へ入れ、離脱時に外す（#56）。
///
/// 監視するのは room 側だけ。接続プロセスは room の生死を気にしないが、
/// room は接続の生死を知る必要がある（片方向の関心）。
///
/// **`process.monitor` を使う。`process.link` ではない**（#69）。link は双方向で、
/// 接続プロセスが 1 つクラッシュすると room actor ごと道連れになり、同室の
/// 全参加者が落ちる。monitor は対象の終了をメッセージで受け取るだけで、
/// 監視元は影響を受けない。
fn update_sessions(
  sessions: Dict(process.Pid, #(String, process.Monitor)),
  event: RoomEvent,
  session: Subject(RoomEvent),
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
        // 所有者が引けないのは想定外だが、監視できないだけで参加は成立する。
        Error(Nil) -> sessions
      }
    ParticipantLeft(id) -> {
      let key = participant_id_to_string(id)
      // 値（ParticipantId）で引いて外す。pid は Down 側でしか分からない。
      // **監視も解除する**（#69）。残すと、Leave 後も生きている接続プロセスが
      // 後から終了したときに無関係な Down 通知が届く。
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
    | BuzzAccepted(_, _)
    | BuzzRejected(_, _)
    | RoundReset -> sessions
  }
}

/// 全購読者へ配信する（除外なし）。接続が死んだ参加者の離脱を知らせるのに使う。
fn broadcast_all(
  subscribers: Dict(String, Subject(RoomEvent)),
  event: RoomEvent,
) -> Nil {
  dict.each(subscribers, fn(_key, subscriber) {
    process.send(subscriber, event)
  })
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

/// Reads the current round's accepted buzzes from a running room actor.
pub fn get_buzz_snapshot(
  subject: Subject(Message),
) -> Result(List(BuzzResult), Nil) {
  call.try_call(
    subject,
    call.default_timeout,
    GetBuzzSnapshot,
    "room.get_buzz_snapshot",
  )
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
