import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleamroom/call
import gleamroom/poker
import gleamroom/poker_registry
import gleamroom/wait

pub fn repeated_lookup_resolves_to_same_room_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-1")

  let assert Ok(first) = poker_registry.lookup(started.data, id)
  let assert Ok(second) = poker_registry.lookup(started.data, id)

  assert first == second
}

pub fn different_room_ids_resolve_to_isolated_rooms_test() {
  let assert Ok(started) = poker_registry.start()
  let assert Ok(room_a) =
    poker_registry.lookup(started.data, poker_registry.room_id("room-a"))
  let assert Ok(room_b) =
    poker_registry.lookup(started.data, poker_registry.room_id("room-b"))
  let alice = poker.participant_id("p1")
  let session = process.new_subject()

  let assert Ok(_) = poker.dispatch(room_a, poker.Join(alice, "Alice"), session)

  let assert Ok(state_a) = poker.get_state(room_a)
  assert state_a.participants == [poker.Participant(alice, "Alice")]
  let assert Ok(state_b) = poker.get_state(room_b)
  assert state_b.participants == []
}

pub fn concurrent_lookups_for_the_same_room_id_agree_on_one_actor_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-concurrent")
  let results = process.new_subject()

  list.each(list.repeat(Nil, 20), fn(_) {
    process.spawn(fn() {
      let assert Ok(subject) = poker_registry.lookup(started.data, id)
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
  assert unique == [registry_subject_of(started.data, id)]
}

pub fn release_removes_an_unjoined_room_so_the_next_lookup_starts_a_fresh_actor_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-release")

  let assert Ok(first) = poker_registry.lookup(started.data, id)
  assert registry_subject_of(started.data, id) == first

  process.send(started.data, poker_registry.Release(id, first))
  wait.until(
    fn() { registry_subject_of(started.data, id) != first },
    "release が処理され新しい room に置き換わる",
  )

  let assert Ok(second) = poker_registry.lookup(started.data, id)
  assert second != first
}

/// 登録中のものと違う subject を渡した Release は無視すること（ABA ガード、
/// `registry_test.gleam` と同じ理由 #26）。
pub fn release_with_a_stale_subject_does_not_remove_the_current_room_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-release-stale")

  let assert Ok(old) = poker_registry.lookup(started.data, id)
  process.send(started.data, poker_registry.Release(id, old))
  wait.until(
    fn() { registry_subject_of(started.data, id) != old },
    "最初の release が処理され新しい room に置き換わる",
  )
  let assert Ok(current) = poker_registry.lookup(started.data, id)

  process.send(started.data, poker_registry.Release(id, old))

  assert registry_subject_of(started.data, id) == current
}

pub fn release_stops_the_room_actor_process_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-release-stops")

  let assert Ok(subject) = poker_registry.lookup(started.data, id)
  let assert Ok(pid) = process.subject_owner(subject)
  assert process.is_alive(pid)

  process.send(started.data, poker_registry.Release(id, subject))
  wait.until_dead(pid, "空の room が停止する")

  assert !process.is_alive(pid)
}

pub fn a_delayed_room_down_does_not_remove_a_recreated_room_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-delayed-down")

  let assert Ok(old) = poker_registry.lookup(started.data, id)
  let assert Ok(old_pid) = process.subject_owner(old)

  process.send(started.data, poker_registry.Release(id, old))
  wait.until(
    fn() { registry_subject_of(started.data, id) != old },
    "release が処理され新しい room に置き換わる",
  )
  let assert Ok(current) = poker_registry.lookup(started.data, id)

  process.send(started.data, poker_registry.RoomDown(old_pid))

  assert registry_subject_of(started.data, id) == current
}

pub fn release_does_not_stop_a_room_that_gained_a_participant_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-race")

  let assert Ok(subject) = poker_registry.lookup(started.data, id)
  let assert Ok(pid) = process.subject_owner(subject)

  let session = process.new_subject()
  let joiner = poker.participant_id("late-joiner")
  let assert Ok(_) =
    poker.dispatch(subject, poker.Join(joiner, "late"), session)

  process.send(started.data, poker_registry.Release(id, subject))
  process.sleep(100)

  let assert Ok(after) = poker_registry.lookup(started.data, id)

  assert process.is_alive(pid)
  assert after == subject
  let assert Ok(state) = poker.get_state(subject)
  assert state.participants != []
}

