/// The minimal browser client for manually exercising Planning Poker's
/// room join/presence, voting, and reveal behavior end to end.
///
/// Deliberately mirrors `web.gleam`'s shape (a single static HTML document
/// with inline CSS/JS, no build tool or framework) rather than sharing code
/// with it, per ADR 0009: Planning Poker duplicates rather than shares. It
/// only speaks the wire protocol documented in `docs/planning-poker.md`; it
/// holds no room-domain logic of its own.
pub fn poker_html() -> String {
  "<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>gleam-room planning poker</title>
<style>
  :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
  body { margin: 0 auto; max-width: 40rem; padding: 1rem; }
  fieldset { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center; }
  #cards { display: flex; gap: 0.5rem; flex-wrap: wrap; margin: 1rem 0; }
  #cards button {
    padding: 1rem;
    min-width: 3rem;
    font-size: 1.25rem;
    font-weight: bold;
  }
  #cards button[aria-pressed=\"true\"] { outline: 3px solid; }
  #cards button:disabled, #reveal:disabled, #reset:disabled { opacity: 0.5; }
  #participants { padding-left: 1.2rem; }
  #votes { padding-left: 1.2rem; }
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
<h1>gleam-room planning poker</h1>

<form id=\"join-form\">
  <fieldset>
    <label>Room <input id=\"room-id\" required autocomplete=\"off\" placeholder=\"ABCD\" maxlength=\"64\"></label>
    <label>Name <input id=\"display-name\" required autocomplete=\"off\" placeholder=\"Alice\" maxlength=\"64\"></label>
    <button type=\"submit\" id=\"join\">Join</button>
    <span id=\"status\" data-state=\"disconnected\">disconnected</span>
  </fieldset>
</form>

<div id=\"cards\">
  <button data-value=\"0\" id=\"card-0\" disabled>0</button>
  <button data-value=\"1\" id=\"card-1\" disabled>1</button>
  <button data-value=\"2\" id=\"card-2\" disabled>2</button>
  <button data-value=\"3\" id=\"card-3\" disabled>3</button>
  <button data-value=\"5\" id=\"card-5\" disabled>5</button>
  <button data-value=\"8\" id=\"card-8\" disabled>8</button>
  <button data-value=\"13\" id=\"card-13\" disabled>13</button>
  <button data-value=\"21\" id=\"card-21\" disabled>21</button>
  <button data-value=\"?\" id=\"card-question\" disabled>?</button>
  <button data-value=\"coffee\" id=\"card-coffee\" disabled>&#9749;</button>
</div>
<fieldset>
  <button id=\"reveal\" disabled>Reveal</button>
  <button id=\"reset\" disabled>Reset round</button>
</fieldset>

<h2>Participants</h2>
<ul id=\"participants\"></ul>

<h2>Votes</h2>
<ul id=\"votes\"></ul>

<h2>Log</h2>
<div id=\"log\"></div>

