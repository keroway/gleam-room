/// The minimal browser client for manually exercising room join/presence
/// and buzzer behavior end to end.
///
/// This is deliberately a single static HTML document with inline CSS/JS,
/// no frontend build tool or framework. It only speaks the wire protocol
/// documented in `docs/mvp.md`; it holds no room-domain logic of its own.
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

  // A reconnect always re-joins as a brand new, server-assigned participant
  // identity (see docs/mvp.md, \"Reconnect\"); this client does not attempt
  // to preserve the previous one. A fixed, small retry count keeps this
  // \"simple\" rather than a full exponential-backoff strategy.
  const RECONNECT_DELAY_MS = 1500;
  const MAX_RECONNECT_ATTEMPTS = 5;
  let lastJoin = null;
  let reconnectAttempts = 0;
  let reconnectTimer = null;

  function cancelReconnect() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    reconnectAttempts = 0;
  }

  function scheduleReconnect() {
    if (!lastJoin) return;
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      log(\"giving up automatic reconnect\");
      return;
    }
    reconnectAttempts += 1;
    log(
      `reconnecting in ${RECONNECT_DELAY_MS}ms (attempt ${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})`,
    );
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect(lastJoin.roomId, lastJoin.displayName);
    }, RECONNECT_DELAY_MS);
  }

  function log(line) {
    const entry = document.createElement(\"div\");
    entry.textContent = `[${new Date().toLocaleTimeString()}] ${line}`;
    logEl.append(entry);
    logEl.scrollTop = logEl.scrollHeight;
  }

  function setConnected(connected) {
    statusEl.textContent = connected ? \"connected\" : \"disconnected\";
    statusEl.dataset.state = connected ? \"connected\" : \"disconnected\";
    joinButton.disabled = connected;
    roomInput.disabled = connected;
    nameInput.disabled = connected;
    buzzButton.disabled = !connected;
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
          const name = b.display_name ?? participants.get(b.participant_id)?.display_name;
          li.textContent = name ?? b.participant_id;
          return li;
        }),
    );
  }

  function handleServerMessage(message) {
    switch (message.type) {
      case \"state\":
        // join が成立した証拠。ここで初めて試行回数を戻す（#87）。
        reconnectAttempts = 0;
        setConnected(true);
        participants = new Map(message.participants.map((p) => [p.id, p]));
        buzzes = message.buzzes;
        renderParticipants();
        renderBuzzes();
        log(`state: ${message.participants.length} participant(s)`);
        break;
      case \"participant_joined\":
        participants.set(message.participant.id, message.participant);
        renderParticipants();
        log(`joined: ${message.participant.display_name}`);
        break;
      case \"participant_left\":
        participants.delete(message.participant_id);
        renderParticipants();
        log(`left: ${message.participant_id}`);
        break;
      case \"buzz_accepted\":
        buzzes.push(message);
        renderBuzzes();
        log(`buzz accepted: ${message.participant_id} (#${message.position})`);
        break;
      case \"round_reset\":
        buzzes = [];
        renderBuzzes();
        log(\"round reset\");
        break;
      case \"error\":
        log(`error [${message.code}]: ${message.message}`);
        // join_rejected/room_unavailable はソケットを閉じずに返る
        // （websocket.gleam の with_room/JoinRejected 分岐）。実接続の
        // close イベントを待つと再joinまで時間差ができるため、ここで
        // 即座に \"未接続・再度join可能\" な状態へ戻す。実ソケットも
        // 明示的に閉じ、以降そのソケットからのイベントは無視する
        // （close は自然発火してもここでの状態は既にリセット済み）。
        // 明示的な拒否なので自動再接続はしない（lastJoin をクリア）。
        if (message.code === \"join_rejected\" || message.code === \"room_unavailable\") {
          if (socket) socket.close();
          socket = null;
          lastJoin = null;
          setConnected(false);
          participants = new Map();
          buzzes = [];
          renderParticipants();
          renderBuzzes();
        }
        break;
      default:
        log(`unrecognized message: ${JSON.stringify(message)}`);
    }
  }

  function connect(roomId, displayName) {
    if (socket) return;

    const protocol = location.protocol === \"https:\" ? \"wss:\" : \"ws:\";
    socket = new WebSocket(`${protocol}//${location.host}/ws`);

    socket.addEventListener(\"open\", () => {
      // **ここでは setConnected(true) を呼ばない・試行回数も戻さない（#62, #87）。**
      // WebSocket が開いただけでは join できたことにならない。UI が
      // \"connected\" になるのはサーバから state（join成立）が届いたときのみ。
      // join が通らずサーバ側から即切断される状況では open → close が
      // 繰り返され、open ごとに試行回数を 0 に戻すと上限に永久に到達せず、
      // 「5 回で諦める」という約束が効かなくなる。
      log(`connected, joining room ${roomId} as ${displayName}`);
      socket.send(JSON.stringify({
        type: \"join\",
        room_id: roomId,
        display_name: displayName,
      }));
    });

    socket.addEventListener(\"message\", (event) => {
      try {
        handleServerMessage(JSON.parse(event.data));
      } catch (err) {
        log(`could not parse server message: ${event.data}`);
      }
    });

    socket.addEventListener(\"close\", () => {
      setConnected(false);
      participants = new Map();
      buzzes = [];
      renderParticipants();
      renderBuzzes();
      socket = null;
      log(\"disconnected\");
      scheduleReconnect();
    });

    socket.addEventListener(\"error\", () => {
      log(\"connection error\");
    });
  }

  joinForm.addEventListener(\"submit\", (event) => {
    event.preventDefault();
    if (socket) return;

    const roomId = roomInput.value.trim();
    const displayName = nameInput.value.trim();
    if (!roomId || !displayName) {
      log(\"room ID と display name を入力してください\");
      return;
    }

    cancelReconnect();
    lastJoin = { roomId, displayName };
    connect(roomId, displayName);
  });

  buzzButton.addEventListener(\"click\", () => {
    if (socket) socket.send(JSON.stringify({ type: \"buzz\" }));
  });

  resetButton.addEventListener(\"click\", () => {
    if (socket) socket.send(JSON.stringify({ type: \"reset\" }));
  });
})();
</script>
</body>
</html>
"
}
