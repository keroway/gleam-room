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
<html lang=\"ja\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>gleam-room 早押し</title>
<style>
  :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
  /* display を指定した要素でも hidden 属性で確実に隠す。 */
  [hidden] { display: none !important; }
  body { margin: 0 auto; max-width: 40rem; padding: 1rem; line-height: 1.5; }
  h1 { font-size: 1.4rem; margin: 0 0 0.5rem; }
  h2 { font-size: 1.1rem; margin: 1rem 0 0.5rem; }
  form { margin: 0 0 1rem; }
  fieldset { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: end; }
  label { display: flex; flex-direction: column; flex: 1 1 12rem; min-width: 0; }
  /* 16px 未満だと iOS Safari が入力時に画面を拡大する。 */
  input, button { font-size: 1rem; }
  input { padding: 0.5rem; min-width: 0; }
  button { padding: 0.5rem 1rem; min-height: 2.75rem; }
  #room-id { text-transform: uppercase; }
  #status { min-height: 1.5em; font-weight: bold; }
  #status[data-state=\"connected\"] { color: green; }
  #status[data-state=\"disconnected\"],
  #status[data-state=\"resume-failed\"],
  #status[data-state=\"replaced\"],
  #status[data-state=\"outdated\"] { color: crimson; }
  #invite { border: 1px solid currentColor; border-radius: 0.5rem; padding: 0 1rem 1rem; }
  #invite-code { font-size: 1.6rem; letter-spacing: 0.15em; font-family: ui-monospace, monospace; }
  #invite-url { width: 100%; box-sizing: border-box; }
  /* QR は暗いテーマでも白地に黒で描く（読み取り機が前提にする向き）。 */
  #invite-qr svg { display: block; width: min(16rem, 100%); height: auto; margin-top: 0.5rem; }
  #buzz {
    display: block;
    width: 100%;
    min-height: 7rem;
    margin: 1rem 0;
    font-size: 2rem;
    font-weight: bold;
    /* 連打してもダブルタップ拡大にならないようにする。 */
    touch-action: manipulation;
  }
  #buzz:disabled { opacity: 0.5; }
  #phase { font-size: 1.6rem; font-weight: bold; margin: 0.5rem 0; }
  #phase[data-phase=\"open\"] { color: green; }
  #phase[data-phase=\"locked\"] { color: darkorange; }
  #notice { min-height: 1.5em; }
  #host-panel { border: 2px solid currentColor; border-radius: 0.5rem; padding: 0 1rem 1rem; }
  #host-panel .controls { display: flex; flex-wrap: wrap; gap: 0.5rem; }
  #host-panel .controls button { flex: 1 1 9rem; }
  #host-panel select { font-size: 1rem; padding: 0.5rem; }
  /* 会場表示（#768）。離れた席からも読めるよう大きく出し、操作部品は出さない。 */
  body.display-mode { max-width: none; }
  body.display-mode #phase { font-size: 4rem; text-align: center; }
  body.display-mode #buzzes { font-size: 2.5rem; }
  body.display-mode #participant-count { font-size: 1.5rem; }
  #participants { padding-left: 1.2rem; }
  #log {
    height: 12rem;
    overflow-y: auto;
    border: 1px solid currentColor;
    padding: 0.5rem;
    font-family: ui-monospace, monospace;
    font-size: 0.85rem;
  }
</style>
</head>
<body>
<h1>gleam-room 早押し</h1>
<p><a href=\"/poker\">Planning Poker</a></p>

<div id=\"entry\">
<form id=\"create-form\">
  <h2>部屋を作る</h2>
  <p>部屋を作ると、参加者に配る招待URLとQRコードが表示されます。</p>
  <fieldset>
    <label>あなたの名前 <input id=\"create-name\" required autocomplete=\"off\" placeholder=\"例: 司会\" maxlength=\"64\"></label>
    <button type=\"submit\" id=\"create\">部屋を作る</button>
  </fieldset>
</form>

<form id=\"join-form\">
  <h2 id=\"join-heading\">部屋コードで参加</h2>
  <fieldset>
    <label id=\"room-label\">部屋コード <input id=\"room-id\" required autocomplete=\"off\" autocapitalize=\"characters\" placeholder=\"例: K7M2QX\" maxlength=\"64\"></label>
    <label>あなたの名前 <input id=\"display-name\" required autocomplete=\"off\" placeholder=\"例: さくら\" maxlength=\"64\"></label>
    <button type=\"submit\" id=\"join\">参加する</button>
  </fieldset>
</form>
</div>

<p id=\"status\" role=\"status\" aria-live=\"polite\" data-state=\"disconnected\">未接続</p>

<p id=\"phase\" aria-live=\"polite\" hidden></p>
<p id=\"notice\" role=\"status\" aria-live=\"polite\"></p>

