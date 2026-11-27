import gleamroom/client_js

/// The minimal browser client for manually exercising room join/presence
/// and buzzer behavior end to end.
///
/// This is deliberately a single static HTML document with inline CSS/JS,
/// no frontend build tool or framework. It only speaks the wire protocol
/// documented in `docs/mvp.md`; it holds no room-domain logic of its own.
/// JS shared with the Planning Poker page is spliced in from `client_js`.
pub fn index_html() -> String {
  "<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>gleam-room buzzer</title>
<style>
  :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
  body { margin: 0 auto; max-width: 40rem; padding: 1rem; }
  fieldset { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center; }
  #buzz {
    display: block;
    width: 100%;
    margin: 1rem 0;
    padding: 1.5rem;
    font-size: 1.5rem;
    font-weight: bold;
  }
  #buzz:disabled { opacity: 0.5; }
  #participants { padding-left: 1.2rem; }
  #log {
    height: 12rem;
    overflow-y: auto;
    border: 1px solid currentColor;
    padding: 0.5rem;
    font-family: ui-monospace, monospace;
    font-size: 0.85rem;
  }
  #status[data-state=\"connected\"] { color: green; }
  #status[data-state=\"disconnected\"] { color: crimson; }
</style>
</head>
<body>
<h1>gleam-room buzzer</h1>
<p><a href=\"/poker\">Planning Poker</a></p>

<form id=\"join-form\">
  <fieldset>
    <label>Room <input id=\"room-id\" required autocomplete=\"off\" placeholder=\"ABCD\" maxlength=\"64\"></label>
    <label>Name <input id=\"display-name\" required autocomplete=\"off\" placeholder=\"Alice\" maxlength=\"64\"></label>
    <button type=\"submit\" id=\"join\">Join</button>
    <span id=\"status\" data-state=\"disconnected\">disconnected</span>
  </fieldset>
</form>

<button id=\"buzz\" disabled>BUZZ</button>
<button id=\"reset\" disabled>Reset round</button>

<h2>Participants</h2>
<ul id=\"participants\"></ul>

<h2>Buzz order</h2>
<ol id=\"buzzes\"></ol>

<h2>Log</h2>
<div id=\"log\"></div>

