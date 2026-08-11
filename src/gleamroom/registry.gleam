import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleamroom/room

/// Opaque so callers cannot construct a `RoomId` except through `room_id`,
/// keeping lookups keyed on a single explicit constructor.
pub opaque type RoomId {
  RoomId(String)
}

pub fn room_id(value: String) -> RoomId {
  RoomId(value)
}

fn room_id_to_string(id: RoomId) -> String {
  let RoomId(value) = id
  value
}

pub type Message {
  Lookup(id: RoomId, reply_to: Subject(Subject(room.Message)))
}

type State =
  Dict(String, Subject(room.Message))

/// Starts one registry actor with no known rooms. Lookups are handled
/// sequentially by this single process, so concurrent lookups for the same
/// `RoomId` cannot race into starting two authoritative room actors (ADR
/// 0002).
pub fn start() -> actor.StartResult(Subject(Message)) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Lookup(id, reply_to) -> {
      let key = room_id_to_string(id)
      case dict.get(state, key) {
        Ok(subject) -> {
          process.send(reply_to, subject)
          actor.continue(state)
        }
        Error(Nil) -> {
          let assert Ok(started) = room.start()
          let subject = started.data
          process.send(reply_to, subject)
          actor.continue(dict.insert(state, key, subject))
        }
      }
    }
  }
}

/// Resolves `id` to its active room actor, lazily starting one if this is
/// the first lookup for that `RoomId`.
pub fn lookup(subject: Subject(Message), id: RoomId) -> Subject(room.Message) {
  actor.call(subject, waiting: 1000, sending: Lookup(id, _))
}