<script>
(() => {
  const joinForm = document.getElementById(\"join-form\");
  const roomInput = document.getElementById(\"room-id\");
  const nameInput = document.getElementById(\"display-name\");
  const joinButton = document.getElementById(\"join\");
  const statusEl = document.getElementById(\"status\");
  // ボタンの `data-value` HTML 属性ではなくこの対応表で値を持つ。
  // harness.mjs の DOM スタブは実 HTML を解析せず、getElementById で
  // 取り出した要素の dataset は空のまま（#282）。
  const cards = [
    { id: \"card-0\", value: \"0\" },
    { id: \"card-1\", value: \"1\" },
    { id: \"card-2\", value: \"2\" },
    { id: \"card-3\", value: \"3\" },
    { id: \"card-5\", value: \"5\" },
    { id: \"card-8\", value: \"8\" },
    { id: \"card-13\", value: \"13\" },
    { id: \"card-21\", value: \"21\" },
    { id: \"card-question\", value: \"?\" },
    { id: \"card-coffee\", value: \"coffee\" },
  ].map((card) => ({ ...card, el: document.getElementById(card.id) }));
  const revealButton = document.getElementById(\"reveal\");
  const resetButton = document.getElementById(\"reset\");
  const participantsEl = document.getElementById(\"participants\");
  const votesEl = document.getElementById(\"votes\");
  const logEl = document.getElementById(\"log\");

  let socket = null;
  let participants = new Map();
  let phase = \"voting\";
  let votes = [];
  let ownVote = null;

  // Same transient-identity reconnect model as the buzzer (docs/mvp.md's
  // Reconnect section, referenced by docs/planning-poker.md): a reconnect
  // re-joins as a brand new, server-assigned participant identity.
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

  const MAX_LOG_ENTRIES = 200;

  function log(line) {
    const entry = document.createElement(\"div\");
    entry.textContent = `[${new Date().toLocaleTimeString()}] ${line}`;
    logEl.append(entry);
    while (logEl.children.length > MAX_LOG_ENTRIES) {
      logEl.firstElementChild.remove();
    }
    logEl.scrollTop = logEl.scrollHeight;
  }

  function setConnected(connected) {
    statusEl.textContent = connected ? \"connected\" : \"disconnected\";
    statusEl.dataset.state = connected ? \"connected\" : \"disconnected\";
    joinButton.disabled = connected;
    roomInput.disabled = connected;
    nameInput.disabled = connected;
    revealButton.disabled = !connected;
    resetButton.disabled = !connected;
    updateCardButtons();
  }

  // 投票ボタンは接続中かつ reveal 前だけ押せる。reveal 前なら自分の投票は
  // 何度でも上書きできるため、選択済みでも無効化はしない（受け入れ基準）。
  function updateCardButtons() {
    const connected = statusEl.dataset.state === \"connected\";
    for (const card of cards) {
      card.el.disabled = !connected || phase !== \"voting\";
      card.el.setAttribute(
        \"aria-pressed\",
        card.value === ownVote ? \"true\" : \"false\",
      );
    }
  }

  function renderParticipants() {
    participantsEl.replaceChildren(
      ...[...participants.values()].map((p) => {
        const li = document.createElement(\"li\");
        li.textContent = p.has_voted
          ? `${p.display_name} ✓`
          : p.display_name;
        return li;
      }),
    );
  }

  function renderVotes() {
    votesEl.replaceChildren(
      ...votes.map((v) => {
        const li = document.createElement(\"li\");
        li.textContent = `${v.display_name}: ${v.value ?? \"(no vote)\"}`;
        return li;
      }),
    );
  }

  function handleServerMessage(message) {
    switch (message.type) {
      case \"state\":
        // join が成立した証拠。ここで初めて試行回数を戻す（web.gleam の #87 と同じ理由）。
        reconnectAttempts = 0;
        phase = message.phase;
        participants = new Map(
          message.participants.map((p) => [p.participant_id, p]),
        );
        votes = [];
        ownVote = null;
        setConnected(true);
        renderParticipants();
        renderVotes();
        log(`state: phase=${message.phase} ${message.participants.length} participant(s)`);
        break;
      case \"participant_joined\":
        participants.set(message.participant.participant_id, message.participant);
        renderParticipants();
        log(`joined: ${message.participant.display_name}`);
        break;
      case \"participant_left\":
        participants.delete(message.participant_id);
        renderParticipants();
        log(`left: ${message.participant_id}`);
        break;
      case \"vote_registered\": {
        const participant = participants.get(message.participant_id);
        if (participant) participant.has_voted = true;
        renderParticipants();
        log(`vote registered: ${message.participant_id}`);
        break;
      }
      case \"revealed\":
        phase = \"revealed\";
        votes = message.votes;
        updateCardButtons();
        renderVotes();
        log(`revealed: ${message.votes.length} vote(s)`);
        break;
      case \"round_reset\":
        phase = \"voting\";
        votes = [];
        ownVote = null;
        for (const participant of participants.values()) {
          participant.has_voted = false;
        }
        updateCardButtons();
        renderParticipants();
        renderVotes();
        log(\"round reset\");
        break;
      case \"error\":
        log(`error [${message.code}]: ${message.message}`);
        // room_full/invalid_room_id/invalid_display_name はソケットを閉じずに
        // 返る（poker_websocket.gleam の同種の分岐）。room_unavailable は理由
        // により挙動が異なり、join タイムアウトでは接続が閉じられるが、
        // buzz/reset タイムアウトでは維持される（README.md/docs/mvp.md の
        // error code 表参照。code だけでは区別できない）。
        // web.gleam と同じ理由でここで即座に未接続・再join可能な状態へ戻す。
        if (
          message.code === \"room_full\" ||
          message.code === \"invalid_room_id\" ||
          message.code === \"invalid_display_name\" ||
          message.code === \"room_unavailable\"
        ) {
          if (socket) socket.close();
          socket = null;
          lastJoin = null;
          setConnected(false);
          participants = new Map();
          votes = [];
          ownVote = null;
          renderParticipants();
          renderVotes();
        }
        break;
      default:
        log(`unrecognized message: ${JSON.stringify(message)}`);
    }
  }

  function connect(roomId, displayName) {
    if (socket) return;

    const protocol = location.protocol === \"https:\" ? \"wss:\" : \"ws:\";
    socket = new WebSocket(`${protocol}//${location.host}/poker/ws`);

    socket.addEventListener(\"open\", () => {
      // web.gleam と同じ理由で、ここでは setConnected(true) を呼ばない・
      // 試行回数も戻さない: open は join 成立を意味しない。
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
      votes = [];
      ownVote = null;
      renderParticipants();
      renderVotes();
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

  function sendIfOpen(message) {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
    } else {
      log(\"not connected, ignoring \" + message.type);
    }
  }

  for (const card of cards) {
    card.el.addEventListener(\"click\", () => {
      ownVote = card.value;
      updateCardButtons();
      sendIfOpen({ type: \"vote\", value: ownVote });
    });
  }

  revealButton.addEventListener(\"click\", () => {
    sendIfOpen({ type: \"reveal\" });
  });

  resetButton.addEventListener(\"click\", () => {
    sendIfOpen({ type: \"reset\" });
  });
})();
</script>
</body>
</html>
"
}
