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
  // 自分が buzz 済みかどうか。サーバーは buzz_accepted を全員に配るだけで
  // 自分の参加者IDも渡さないため、クリック時に楽観的に立て、already_buzzed で
  // 確定させる。round_reset・state・切断で戻す（#576）。
  let hasBuzzed = false;
  let isConnected = false;

  const WS_PATH = \"/ws\";
  const afterSend = () => {};
" <> client_js.shared <> "
  function resetRoomView() {
    participants = new Map();
    buzzes = [];
    renderParticipants();
    renderBuzzes();
  }

  function updateBuzzButton() {
    buzzButton.disabled = !isConnected || hasBuzzed;
  }

  function setConnected(connected) {
    statusEl.textContent = connected ? \"connected\" : \"disconnected\";
    statusEl.dataset.state = connected ? \"connected\" : \"disconnected\";
    joinButton.disabled = connected;
    roomInput.disabled = connected;
    nameInput.disabled = connected;
    isConnected = connected;
    if (!connected) hasBuzzed = false;
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

  function handleServerMessage(message) {
    switch (message.type) {
      case \"state\":
        // 妥当な JSON でも participants/buzzes フィールドが欠落・型不一致の
        // ことがある（サーバ側プロトコル変更等）。副作用を始める前に検証し、
        // setConnected(true) 実行済みのまま参加者/buzz が更新されない
        // 部分適用状態を避ける（#478）。
        if (!Array.isArray(message.participants) || !Array.isArray(message.buzzes)) {
          log(`state message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        // join が成立した証拠。ここで初めて試行回数を戻す（#87）。
        reconnectAttempts = 0;
        hasBuzzed = false;
        setConnected(true);
        participants = new Map(message.participants.map((p) => [p.participant_id, p]));
        buzzes = message.buzzes;
        renderParticipants();
        renderBuzzes();
        log(`state: ${message.participants.length} participant(s)`);
        break;
      case \"participant_joined\":
        // state ケース（#478）と同じ理由。participant がオブジェクトでない/
        // participant_id が文字列でないと、以降の描画・ログが部分適用状態で
        // 固まるか例外を投げる（#527）。
        if (
          typeof message.participant !== \"object\" ||
          message.participant === null ||
          typeof message.participant.participant_id !== \"string\"
        ) {
          log(`participant_joined message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        participants.set(message.participant.participant_id, message.participant);
        renderParticipants();
        log(`joined: ${message.participant.display_name}`);
        break;
      case \"participant_left\":
        if (typeof message.participant_id !== \"string\") {
          log(`participant_left message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        participants.delete(message.participant_id);
        renderParticipants();
        log(`left: ${message.participant_id}`);
        break;
      case \"buzz_accepted\":
        if (
          typeof message.participant_id !== \"string\" ||
          typeof message.position !== \"number\" ||
          typeof message.display_name !== \"string\"
        ) {
          log(`buzz_accepted message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        // join直後の狭い時間窓で、room 側の subscribers 登録と selector 設定の
        // 間にメールボックスへ滞留したイベントが、state 受信後に再配送され
        // 重複表示されうる（#43）。position は round 内で一意なので、
        // それをキーに冪等化する。
        if (!buzzes.some((b) => b.position === message.position)) {
          buzzes.push(message);
          renderBuzzes();
          log(`buzz accepted: ${message.participant_id} (#${message.position})`);
        }
        break;
      case \"round_reset\":
        hasBuzzed = false;
        updateBuzzButton();
        // broadcast_all は発行者本人にも配信するため、同じ round_reset が
        // reply 経由と broadcast 経由の2回届く（#526）。round には position
        // のような一意キーが無いため、リセット後の状態（buzzes が空）と
        // 現在の状態が既に一致しているかどうかを冪等化キーとして使う。
        if (buzzes.length === 0) {
          break;
        }
        buzzes = [];
        renderBuzzes();
        log(\"round reset\");
        break;
      case \"error\":
        log(`error [${message.code}]: ${message.message}`);
        // room_full/invalid_room_id/invalid_display_name/room_unavailable は
        // room_full/room_unavailable/room_busy 等の接続レベルのエラーは
        // client_js.gleam の共有処理が扱う。
        if (handleConnectionError(message.code)) {
          break;
        }
        if (message.code === \"already_buzzed\") {
          // 楽観的に立てた hasBuzzed をサーバーの判定で確定させる（#576）。
          hasBuzzed = true;
          updateBuzzButton();
        } else if (hasBuzzed) {
          // buzz が rate_limited 等で拒否された場合に備えて楽観状態を戻す。
          // 取り違えても、次のクリックで already_buzzed が返って再び確定する。
          hasBuzzed = false;
          updateBuzzButton();
        }
        break;
      default:
        log(`unrecognized message: ${JSON.stringify(message)}`);
    }
  }

  buzzButton.addEventListener(\"click\", () => {
    if (!sendIfOpen({ type: \"buzz\" })) return;
    hasBuzzed = true;
    updateBuzzButton();
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