<p id=\"player-help\" hidden>司会が受付を始めたら BUZZ を押してください。一番早く押した人が回答者です。押せるのは1問につき1回です。</p>
<button id=\"buzz\" disabled>BUZZ</button>

<section id=\"host-panel\" hidden aria-labelledby=\"host-heading\">
  <h2 id=\"host-heading\">司会の操作</h2>
  <p>問題を読み上げたら「受付開始」。最初に押した人が回答者になり、受付は自動で締まります。答えが出たら「次の問題へ」。誰も答えられないときは「この問題を閉じる」。</p>
  <div class=\"controls\">
    <button type=\"button\" id=\"open-acceptance\" disabled>受付開始</button>
    <button type=\"button\" id=\"close-acceptance\" disabled>受付を止める</button>
    <button type=\"button\" id=\"skip\" disabled>この問題を閉じる</button>
    <button type=\"button\" id=\"next-question\" disabled>次の問題へ</button>
  </div>
  <p><a id=\"display-link\" target=\"_blank\" rel=\"noopener\">会場表示を開く</a>（プロジェクタや大きな画面に映す用。操作はできません）</p>
  <p>
    <label>司会を渡す相手 <select id=\"transfer-target\"></select></label>
    <button type=\"button\" id=\"transfer-host\" disabled>司会を渡す</button>
  </p>
  <p><button type=\"button\" id=\"end-session\" disabled>部屋を終了する</button></p>
</section>

<p><button id=\"leave\" disabled>退出する</button></p>

<section id=\"invite\" hidden aria-labelledby=\"invite-heading\">
  <h2 id=\"invite-heading\">参加者を招待する</h2>
  <p>部屋コード <span id=\"invite-code\"></span></p>
  <label>招待URL <input id=\"invite-url\" readonly></label>
  <p><button type=\"button\" id=\"copy-invite\">招待URLをコピー</button> <span id=\"copy-result\" role=\"status\" aria-live=\"polite\"></span></p>
  <div id=\"invite-qr\" role=\"img\" aria-label=\"招待URLのQRコード\"></div>
  <p><span id=\"invite-qr-hint\">スマホのカメラでQRコードを読み取るか、招待URLを送ってください。</span>招待から入った人は名前を入れるだけで参加できます。</p>
</section>

<p id=\"display-help\" hidden>この画面は会場のスクリーン用です。操作はできません。</p>

<h2>参加者 <span id=\"participant-count\"></span></h2>
<ul id=\"participants\"></ul>

<h2>押した順</h2>
<ol id=\"buzzes\"></ol>

<details>
  <summary>接続ログ（不具合の調査用）</summary>
  <div id=\"log\"></div>
</details>