<script>
(() => {
  const joinForm = document.getElementById(\"join-form\");
  const roomInput = document.getElementById(\"room-id\");
  const nameInput = document.getElementById(\"display-name\");
  const joinButton = document.getElementById(\"join\");
  const statusEl = document.getElementById(\"status\");
  const buzzButton = document.getElementById(\"buzz\");
  const resetButton = document.getElementById(\"reset\");
  const participantsEl = document.getElementById(\"participants\");
  const buzzesEl = document.getElementById(\"buzzes\");
  const logEl = document.getElementById(\"log\");

  let socket = null;
  let participants = new Map();
  let buzzes = [];
  let selfId = null;
  let isConnected = false;
  // サーバ権威の状態の位置（#765）。通知は room_instance_id が一致し、
  // revision がちょうど次のものだけを適用する。内容を比べて新旧を推測しない。
  let instanceId = null;
  let revision = 0;
  let roundId = null;
  let syncRequested = false;
  // 送った sync の request_id。拒否（rate_limited など）の応答を見分け、
  // 間隔を空けて上限回数まで取り直す。state を受け取れば回数を戻す。
  const SYNC_RETRY_MS = 1000;
  const MAX_SYNC_RETRIES = 3;
  let syncRequestId = null;
  let syncRetries = 0;
  let syncRetryTimer = null;
  // 応答待ちの buzz/reset（request_id → 内容）。直接応答（reply）で解決する。
  // 切断で破棄し、上限を超えたら古いものから捨てる。
  const MAX_PENDING_REQUESTS = 16;
  let pending = new Map();
  let nextRequestId = 1;

  const PROTOCOL_VERSION = 2;
  const WS_PATH = \"/ws\";
  const JOIN_FIELDS = { v: PROTOCOL_VERSION };
  const afterSend = () => {};
" <> client_js.shared <> "
  function resetRoomView() {
    participants = new Map();
    buzzes = [];
    instanceId = null;
    revision = 0;
    roundId = null;
    clearSyncRetry();
    syncRetries = 0;
    pending = new Map();
    renderParticipants();
    renderBuzzes();
  }

  // 押下済みかどうかはサーバの buzz 一覧と、現ラウンドへの応答待ちの buzz
  // だけから決める（#765）。拒否・受理の応答で pending が消えれば自動的に戻る。
  function hasBuzzed() {
    if (selfId !== null && buzzes.some((b) => b.participant_id === selfId)) {
      return true;
    }
    for (const request of pending.values()) {
      if (request.type === \"buzz\" && request.roundId === roundId) return true;
    }
    return false;
  }

  function updateBuzzButton() {
    buzzButton.disabled = !isConnected || hasBuzzed();
  }

  function setConnected(connected) {
    statusEl.textContent = connected ? \"connected\" : \"disconnected\";
    statusEl.dataset.state = connected ? \"connected\" : \"disconnected\";
    joinButton.disabled = connected;
    roomInput.disabled = connected;
    nameInput.disabled = connected;
    isConnected = connected;
    updateBuzzButton();
    resetButton.disabled = !connected;
  }

  function renderParticipants() {
    participantsEl.replaceChildren(
      ...[...participants.values()].map((p) => {
        const li = document.createElement(\"li\");
        li.textContent = p.display_name;
        return li;
      }),
    );
  }

  function renderBuzzes() {
    buzzesEl.replaceChildren(
      ...buzzes
        .slice()
        .sort((a, b) => a.position - b.position)
        .map((b) => {
          const li = document.createElement(\"li\");
          li.textContent = b.display_name;
          return li;
        }),
    );
  }

  const isObject = (value) => typeof value === \"object\" && value !== null;
  const isParticipant = (p) =>
    isObject(p) &&
    typeof p.participant_id === \"string\" &&
    typeof p.display_name === \"string\";
  const isBuzz = (b) =>
    isObject(b) &&
    typeof b.participant_id === \"string\" &&
    typeof b.display_name === \"string\" &&
    Number.isInteger(b.position);

  // 状態を変える通知の共通の検証（#765）。部屋の世代と revision が無いものは
  // 適用順を決められないので受理しない。
  function hasPosition(message) {
    return (
      typeof message.room_instance_id === \"string\" &&
      Number.isInteger(message.revision)
    );
  }

  function clearSyncRetry() {
    syncRequested = false;
    syncRequestId = null;
    if (syncRetryTimer !== null) {
      clearTimeout(syncRetryTimer);
      syncRetryTimer = null;
    }
  }

  function requestSync() {
    if (syncRequested) return;
    syncRequested = true;
    syncRequestId = String(nextRequestId++);
    log(\"missing update detected, requesting the current state\");
    sendIfOpen({ type: \"sync\", request_id: syncRequestId });
  }

  // sync が拒否されたら待機を解き、上限内なら間隔を空けて取り直す。
  // 解かないと、以後の欠番でも sync を送れず古い表示が切断まで残る。
  function handleSyncRejected() {
    syncRequested = false;
    syncRequestId = null;
    if (syncRetries >= MAX_SYNC_RETRIES) {
      log(\"sync rejected repeatedly, waiting for the next missing update\");
      syncRetries = 0;
      return;
    }
    syncRetries += 1;
    syncRetryTimer = setTimeout(() => {
      syncRetryTimer = null;
      requestSync();
    }, SYNC_RETRY_MS);
  }

  // 通知を適用してよいかを revision で判定する（#765）。
  // \"apply\": ちょうど次。\"skip\": 既に適用済み・前の部屋・未参加。
  // 欠番があれば sync を要求して \"skip\" を返す（届いた state で追いつく）。
  function admit(message) {
    if (instanceId === null || message.room_instance_id !== instanceId) {
      return \"skip\";
    }
    if (message.revision <= revision) return \"skip\";
    if (message.revision > revision + 1) {
      requestSync();
      return \"skip\";
    }
    return \"apply\";
  }

  function applyState(message) {
    if (
      !Array.isArray(message.participants) ||
      !Array.isArray(message.buzzes) ||
      !message.participants.every(isParticipant) ||
      !message.buzzes.every(isBuzz) ||
      !hasPosition(message) ||
      !Number.isInteger(message.round_id) ||
      typeof message.self_id !== \"string\"
    ) {
      log(`state message missing expected fields: ${JSON.stringify(message)}`);
      return;
    }
    if (message.protocol_version !== PROTOCOL_VERSION) {
      markOutdated();
      return;
    }
    // join が成立した証拠。ここで初めて試行回数を戻す（#87）。
    clearJoinTimer();
    reconnectAttempts = 0;
    instanceId = message.room_instance_id;
    revision = message.revision;
    roundId = message.round_id;
    clearSyncRetry();
    syncRetries = 0;
    selfId = message.self_id;
    participants = new Map(message.participants.map((p) => [p.participant_id, p]));
    buzzes = message.buzzes;
    setConnected(true);
    renderParticipants();
    renderBuzzes();
    log(`state: ${message.participants.length} participant(s), round ${roundId}`);
  }

  // 状態変更の通知（直接応答の中身を含む）を適用する。適用したら true。
  function applyChange(message) {
    switch (message.type) {
      case \"participant_joined\":
        if (!hasPosition(message) || !isParticipant(message.participant)) {
          log(`participant_joined message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        participants.set(message.participant.participant_id, message.participant);
        renderParticipants();
        log(`joined: ${message.participant.display_name}`);
        break;
      case \"participant_left\":
        if (!hasPosition(message) || typeof message.participant_id !== \"string\") {
          log(`participant_left message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        participants.delete(message.participant_id);
        renderParticipants();
        log(`left: ${message.participant_id}`);
        break;
      case \"buzz_accepted\":
        if (!hasPosition(message) || !isBuzz(message) || !Number.isInteger(message.round_id)) {
          log(`buzz_accepted message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        buzzes.push({
          participant_id: message.participant_id,
          display_name: message.display_name,
          position: message.position,
        });
        renderBuzzes();
        log(`buzz accepted: ${message.participant_id} (#${message.position})`);
        break;
      case \"round_reset\":
        if (!hasPosition(message) || !Number.isInteger(message.round_id)) {
          log(`round_reset message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        roundId = message.round_id;
        buzzes = [];
        renderBuzzes();
        log(`round reset (round ${roundId})`);
        break;
      default:
        log(`unrecognized message: ${JSON.stringify(message)}`);
        return false;
    }
    revision = message.revision;
    return true;
  }

  function handleError(message) {
    log(`error [${message.code}]: ${message.message}`);
    // room_full/room_unavailable/room_busy/client_outdated 等の接続レベルの
    // エラーは client_js.gleam の共有処理が扱う。
    if (handleConnectionError(message.code)) return;
    // 押下済みだとサーバが言うのに手元の一覧に無いなら、どこかで通知を
    // 取りこぼしている。内容を推測せず state を取り直す（#765）。
    if (message.code === \"already_buzzed\") requestSync();
  }

  function handleServerMessage(message) {
    switch (message.type) {
      case \"state\":
        applyState(message);
        break;
      case \"reply\":
        // 直接応答。同じ変更が配信でも届くが revision で一度だけ適用される。
        // 適用済みでも pending の解決は落とさない（#765）。
        if (typeof message.request_id !== \"string\" || !isObject(message.result)) {
          log(`reply message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        pending.delete(message.request_id);
        if (message.request_id === syncRequestId && message.result.type === \"error\") {
          log(`error [${message.result.code}]: ${message.result.message}`);
          handleSyncRejected();
        } else if (message.result.type === \"error\") {
          handleError(message.result);
        } else {
          applyChange(message.result);
        }
        break;
      case \"error\":
        handleError(message);
        break;
      default:
        applyChange(message);
    }
    updateBuzzButton();
  }

  function sendRequest(type) {
    if (roundId === null) {
      log(\"not joined, ignoring \" + type);
      return;
    }
    const requestId = String(nextRequestId++);
    if (!sendIfOpen({ type, round_id: roundId, request_id: requestId })) return;
    pending.set(requestId, { type, roundId });
    while (pending.size > MAX_PENDING_REQUESTS) {
      pending.delete(pending.keys().next().value);
    }
    updateBuzzButton();
  }

  buzzButton.addEventListener(\"click\", () => sendRequest(\"buzz\"));
  resetButton.addEventListener(\"click\", () => sendRequest(\"reset\"));
})();
</script>
</body>
</html>
"
}