fn registry_subject_of(
  registry_subject: process.Subject(poker_registry.Message),
  id: poker_registry.RoomId,
) -> process.Subject(poker.Message) {
  let assert Ok(subject) = poker_registry.lookup(registry_subject, id)
  subject
}

pub fn a_room_start_failure_does_not_crash_the_registry_test() {
  let assert Ok(started) =
    poker_registry.start_with_room_starter(fn() {
      Error(actor.InitFailed("boom"))
    })
  let assert Ok(registry_pid) = process.subject_owner(started.data)

  assert poker_registry.lookup(
      started.data,
      poker_registry.room_id("room-fails"),
    )
    == Error(Nil)

  assert process.is_alive(registry_pid)

  assert poker_registry.lookup(
      started.data,
      poker_registry.room_id("room-other"),
    )
    == Error(Nil)
  assert process.is_alive(registry_pid)
}

pub fn a_crashed_room_is_removed_from_the_registry_test() {
  let assert Ok(started) = poker_registry.start()
  let id = poker_registry.room_id("room-crash")

  let before = registry_subject_of(started.data, id)
  let assert Ok(pid) = process.subject_owner(before)

  process.kill(pid)
  wait.until_dead(pid, "room actor が終了する")

  let after = registry_subject_of(started.data, id)
  assert after != before

  let assert Ok(after_pid) = process.subject_owner(after)
  assert process.is_alive(after_pid)
  let assert Ok(state) = poker.get_state(after)
  assert state.participants == []
}

pub fn lookup_returns_error_instead_of_crashing_the_caller_test() {
  let unresponsive: process.Subject(poker_registry.Message) =
    process.new_subject()

  assert poker_registry.lookup(unresponsive, poker_registry.room_id("stalled"))
    == Error(Nil)

  let assert Ok(started) = poker_registry.start()
  let assert Ok(_) =
    poker_registry.lookup(started.data, poker_registry.room_id("ok"))
}

pub fn a_room_emptied_by_a_dead_session_is_removed_from_the_registry_test() {
  let assert Ok(started) = poker_registry.start()
  let reg = started.data
  let id = poker_registry.room_id("room-session-down")

  let assert Ok(subject) = poker_registry.lookup(reg, id)
  let assert Ok(room_pid) = process.subject_owner(subject)

  let ready = process.new_subject()
  let session_pid =
    process.spawn_unlinked(fn() {
      let session = process.new_subject()
      let joiner = poker.participant_id("doomed")
      let assert Ok(_) =
        poker.dispatch(subject, poker.Join(joiner, "doomed"), session)
      process.send(ready, Nil)
      process.sleep(5000)
    })
  let assert Ok(Nil) = process.receive(ready, 1000)

  process.kill(session_pid)
  wait.until_dead(room_pid, "空になった room が停止する")

  let assert Ok(after) = poker_registry.lookup(reg, id)
  assert after != subject
}

pub fn lookup_rejects_new_rooms_once_max_rooms_is_reached_test() {
  let assert Ok(started) = poker_registry.start_with_max_rooms(1)
  let reg = started.data

  let assert Ok(_) =
    poker_registry.lookup(reg, poker_registry.room_id("room-a"))

  assert poker_registry.lookup(reg, poker_registry.room_id("room-b"))
    == Error(Nil)
}

pub fn lookup_still_resolves_an_existing_room_once_max_rooms_is_reached_test() {
  let assert Ok(started) = poker_registry.start_with_max_rooms(1)
  let reg = started.data

  let assert Ok(first) =
    poker_registry.lookup(reg, poker_registry.room_id("room-a"))
  assert poker_registry.lookup(reg, poker_registry.room_id("room-b"))
    == Error(Nil)

  assert poker_registry.lookup(reg, poker_registry.room_id("room-a"))
    == Ok(first)
}

