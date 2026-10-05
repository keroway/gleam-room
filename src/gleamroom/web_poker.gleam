import gleamroom/client_js

/// The minimal browser client for manually exercising Planning Poker's
/// room join/presence, voting, and reveal behavior end to end.
///
/// Mirrors `web.gleam`'s shape (a single static HTML document with inline
/// CSS/JS, no build tool or framework); the connection/reconnect/log JS both
/// pages have in common is spliced in from `client_js` (#589). It only speaks the wire protocol documented in `docs/planning-poker.md`; it
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
<p><a href=\"/\">Buzzer</a></p>

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
  // 直近の vote 送信前の ownVote。拒否時は null ではこの値へ戻す（#575）。
  let ownVoteBeforeSend = null;
  let lastSentType = null;

  const WS_PATH = \"/poker/ws\";
  const afterSend = (message) => {
    lastSentType = message.type;
  };
" <> client_js.shared <> "
  function resetRoomView() {
    participants = new Map();
    votes = [];
    ownVote = null;
    ownVoteBeforeSend = null;
    renderParticipants();
    renderVotes();
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
        // 妥当な JSON でも phase/participants フィールドが欠落・型不一致の
        // ことがある（サーバ側プロトコル変更等）。副作用を始める前に検証し、
        // setConnected(true) 実行済みのまま参加者が更新されない部分適用状態を
        // 避ける（web.gleam #478 と同じ理由）。
        if (
          typeof message.phase !== \"string\" ||
          !Array.isArray(message.participants)
        ) {
          log(`state message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        // join が成立した証拠。ここで初めて試行回数を戻す（web.gleam の #87 と同じ理由）。
        reconnectAttempts = 0;
        phase = message.phase;
        participants = new Map(
          message.participants.map((p) => [p.participant_id, p]),
        );
        // Revealed中にjoinした場合、他参加者が revealed イベントで受け取った
        // のと同じ投票値を state.votes から受け取る(#407)。Voting中は常に
        // 空配列で届く。
        votes = Array.isArray(message.votes) ? message.votes : [];
        ownVote = null;
        ownVoteBeforeSend = null;
        setConnected(true);
        renderParticipants();
        renderVotes();
        log(`state: phase=${message.phase} ${message.participants.length} participant(s)`);
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
      case \"vote_registered\": {
        if (typeof message.participant_id !== \"string\") {
          log(`vote_registered message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        const participant = participants.get(message.participant_id);
        if (participant) {
          // broadcast_all は発行者本人にも配信するため、同じ vote_registered
          // が reply 経由と broadcast 経由の2回届く（#526）。has_voted は
          // 投票のたびに毎回trueへ上書きされる一意キー相当の値なので、既に
          // trueならこの配信は自己エコーとみなしてスキップする。
          if (participant.has_voted) {
            break;
          }
          participant.has_voted = true;
          renderParticipants();
          log(`vote registered: ${message.participant_id}`);
        } else {
          log(`vote registered for unknown participant: ${message.participant_id}`);
        }
        break;
      }
      case \"revealed\": {
        // state ケース（#478）と同じ理由。votes が配列でないと updateCardButtons
        // 実行済みのまま votes 描画・ログが例外か部分適用状態で固まる（#527）。
        if (!Array.isArray(message.votes)) {
          log(`revealed message missing expected fields: ${JSON.stringify(message)}`);
          break;
        }
        // 同じ理由（#526）で revealed も自己エコーが2回届く。round には
        // position のような一意キーが無いため、直前の revealed と phase・
        // votes 内容が両方一致するかどうかを冪等化キーとして使う。
        const alreadyRevealed =
          phase === \"revealed\" && JSON.stringify(votes) === JSON.stringify(message.votes);
        if (alreadyRevealed) {
          break;
        }
        phase = \"revealed\";
        votes = message.votes;
        updateCardButtons();
        renderVotes();
        log(`revealed: ${message.votes.length} vote(s)`);
        break;
      }
      case \"round_reset\": {
        // 同じ理由（#526）で round_reset も自己エコーが2回届く。リセット後
        // の状態（voting フェーズ・votes 空・全員 has_voted=false）と現在の
        // 状態が既に一致しているかどうかを冪等化キーとして使う。
        const alreadyReset =
          phase === \"voting\" &&
          votes.length === 0 &&
          ![...participants.values()].some((p) => p.has_voted);
        if (alreadyReset) {
          break;
        }
        phase = \"voting\";
        votes = [];
        ownVote = null;
        ownVoteBeforeSend = null;
        for (const participant of participants.values()) {
          participant.has_voted = false;
        }
        updateCardButtons();
        renderParticipants();
        renderVotes();
        log(\"round reset\");
        break;
      }
      case \"error\":
        log(`error [${message.code}]: ${message.message}`);
        // room_full/invalid_room_id/invalid_display_name/room_unavailable は
        // room_full/room_unavailable/room_busy 等の接続レベルのエラーは
        // client_js.gleam の共有処理が扱う。
        if (handleConnectionError(message.code)) {
          break;
        }
        if (
          message.code === \"round_already_revealed\" ||
          message.code === \"voter_not_joined\" ||
          message.code === \"invalid_card\" ||
          (message.code === \"rate_limited\" && lastSentType === \"vote\")
        ) {
          // vote が楽観的に反映した ownVote/aria-pressed をサーバーの拒否に
          // 合わせて巻き戻す（reveal との競合などで届いた vote が拒否される
          // ケース。参加者リストの✓は元々サーバー権威なので不整合はない）。
          // rate_limited は vote 以外（reveal/reset）でも発生しうるため、
          // 直前に送信したメッセージ種別が vote のときだけロールバックする
          // （WebSocket はメッセージ順序を保証し、サーバーは受信順に1件ずつ
          // 処理するため、1件ずつ送って応答を待つ限り、直前送信と直後に届く
          // エラーは対応する）。
          // 既知の制約（#525）: vote の直後に応答を待たず reveal 等を送ると
          // lastSentType が上書きされ、vote への rate_limited を取り違えて
          // ロールバックしない。サーバーの rate_limited は拒否した種別を
          // 返さず、成功応答（vote_registered）も自分のものか判別できないため、
          // クライアントだけでは区別できない。実害はレート制限（30通/30秒）に
          // 達した状態での本人画面の表示ずれのみで、次の state/round_reset で
          // 直る。厳密にするなら rate_limited に拒否した種別
          // （例: rejected_type）を足す案があるが、費用に見合わず見送った。
          // 戻し先は null ではなく送信前の値（2回目以降の vote が拒否されても、
          // サーバーに残っている前回の投票を見失わない。#575）。
          ownVote = ownVoteBeforeSend;
          updateCardButtons();
        }
        break;
      default:
        log(`unrecognized message: ${JSON.stringify(message)}`);
    }
  }

  for (const card of cards) {
    card.el.addEventListener(\"click\", () => {
      if (!sendIfOpen({ type: \"vote\", value: card.value })) return;
      ownVoteBeforeSend = ownVote;
      ownVote = card.value;
      updateCardButtons();
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
