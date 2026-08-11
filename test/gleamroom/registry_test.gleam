import gleam/erlang/process
import gleam/list
import gleamroom/registry
import gleamroom/room

pub fn repeated_lookup_resolves_to_same_room_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-1")

  let first = registry.lookup(started.data, id)
  let second = registry.lookup(started.data, id)

  assert first == second
}

pub fn different_room_ids_resolve_to_isolated_rooms_test() {
  let assert Ok(started) = registry.start()
  let room_a = registry.lookup(started.data, registry.room_id("room-a"))
  let room_b = registry.lookup(started.data, registry.room_id("room-b"))
  let alice = room.participant_id("p1")

  let _ = room.dispatch(room_a, room.Join(alice, "Alice"))

  assert room.get_snapshot(room_a) == [room.Participant(alice, "Alice")]
  assert room.get_snapshot(room_b) == []
}

pub fn concurrent_lookups_for_the_same_room_id_agree_on_one_actor_test() {
  let assert Ok(started) = registry.start()
  let id = registry.room_id("room-concurrent")
  let results = process.new_subject()

  list.each(list.repeat(Nil, 20), fn(_) {
    process.spawn(fn() {
      let subject = registry.lookup(started.data, id)
      process.send(results, subject)
    })
  })

  let subjects =
    list.repeat(Nil, 20)
    |> list.map(fn(_) {
      let assert Ok(subject) = process.receive(results, 1000)
      subject
    })

  let unique = list.unique(subjects)
  assert unique == [registry.lookup(started.data, id)]
}
