// 早押しのワイヤープロトコル v2（#765）のテスト用メッセージ。
// 状態を変える通知はすべて room_instance_id と revision を持ち、クライアントは
// ちょうど次の revision だけを適用する。テストではこの規則に沿った値を組み立てる。
export const INSTANCE = "inst-1";

export function buzzerState({
  selfId = "p1",
  participants = [],
  buzzes = [],
  revision = 1,
  roundId = 1,
  instance = INSTANCE,
  protocolVersion = 2,
} = {}) {
  return {
    type: "state",
    protocol_version: protocolVersion,
    room_instance_id: instance,
    self_id: selfId,
    round_id: roundId,
    revision,
    participants,
    buzzes,
  };
}

export const participantJoined = (revision, participant, instance = INSTANCE) => ({
  type: "participant_joined",
  room_instance_id: instance,
  revision,
  participant,
});

export const participantLeft = (revision, participantId, instance = INSTANCE) => ({
  type: "participant_left",
  room_instance_id: instance,
  revision,
  participant_id: participantId,
});

export const buzzAccepted = (
  revision,
  { participantId = "p1", displayName = "Alice", position = 1, roundId = 1 } = {},
  instance = INSTANCE,
) => ({
  type: "buzz_accepted",
  room_instance_id: instance,
  revision,
  round_id: roundId,
  participant_id: participantId,
  display_name: displayName,
  position,
});

export const roundReset = (revision, roundId, instance = INSTANCE) => ({
  type: "round_reset",
  room_instance_id: instance,
  revision,
  round_id: roundId,
});

export const reply = (requestId, result) => ({
  type: "reply",
  request_id: requestId,
  result,
});

export const error = (code, message = code) => ({ type: "error", code, message });

/// クライアントが送った最後の buzz/reset/sync（JSON を解いたもの）。
export function lastSent(socket, type) {
  const sent = socket.sent.map((data) => JSON.parse(data)).filter((m) => m.type === type);
  return sent[sent.length - 1];
}