/// 親（supervisor 相当）からの `exit(RegistryPid, shutdown)` を受けた
/// registry が、無視せず即座に自ら終了すること（`registry_test.gleam` と
/// 同じ理由 #117）。
pub fn parent_shutdown_stops_the_registry_promptly_test() {
  let name = process.new_name("poker_registry_test_parent_shutdown")
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(_) = poker_registry.start_named(name)
    process.send(ready, Nil)
    process.sleep(3000)
  })
  let assert Ok(Nil) = process.receive(ready, 1000)

  let reg = process.named_subject(name)
  let assert Ok(pid) = process.subject_owner(reg)

  process.send_abnormal_exit(pid, atom.create("shutdown"))

  wait.until_dead(pid, "shutdown要求を受けたpoker registryが即座に終了する")
}

/// `registry_test.gleam`'s `health_reports_the_number_of_registered_rooms_test`
/// と同じ理由（#93, #285）: `/health` の poker 側応答を配線するにはまず
/// 登録数を正しく返す必要がある。
pub fn health_reports_the_number_of_registered_rooms_test() {
  let assert Ok(started) = poker_registry.start()
  let reg = started.data

  assert poker_registry.health(reg)
    == Ok(poker_registry.HealthSnapshot(rooms: 0, stuck: 0))

  let assert Ok(_) = poker_registry.lookup(reg, poker_registry.room_id("a"))
  let assert Ok(_) = poker_registry.lookup(reg, poker_registry.room_id("b"))

  assert poker_registry.health(reg)
    == Ok(poker_registry.HealthSnapshot(rooms: 2, stuck: 0))
}

/// registry 自体は応答していても、個々の room actor がハング/デッドロック
/// していれば `Health` の `stuck` に反映されること。`registry_test.gleam`'s
/// `health_reports_a_room_that_does_not_respond_to_a_probe_test` と同じ理由
/// （#138, #285）。
pub fn health_reports_a_room_that_does_not_respond_to_a_probe_test() {
  let stuck_subject: process.Subject(poker.Message) = process.new_subject()
  let assert Ok(started) =
    poker_registry.start_with_room_starter(fn() {
      Ok(actor.Started(pid: process.self(), data: stuck_subject))
    })
  let reg = started.data

  let assert Ok(_) =
    poker_registry.lookup(reg, poker_registry.room_id("stuck-room"))

  // 最初の Health は probe 前なので stuck=0（前回の probe 結果が無い）。
  assert poker_registry.health(reg)
    == Ok(poker_registry.HealthSnapshot(rooms: 1, stuck: 0))

  wait.until_within(
    fn() {
      poker_registry.health(reg)
      == Ok(poker_registry.HealthSnapshot(rooms: 1, stuck: 1))
    },
    "詰まっている poker room が probe で検知される",
    200,
  )
}

/// **応答しない registry では失敗する**こと。`registry_test.gleam`'s
/// `health_fails_when_the_registry_does_not_answer_test` と同じ理由。
pub fn health_fails_when_the_registry_does_not_answer_test() {
  let unresponsive: process.Subject(poker_registry.Message) =
    process.new_subject()

  assert poker_registry.health(unresponsive) == Error(call.Timeout)
}

/// 死んだ registry でも失敗する（クラッシュではなく Error になる）。
/// `registry_test.gleam`'s `health_fails_when_the_registry_is_dead_test` と
/// 同じ理由。
pub fn health_fails_when_the_registry_is_dead_test() {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = poker_registry.start()
    process.send(ready, started.data)
    process.sleep(3000)
  })
  let assert Ok(reg) = process.receive(ready, 1000)
  let assert Ok(pid) = process.subject_owner(reg)

  assert poker_registry.health(reg)
    == Ok(poker_registry.HealthSnapshot(rooms: 0, stuck: 0))

  process.kill(pid)
  wait.until_dead(pid, "poker registry が終了する")

  assert poker_registry.health(reg) == Error(call.ActorDown)
}