<script>
(() => {
  const entryEl = document.getElementById(\"entry\");
  const createForm = document.getElementById(\"create-form\");
  const createNameInput = document.getElementById(\"create-name\");
  const createButton = document.getElementById(\"create\");
  const joinForm = document.getElementById(\"join-form\");
  const joinHeading = document.getElementById(\"join-heading\");
  const roomLabel = document.getElementById(\"room-label\");
  const roomInput = document.getElementById(\"room-id\");
  const nameInput = document.getElementById(\"display-name\");
  const joinButton = document.getElementById(\"join\");
  const statusEl = document.getElementById(\"status\");
  const inviteEl = document.getElementById(\"invite\");
  const inviteCodeEl = document.getElementById(\"invite-code\");
  const inviteUrlInput = document.getElementById(\"invite-url\");
  const copyButton = document.getElementById(\"copy-invite\");
  const copyResultEl = document.getElementById(\"copy-result\");
  const inviteQrEl = document.getElementById(\"invite-qr\");
  const inviteQrHintEl = document.getElementById(\"invite-qr-hint\");
  const buzzButton = document.getElementById(\"buzz\");
  const leaveButton = document.getElementById(\"leave\");
  const phaseEl = document.getElementById(\"phase\");
  const noticeEl = document.getElementById(\"notice\");
  const playerHelpEl = document.getElementById(\"player-help\");
  const displayHelpEl = document.getElementById(\"display-help\");
  const participantCountEl = document.getElementById(\"participant-count\");
  const hostPanel = document.getElementById(\"host-panel\");
  const openButton = document.getElementById(\"open-acceptance\");
  const closeButton = document.getElementById(\"close-acceptance\");
  const skipButton = document.getElementById(\"skip\");
  const nextQuestionButton = document.getElementById(\"next-question\");
  const displayLink = document.getElementById(\"display-link\");
  const transferSelect = document.getElementById(\"transfer-target\");
  const transferButton = document.getElementById(\"transfer-host\");
  const endButton = document.getElementById(\"end-session\");
  const participantsEl = document.getElementById(\"participants\");
  const buzzesEl = document.getElementById(\"buzzes\");
  const logEl = document.getElementById(\"log\");

  let socket = null;
  let participants = new Map();
  let buzzes = [];
  let selfId = null;
  let isConnected = false;
  // 受付の段階と自分の役割（#768）。どちらもサーバの state と通知だけで決める。
  // 画面のボタンを隠すのは操作の案内で、権限はサーバが確かめる。
  let phase = null;
  let selfRole = null;
  // 「部屋を終了する」は取り消せないので、2回押して確定する。
  let endArmed = false;
  // 「次の問題へ」を短く2回押すと、1回目の round_reset が2回目より先に届いた
  // 場合に2回目が新しい問題を名指しして、問題が2つ進む。問題が変わった直後は
  // しばらく押せなくする（#768）。
  const NEXT_QUESTION_HOLD_MS = 1000;
  let nextQuestionHoldTimer = null;
  // サーバ権威の状態の位置（#765）。通知は room_instance_id が一致し、
  // revision がちょうど次のものだけを適用する。内容を比べて新旧を推測しない。
  let instanceId = null;
  let revision = 0;
  let roundId = null;
  let syncRequested = false;
  // 送った sync の request_id。拒否（rate_limited など）の応答を見分け、
  // 間隔を広げながら上限回数まで取り直す。state を受け取れば回数を戻す。
  // レート制限の窓は30秒（ws_guard の heartbeat 窓）なので、最後の再試行は
  // 最初の拒否から30秒以上後になるようにし、窓の回復後に必ず1回は試す。
  const SYNC_RETRY_DELAYS_MS = [2000, 8000, 32000];
  let syncRequestId = null;
  let syncRetries = 0;
  let syncRetryTimer = null;
  // 応答待ちの buzz/reset（request_id → 内容）。直接応答（reply）で解決する。
  // 切断で破棄し、上限を超えたら古いものから捨てる。
  const MAX_PENDING_REQUESTS = 16;
  let pending = new Map();
  // 作成（create）を送って、部屋コード付きの state を待っている間だけ
  // { displayName } を持つ（#767）。
  let pendingCreate = null;
  let nextRequestId = 1;

  const PROTOCOL_VERSION = 2;
  const PHASES = [\"waiting\", \"open\", \"locked\", \"finished\"];
  // /r/部屋コード/display で開いた会場表示（#768）。
  const displayMode = /^[/]r[/][^/]+[/]display[/]?$/.test(location.pathname ?? \"\");
  const WS_PATH = \"/ws\";
  // このタブで参加した部屋と resume token（#766）。タブ単位の sessionStorage に
  // 置くので、再読み込みでは同じ参加者に戻り、新しいタブは別の人として参加する。
  // 保存できない環境（プライベートモード等）では再読み込みで新規参加になる。
  const RESUME_KEY = \"gleamroom.buzzer.resume\";

  function loadResume() {
    try {
      const saved = JSON.parse(sessionStorage.getItem(RESUME_KEY) ?? \"null\");
      if (
        saved !== null &&
        typeof saved === \"object\" &&
        typeof saved.room_id === \"string\" &&
        typeof saved.display_name === \"string\" &&
        typeof saved.room_instance_id === \"string\" &&
        typeof saved.resume_token === \"string\"
      ) {
        return saved;
      }
    } catch (_) {}
    return null;
  }

  function saveResume(saved) {
    try {
      sessionStorage.setItem(RESUME_KEY, JSON.stringify(saved));
    } catch (_) {}
  }

  function clearResume() {
    try {
      sessionStorage.removeItem(RESUME_KEY);
    } catch (_) {}
  }

  // 同じ部屋・同じ名前で参加した記録があれば、新規参加ではなく同じ参加者として
  // 戻る（#766）。表示名だけでは戻れない。token を持つこのタブだけが戻れる。
  // 部屋の作成（#767）は roomId を null にして connect する。部屋コードは
  // サーバが発行し、作った本人への state にだけ付く。
  function joinMessage(roomId, displayName) {
    if (roomId === null) {
      return { type: \"create\", v: PROTOCOL_VERSION, display_name: displayName };
    }
    // 会場表示は参加者にならず、token も持たない（#768）。
    if (displayMode) return { type: \"watch\", v: PROTOCOL_VERSION, room_id: roomId };
    const saved = loadResume();
    if (saved && saved.room_id === roomId && saved.display_name === displayName) {
      const resume = {
        type: \"resume\",
        v: PROTOCOL_VERSION,
        room_id: roomId,
        room_instance_id: saved.room_instance_id,
        resume_token: saved.resume_token,
      };
      // 司会は司会 token も添える。猶予が切れた後でも司会として戻れる（#768）。
      if (typeof saved.host_token === \"string\") resume.host_token = saved.host_token;
      return resume;
    }
    return { type: \"join\", v: PROTOCOL_VERSION, room_id: roomId, display_name: displayName };
  }
  const afterSend = () => {};
" <> client_js.qr_code <> client_js.shared <> "
  function resetRoomView() {
    participants = new Map();
    buzzes = [];
    instanceId = null;
    revision = 0;
    roundId = null;
    phase = null;
    selfRole = null;
    noticeEl.textContent = \"\";
    clearSyncRetry();
    syncRetries = 0;
    pending = new Map();
    renderParticipants();
    renderBuzzes();
    renderRoleView();
    hideInvite();
    // 作成の応答（部屋コード付きの state）を受け取る前に接続が終わった。
    // 部屋が二重にできないよう、作成は自動で送り直さない（#767）。
    if (pendingCreate !== null) {
      pendingCreate = null;
      createButton.disabled = false;
      createNameInput.disabled = false;
      showProblem(\"部屋を作れませんでした。もう一度「部屋を作る」を押してください\");
    }
  }

  // 接続できなかった・参加できなかった理由を画面に出す（#767）。ログを
  // 開かなくても分かるようにする。
  function showProblem(text) {
    statusEl.textContent = text;
  }

  // 招待 URL を参加者に見せる（#767）。載せるのは部屋コードだけで、
  // resume token や司会 token は載せない。
  function inviteUrl(roomId) {
    return `${location.protocol}//${location.host}/r/${encodeURIComponent(roomId)}`;
  }

  function showInvite(roomId) {
    displayLink.href = `${inviteUrl(roomId)}/display`;
    if (displayMode) return;
    const url = inviteUrl(roomId);
    inviteCodeEl.textContent = roomId;
    inviteUrlInput.value = url;
    copyResultEl.textContent = \"\";
    renderQr(url);
    inviteEl.hidden = false;
  }

  function hideInvite() {
    inviteEl.hidden = true;
    copyResultEl.textContent = \"\";
  }

  const SVG_NS = \"http://www.w3.org/2000/svg\";
  const QR_QUIET_ZONE = 4;

  function renderQr(text) {
    const matrix = qrMatrix(text);
    // URL が長すぎて QR に収まらないときは、空の枠と読み取り案内を残さず
    // URL の送付だけを案内する。
    inviteQrEl.hidden = matrix === null;
    inviteQrHintEl.textContent =
      matrix === null
        ? \"招待URLをコピーして送ってください。\"
        : \"スマホのカメラでQRコードを読み取るか、招待URLを送ってください。\";
    if (matrix === null) {
      inviteQrEl.replaceChildren();
      return;
    }
    const size = matrix.length + QR_QUIET_ZONE * 2;
    let d = \"\";
    matrix.forEach((row, y) => {
      row.forEach((dark, x) => {
        if (dark) d += `M${x + QR_QUIET_ZONE} ${y + QR_QUIET_ZONE}h1v1h-1z`;
      });
    });
    const svg = document.createElementNS(SVG_NS, \"svg\");
    svg.setAttribute(\"viewBox\", `0 0 ${size} ${size}`);
    svg.setAttribute(\"shape-rendering\", \"crispEdges\");
    svg.setAttribute(\"aria-hidden\", \"true\");
    const background = document.createElementNS(SVG_NS, \"rect\");
    background.setAttribute(\"width\", String(size));
    background.setAttribute(\"height\", String(size));
    background.setAttribute(\"fill\", \"#fff\");
    const modules = document.createElementNS(SVG_NS, \"path\");
    modules.setAttribute(\"d\", d);
    modules.setAttribute(\"fill\", \"#000\");
    svg.append(background, modules);
    inviteQrEl.replaceChildren(svg);
  }

  // 招待パスから入ったときは、部屋コードの入力と部屋の作成を出さない。
  function enterInviteMode(roomId) {
    roomInput.value = roomId;
    roomLabel.hidden = true;
    createForm.hidden = true;
    joinHeading.textContent = `部屋 ${roomId} に参加`;
  }

  function invitedRoomFromPath() {
    // サーバは空のパス要素を無視するので、末尾の / も同じ招待として扱う。
    const match = /^[/]r[/]([^/]+)(?:[/]display)?[/]?$/.exec(location.pathname ?? \"\");
    if (!match) return null;
    let roomId;
    try {
      roomId = decodeURIComponent(match[1]).trim().toUpperCase();
    } catch (_) {
      return null;
    }
    // サーバが受け付けないコードなら招待として扱わず、通常の画面を出す
    // （部屋コード欄と作成フォームを隠したまま行き詰まらないように）。
    return roomId !== \"\" && byteLength(roomId) <= 64 ? roomId : null;
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
    buzzButton.disabled =
      !isConnected ||
      selfRole !== \"player\" ||
      (phase !== \"open\" && phase !== \"locked\") ||
      hasBuzzed();
  }

  function answererName() {
    const first = buzzes.find((b) => b.position === 1);
    return first ? first.display_name : null;
  }

  function phaseText() {
    switch (phase) {
      case \"waiting\":
        return selfRole === \"host\" ? \"受付前（「受付開始」で始まります）\" : \"受付前：司会が始めるのを待っています\";
      case \"open\":
        return selfRole === \"player\" ? \"受付中：BUZZ を押してください\" : \"受付中\";
      case \"locked\":
        return `回答者：${answererName() ?? \"\"}`;
      case \"finished\":
        return \"この部屋は終了しました\";
      default:
        return \"\";
    }
  }

  // 役割と段階に合わせて、出す部品と押せるボタンを決める（#768）。
  function renderRoleView() {
    const joined = isConnected && phase !== null;
    phaseEl.hidden = !joined;
    phaseEl.textContent = phaseText();
    phaseEl.dataset.phase = phase ?? \"\";
    playerHelpEl.hidden = !joined || selfRole !== \"player\" || phase === \"finished\";
    buzzButton.hidden = selfRole === \"host\" || displayMode;
    displayHelpEl.hidden = !displayMode;
    leaveButton.hidden = displayMode;
    const isHost = joined && selfRole === \"host\";
    hostPanel.hidden = !isHost;
    const running = isHost && phase !== \"finished\";
    // 応答待ちの間は段階の操作を重ねて送らない。
    const ready = running && !hostCommandPending();
    // 閉じた問題の押順が残っている間は開き直せない（サーバも拒否する）。
    openButton.disabled = !(ready && phase === \"waiting\" && buzzes.length === 0);
    closeButton.disabled = !(ready && phase === \"open\");
    skipButton.disabled = !(ready && (phase === \"open\" || phase === \"locked\"));
    nextQuestionButton.disabled = !ready || nextQuestionHoldTimer !== null;
    endButton.disabled = !running;
    if (!running) disarmEnd();
    renderTransferTargets(running);
    updateBuzzButton();
  }

  // 司会を渡せるのは接続中の参加者だけ（サーバも同じ条件で確かめる）。
  function renderTransferTargets(running) {
    const previous = transferSelect.value;
    const targets = [...participants.values()].filter(
      (p) => p.role !== \"host\" && p.connected !== false,
    );
    transferSelect.replaceChildren(
      ...targets.map((p) => {
        const option = document.createElement(\"option\");
        option.value = p.participant_id;
        option.textContent = p.display_name;
        return option;
      }),
    );
    if (targets.some((p) => p.participant_id === previous)) transferSelect.value = previous;
    else transferSelect.value = targets[0]?.participant_id ?? \"\";
    transferButton.disabled = !running || targets.length === 0;
  }

  function hostCommandPending() {
    for (const request of pending.values()) {
      if (request.type !== \"buzz\") return true;
    }
    return false;
  }

  function holdNextQuestion() {
    if (nextQuestionHoldTimer !== null) clearTimeout(nextQuestionHoldTimer);
    nextQuestionHoldTimer = setTimeout(() => {
      nextQuestionHoldTimer = null;
      renderRoleView();
    }, NEXT_QUESTION_HOLD_MS);
  }

  function disarmEnd() {
    endArmed = false;
    endButton.textContent = \"部屋を終了する\";
  }

  function setConnected(connected) {
    statusEl.textContent = connected ? \"接続中\" : \"未接続\";
    statusEl.dataset.state = connected ? \"connected\" : \"disconnected\";
    joinButton.disabled = connected;
    roomInput.disabled = connected;
    nameInput.disabled = connected;
    createButton.disabled = connected;
    createNameInput.disabled = connected;
    // 参加中は入力欄を畳み、狭い画面でも BUZZ を上の方に出す。
    entryEl.hidden = connected || displayMode;
    isConnected = connected;
    leaveButton.disabled = !connected;
    renderRoleView();
  }

  function renderParticipants() {
    participantsEl.replaceChildren(
      ...[...participants.values()].map((p) => {
        const li = document.createElement(\"li\");
        // 切断中（猶予内）の参加者は、戻ってくるまで印を付けて残す（#766）。
        const role = p.role === \"host\" ? \"（司会）\" : \"\";
        const away = p.connected === false ? \"（切断中）\" : \"\";
        li.textContent = `${p.display_name}${role}${away}`;
        return li;
      }),
    );
    const players = [...participants.values()].filter((p) => p.role !== \"host\").length;
    participantCountEl.textContent = phase === null ? \"\" : `（${players}人）`;
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
    typeof p.display_name === \"string\" &&
    (p.connected === undefined || typeof p.connected === \"boolean\") &&
    (p.role === undefined || p.role === \"host\" || p.role === \"player\");
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
    // 再試行の予約中も待機中として扱う。新しい sync を重ねるとタイマーが
    // 上書きされ、state 受信後も取り消せない再同期が残る。
    if (syncRequested || syncRetryTimer !== null) return;
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
    if (syncRetries >= SYNC_RETRY_DELAYS_MS.length) {
      log(\"sync rejected repeatedly, waiting for the next missing update\");
      syncRetries = 0;
      return;
    }
    const delay = SYNC_RETRY_DELAYS_MS[syncRetries];
    syncRetries += 1;
    syncRetryTimer = setTimeout(() => {
      syncRetryTimer = null;
      requestSync();
    }, delay);
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
      !PHASES.includes(message.phase) ||
      ![\"host\", \"player\", \"display\"].includes(message.self_role) ||
      (message.self_role !== \"display\" && typeof message.self_id !== \"string\")
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
    selfId = message.self_role === \"display\" ? null : message.self_id;
    selfRole = message.self_role;
    phase = message.phase;
    // 作った部屋のコードは作成の応答でだけ届く（#767）。以後の再接続はこの
    // 部屋への resume/join になり、作成を繰り返さない。招待 URL にもしておき、
    // 再読み込みしても同じ部屋に戻れるようにする。
    if (pendingCreate !== null && typeof message.room_id === \"string\") {
      lastJoin = { roomId: message.room_id, displayName: pendingCreate.displayName };
      enterInviteMode(message.room_id);
      try {
        history.replaceState(null, \"\", `/r/${encodeURIComponent(message.room_id)}`);
      } catch (_) {}
    }
    pendingCreate = null;
    // join の応答にだけ resume token が付く（#766）。resume の応答には付かず、
    // 保存済みのものをそのまま使い続ける。司会 token（#767）は作成の応答と、
    // 移譲で司会になったときの host_assigned（#768）でだけ届く。
    if (typeof message.resume_token === \"string\" && lastJoin) {
      const saved = {
        room_id: lastJoin.roomId,
        display_name: lastJoin.displayName,
        room_instance_id: message.room_instance_id,
        resume_token: message.resume_token,
      };
      if (typeof message.host_token === \"string\") saved.host_token = message.host_token;
      saveResume(saved);
    }
    participants = new Map(message.participants.map((p) => [p.participant_id, p]));
    buzzes = message.buzzes;
    setConnected(true);
    renderParticipants();
    renderBuzzes();
    if (lastJoin) showInvite(lastJoin.roomId);
    renderRoleView();
    log(`state: ${message.participants.length} participant(s), round ${roundId}, ${phase}, ${selfRole}`);
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
      case \"participant_disconnected\":
      case \"participant_reconnected\": {
        if (!hasPosition(message) || typeof message.participant_id !== \"string\") {
          log(`${message.type} message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        const connected = message.type === \"participant_reconnected\";
        const participant = participants.get(message.participant_id);
        if (participant) {
          participants.set(message.participant_id, { ...participant, connected });
          renderParticipants();
        }
        log(`${connected ? \"reconnected\" : \"disconnected\"}: ${participant?.display_name ?? message.participant_id}`);
        break;
      }
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
        if (PHASES.includes(message.phase)) phase = message.phase;
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
        phase = \"waiting\";
        holdNextQuestion();
        renderBuzzes();
        log(`round reset: next question (round ${roundId})`);
        break;
      case \"phase_changed\":
        if (!hasPosition(message) || !PHASES.includes(message.phase) || !Number.isInteger(message.round_id)) {
          log(`phase_changed message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        phase = message.phase;
        log(`phase: ${phase}`);
        break;
      case \"host_transferred\": {
        if (!hasPosition(message) || typeof message.from !== \"string\" || typeof message.to !== \"string\") {
          log(`host_transferred message missing expected fields: ${JSON.stringify(message)}`);
          return false;
        }
        if (admit(message) !== \"apply\") return false;
        for (const [id, role] of [[message.from, \"player\"], [message.to, \"host\"]]) {
          const participant = participants.get(id);
          if (participant) participants.set(id, { ...participant, role });
        }
        if (message.from === selfId) {
          selfRole = \"player\";
          forgetHostToken();
          noticeEl.textContent = \"司会を渡しました。これからは参加者として BUZZ できます\";
        }
        if (message.to === selfId) {
          selfRole = \"host\";
          noticeEl.textContent = \"あなたが司会になりました\";
        }
        renderParticipants();
        log(`host: ${participants.get(message.to)?.display_name ?? message.to}`);
        break;
      }
      default:
        log(`unrecognized message: ${JSON.stringify(message)}`);
        return false;
    }
    revision = message.revision;
    renderRoleView();
    return true;
  }

  // 司会 token を保存し直す（#768）。移譲で司会になったときに届く。
  function rememberHostToken(token) {
    const saved = loadResume();
    if (saved) saveResume({ ...saved, host_token: token });
  }

  function forgetHostToken() {
    const saved = loadResume();
    if (saved && \"host_token\" in saved) {
      const { host_token: _dropped, ...rest } = saved;
      saveResume(rest);
    }
  }

  // 操作が通らなかった理由（#768）。接続は続く。
  const COMMAND_PROBLEMS = {
    not_accepting: \"まだ受付が始まっていません\",
    forbidden: \"この操作は司会だけができます\",
    invalid_phase: \"今の段階ではその操作はできません\",
    stale_round: \"画面が古い問題のままでした。最新の状態を表示しています\",
    session_finished: \"この部屋は終了しています\",
    session_full: \"問題数の上限（200問）に達しました\",
    invalid_target: \"司会を渡せるのは接続中の参加者だけです\",
  };

  // 同じ参加者に戻れなかった理由（#766）。どれも新規参加し直せば続けられる。
  const RESUME_FAILURES = {
    room_gone: \"前回の部屋は終了しています\",
    resume_expired: \"切断から時間が経ったため、前回の参加は終了しました\",
    invalid_token: \"前回の参加情報が無効です\",
  };

  // 参加できなかった理由（#767）。
  const JOIN_PROBLEMS = {
    room_full: \"この部屋は満員です（最大64人）\",
    room_unavailable: \"サーバが混み合っているため部屋に入れません。少し待ってからもう一度お試しください\",
    invalid_display_name: \"名前は1〜64文字で入力してください\",
    invalid_room_id: \"部屋コードが正しくありません\",
  };

  // この参加を終える。保存した token を消し、自動再接続もしない。
  function endParticipation(statusText, state) {
    clearResume();
    clearJoinTimer();
    stopPing();
    cancelReconnect();
    if (socket) socket.close();
    socket = null;
    lastJoin = null;
    setConnected(false);
    resetRoomView();
    statusEl.textContent = statusText;
    statusEl.dataset.state = state;
  }

  function handleError(message) {
    log(`error [${message.code}]: ${message.message}`);
    if (Object.hasOwn(RESUME_FAILURES, message.code)) {
      endParticipation(
        `${RESUME_FAILURES[message.code]}。「参加する」で新しい参加者として参加できます`,
        \"resume-failed\",
      );
      // 部屋ごと終わっているなら、新しく作る導線を出す（#767）。
      if (message.code === \"room_gone\") createForm.hidden = false;
      return;
    }
    if (message.code === \"session_replaced\") {
      // 複製したタブなどが同じ参加者として接続し直した。こちらが再接続すると
      // 取り合いになるので止める。
      endParticipation(
        \"別のタブや端末で同じ参加者として接続し直したため、この画面の接続を終了しました\",
        \"replaced\",
      );
      return;
    }
    if (message.code === \"room_not_found\") {
      // 部屋は終わっているか、コードが違う（#767）。無断で作り直さないので、
      // 新しく作る導線を出す。
      endParticipation(
        \"この部屋は見つかりません。終了したか、URL・部屋コードが違います。新しく部屋を作ることもできます\",
        \"disconnected\",
      );
      createForm.hidden = false;
      return;
    }
    // room_full/room_unavailable/room_busy/client_outdated 等の接続レベルの
    // エラーは client_js.gleam の共有処理が扱う。理由は画面にも出す（#767）。
    if (handleConnectionError(message.code)) {
      if (Object.hasOwn(JOIN_PROBLEMS, message.code)) showProblem(JOIN_PROBLEMS[message.code]);
      return;
    }
    if (!isConnected && (message.code === \"session_finished\" || message.code === \"displays_full\")) {
      // 参加前の拒否（#768）。部屋は続いていない／会場表示が多すぎる。
      endParticipation(
        message.code === \"session_finished\"
          ? \"この部屋は終了しています。新しく部屋を作ることもできます\"
          : \"この部屋の会場表示は上限（8画面）に達しています\",
        \"disconnected\",
      );
      if (message.code === \"session_finished\") createForm.hidden = false;
      return;
    }
    if (Object.hasOwn(COMMAND_PROBLEMS, message.code)) {
      noticeEl.textContent = COMMAND_PROBLEMS[message.code];
    }
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
      case \"host_assigned\":
        // 移譲で司会になった本人にだけ届く（#768）。状態の変更ではないので
        // revision は無い。token はログにも画面にも出さない。
        if (typeof message.host_token === \"string\") rememberHostToken(message.host_token);
        log(\"received the host role\");
        break;
      default:
        applyChange(message);
    }
    renderRoleView();
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
    renderRoleView();
  }

  function sendCommand(message) {
    const requestId = String(nextRequestId++);
    sendIfOpen({ ...message, request_id: requestId });
  }

  buzzButton.addEventListener(\"click\", () => {
    noticeEl.textContent = \"\";
    sendRequest(\"buzz\");
  });
  // 司会の操作（#768）。どれも今の問題（round_id）を名指しするので、古い
  // 画面で押しても新しい問題には効かない。
  openButton.addEventListener(\"click\", () => sendRequest(\"open\"));
  closeButton.addEventListener(\"click\", () => sendRequest(\"close\"));
  skipButton.addEventListener(\"click\", () => sendRequest(\"skip\"));
  nextQuestionButton.addEventListener(\"click\", () => {
    // ボタンを無効にするだけでは、無効になる前に入ったクリックを止められない。
    if (nextQuestionHoldTimer !== null || hostCommandPending()) return;
    sendRequest(\"next_question\");
  });
  transferButton.addEventListener(\"click\", () => {
    if (!transferSelect.value) return;
    sendCommand({ type: \"transfer_host\", participant_id: transferSelect.value });
  });
  endButton.addEventListener(\"click\", () => {
    if (!endArmed) {
      endArmed = true;
      endButton.textContent = \"もう一度押すと終了します（取り消せません）\";
      return;
    }
    disarmEnd();
    sendCommand({ type: \"end_session\" });
  });
  // 明示的な退出（#766）。サーバはすぐに参加者を外し、token は使えなくなる。
  // 接続を閉じるだけ（タブを閉じる・再読み込み）は退出ではない。
  leaveButton.addEventListener(\"click\", () => {
    sendIfOpen({ type: \"leave\" });
    endParticipation(\"退出しました\", \"disconnected\");
    log(\"left the room\");
  });

  // 部屋を作る（#767）。作成が確定する（部屋コード付きの state が届く）
  // までは自動再接続しない。送り直すと部屋が二重にできるため。
  createForm.addEventListener(\"submit\", (event) => {
    event.preventDefault();
    if (socket) {
      log(\"already connecting or connected\");
      return;
    }
    const displayName = createNameInput.value.trim();
    if (!displayName || byteLength(displayName) > 64) {
      showProblem(\"名前は1〜64文字で入力してください（UTF-8で64バイト以内）\");
      return;
    }
    cancelReconnect();
    lastJoin = null;
    pendingCreate = { displayName };
    nameInput.value = displayName;
    createButton.disabled = true;
    createNameInput.disabled = true;
    statusEl.textContent = \"部屋を作っています…\";
    connect(null, displayName);
  });

  copyButton.addEventListener(\"click\", () => {
    // navigator.clipboard は https（と localhost）でしか使えない。LAN 内の
    // http で開いたスマホでもコピーできるよう、選択してからの copy に落とす。
    const fallback = () => {
      inviteUrlInput.select?.();
      let copied = false;
      try {
        copied = document.execCommand?.(\"copy\") === true;
      } catch (_) {
        copied = false;
      }
      copyResultEl.textContent = copied
        ? \"招待URLをコピーしました\"
        : \"自動でコピーできませんでした。選択された招待URLをコピーしてください\";
    };
    const clipboard = globalThis.navigator?.clipboard;
    if (!clipboard?.writeText) {
      fallback();
      return;
    }
    clipboard.writeText(inviteUrlInput.value).then(() => {
      copyResultEl.textContent = \"招待URLをコピーしました\";
    }, fallback);
  });

  // 招待 URL（/r/部屋コード）から開いたら、名前を入れるだけで参加できる（#767）。
  const invitedRoom = invitedRoomFromPath();
  // 会場表示（/r/部屋コード/display）は名前も入力も無く、すぐ見始める（#768）。
  if (displayMode && invitedRoom !== null) {
    document.body?.classList?.add(\"display-mode\");
    entryEl.hidden = true;
    lastJoin = { roomId: invitedRoom, displayName: \"会場表示\" };
    connect(invitedRoom, \"会場表示\");
    return;
  }
  if (invitedRoom !== null) enterInviteMode(invitedRoom);

  // 再読み込み・タブの復元では、保存した参加に自動で戻る（#766）。別の部屋の
  // 招待を開いたときは戻らない（名前を入れて参加すれば新しい参加になる）。
  const savedParticipation = loadResume();
  if (
    savedParticipation &&
    (invitedRoom === null || invitedRoom === savedParticipation.room_id)
  ) {
    roomInput.value = savedParticipation.room_id;
    nameInput.value = savedParticipation.display_name;
    lastJoin = {
      roomId: savedParticipation.room_id,
      displayName: savedParticipation.display_name,
    };
    connect(savedParticipation.room_id, savedParticipation.display_name);
  }
})();
</script>
</body>
</html>
"
}
