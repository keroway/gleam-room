import gleam/option.{None, Some}
import gleam/string
import gleamroom/poker

pub fn join_adds_participant_and_emits_joined_test() {
  let state = poker.new_state()
  let id = poker.participant_id("p1")

  let #(next, event) = poker.apply_command(state, poker.Join(id, "Alice"))

  assert poker.snapshot(next) == [poker.Participant(id, "Alice")]
  assert event == poker.ParticipantJoined(poker.Participant(id, "Alice"))
}

pub fn duplicate_join_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))

  let #(next, event) = poker.apply_command(state, poker.Join(id, "Alice again"))

  assert next == state
  assert event == poker.JoinRejected(id, poker.AlreadyJoined)
}

pub fn join_with_blank_display_name_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()

  let #(next, event) = poker.apply_command(state, poker.Join(id, "   "))

  assert next == state
  assert event == poker.JoinRejected(id, poker.InvalidDisplayName)
}

pub fn join_with_display_name_over_the_length_limit_is_rejected_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()
  let too_long = string.repeat("a", 65)

  let #(next, event) = poker.apply_command(state, poker.Join(id, too_long))

  assert next == state
  assert event == poker.JoinRejected(id, poker.InvalidDisplayName)
}

pub fn join_beyond_the_participant_limit_is_rejected_and_state_is_unchanged_test() {
  let full_state = fill_room(64)
  let overflow_id = poker.participant_id("overflow")

  let #(next, event) =
    poker.apply_command(full_state, poker.Join(overflow_id, "Overflow"))

  assert next == full_state
  assert event == poker.JoinRejected(overflow_id, poker.RoomFull)
}

pub fn leave_removes_participant_and_emits_left_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))

  let #(next, event) = poker.apply_command(state, poker.Leave(id))

  assert poker.snapshot(next) == []
  assert event == poker.ParticipantLeft(id)
}

pub fn leave_of_unknown_participant_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()

  let #(next, event) = poker.apply_command(state, poker.Leave(id))

  assert next == state
  assert event == poker.LeaveRejected(id, poker.NotJoined)
}

pub fn vote_from_unjoined_participant_is_rejected_test() {
  let id = poker.participant_id("p1")
  let state = poker.new_state()

  let #(next, event) = poker.apply_command(state, poker.Vote(id, poker.Five))

  assert next == state
  assert event == poker.VoteRejected(id, poker.VoterNotJoined)
}

pub fn vote_registers_without_revealing_the_value_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))

  let #(next, event) = poker.apply_command(state, poker.Vote(id, poker.Five))

  assert event == poker.VoteRegistered(id)
  assert poker.has_voted(next, id)
}

pub fn revoting_before_reveal_keeps_only_the_last_value_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Three))

  let #(state, event) = poker.apply_command(state, poker.Vote(id, poker.Eight))
  let #(_, revealed) = poker.apply_command(state, poker.Reveal)

  assert event == poker.VoteRegistered(id)
  assert revealed
    == poker.RoundRevealed([poker.RevealedVote(id, "Alice", Some(poker.Eight))])
}

pub fn vote_after_reveal_is_rejected_and_state_is_unchanged_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Reveal)

  let #(next, event) = poker.apply_command(state, poker.Vote(id, poker.Eight))

  assert next == state
  assert event == poker.VoteRejected(id, poker.RoundAlreadyRevealed)
}

pub fn reveal_reports_every_participant_including_those_who_did_not_vote_test() {
  let alice = poker.participant_id("p1")
  let bob = poker.participant_id("p2")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(alice, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Join(bob, "Bob"))
  let #(state, _) = poker.apply_command(state, poker.Vote(alice, poker.Five))

  let #(next, event) = poker.apply_command(state, poker.Reveal)

  assert next.phase == poker.Revealed
  assert event
    == poker.RoundRevealed([
      poker.RevealedVote(alice, "Alice", Some(poker.Five)),
      poker.RevealedVote(bob, "Bob", None),
    ])
}

pub fn repeat_reveal_is_idempotent_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, first_reveal) = poker.apply_command(state, poker.Reveal)

  let #(next, second_reveal) = poker.apply_command(state, poker.Reveal)

  assert next == state
  assert second_reveal == first_reveal
}

pub fn reset_round_clears_votes_and_returns_to_voting_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Reveal)

  let #(next, event) = poker.apply_command(state, poker.ResetRound)

  assert event == poker.RoundReset
  assert next.phase == poker.Voting
  assert !poker.has_voted(next, id)
}

pub fn reset_from_voting_also_clears_votes_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))

  let #(next, event) = poker.apply_command(state, poker.ResetRound)

  assert event == poker.RoundReset
  assert next.phase == poker.Voting
  assert !poker.has_voted(next, id)
}

pub fn vote_is_allowed_again_after_reset_test() {
  let id = poker.participant_id("p1")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(id, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Vote(id, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Reveal)
  let #(state, _) = poker.apply_command(state, poker.ResetRound)

  let #(_, event) = poker.apply_command(state, poker.Vote(id, poker.Eight))

  assert event == poker.VoteRegistered(id)
}

pub fn leaving_participant_is_dropped_from_a_later_reveal_test() {
  let alice = poker.participant_id("p1")
  let bob = poker.participant_id("p2")
  let #(state, _) =
    poker.apply_command(poker.new_state(), poker.Join(alice, "Alice"))
  let #(state, _) = poker.apply_command(state, poker.Join(bob, "Bob"))
  let #(state, _) = poker.apply_command(state, poker.Vote(bob, poker.Five))
  let #(state, _) = poker.apply_command(state, poker.Leave(bob))

  let #(_, event) = poker.apply_command(state, poker.Reveal)

  assert event
    == poker.RoundRevealed([poker.RevealedVote(alice, "Alice", None)])
}

fn fill_room(count: Int) -> poker.PokerState {
  case count {
    0 -> poker.new_state()
    _ -> {
      let state = fill_room(count - 1)
      let id = poker.participant_id("p" <> string.inspect(count))
      let #(next, _) = poker.apply_command(state, poker.Join(id, "Name"))
      next
    }
  }
}
