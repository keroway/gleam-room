/// Browser-client JS shared by the buzzer (`web.gleam`) and Planning Poker
/// (`web_poker.gleam`) pages.
///
/// Both pages stay a single static HTML document with inline JS and no build
/// step: this constant is concatenated into each page's `<script>` with Gleam's
/// `<>`, so it runs inside the page's own IIFE and shares its scope. The page
/// must declare, before this snippet is spliced in:
///
/// - DOM refs `joinForm`, `roomInput`, `nameInput`, `logEl`
/// - `let socket = null`
/// - `const WS_PATH` (e.g. `"/ws"`)
/// - `const afterSend = (message) => {...}` (called after a successful send)
/// - functions `setConnected(connected)`, `resetRoomView()` (clear the
///   page's room state and re-render) and `handleServerMessage(message)`
///
/// and may call `handleConnectionError(code)` from its `error` case.
/// The test extractor (`test/client/extract.mjs`) resolves the same
/// concatenation, so the client JS tests exercise the spliced result.
pub const shared =
  "
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

  // Handles the join/connection-level error codes common to both pages.
  // Returns true when the code was consumed.
  function handleConnectionError(code) {
    // room_full/invalid_room_id/invalid_display_name/room_unavailable は
    // 恒久的な拒否で、ソケットを閉じずに返る（websocket.gleam /
    // poker_websocket.gleam の with_room/JoinRejected/with_join_reply の
    // 各分岐。join タイムアウト由来の room_unavailable はサーバ側が接続自体を
    // 閉じるが、クライアントからは同じ error メッセージとして届く）。実接続の
    // close イベントを待つと再joinまで時間差ができるため、ここで即座に
    // \"未接続・再度join可能\" な状態へ戻す。実ソケットも明示的に閉じ、
    // 以降そのソケットからのイベントは無視する（close は自然発火しても
    // ここでの状態は既にリセット済み）。
    // 明示的な拒否なので自動再接続はしない（lastJoin をクリア）。
    // already_joined はこの接続が既にroomへ参加済みであることを示す
    // だけで join 失敗ではないため、ここには含めない。
    if (
      code === \"room_full\" ||
      code === \"invalid_room_id\" ||
      code === \"invalid_display_name\" ||
      code === \"room_unavailable\"
    ) {
      if (socket) socket.close();
      socket = null;
      lastJoin = null;
      setConnected(false);
      resetRoomView();
      return true;
    }
    if (code === \"room_busy\") {
      // join 済みの接続で操作がタイムアウトしたときだけ届く（with_room_reply/
      // ReplyTimedOut）。サーバはこの接続を閉じずに保持する設計だが、以後の
      // 操作はサーバ側 state がリセットされ not_joined で弾かれるため、
      // クライアントはソケットを閉じて再接続を起こす。ただし恒久拒否とは違い
      // lastJoin はクリアしない — close イベントの scheduleReconnect() が
      // lastJoin を使って自動的に再 join まで行う（#570）。
      if (socket) socket.close();
      return true;
    }
    return false;
  }

  function connect(roomId, displayName) {
    if (socket) return;

    const protocol = location.protocol === \"https:\" ? \"wss:\" : \"ws:\";
    const ws = new WebSocket(`${protocol}//${location.host}${WS_PATH}`);
    socket = ws;
    // 拒否後に再joinされると `socket` は別の接続を指す。旧ソケットの遅延
    // イベントが現行接続の状態を壊さないよう、各ハンドラで同一性を確認する（#645）。
    const isCurrent = () => socket === ws;

    ws.addEventListener(\"open\", () => {
      if (!isCurrent()) return;
      // **ここでは setConnected(true) を呼ばない・試行回数も戻さない（#62, #87）。**
      // WebSocket が開いただけでは join できたことにならない。UI が
      // \"connected\" になるのはサーバから state（join成立）が届いたときのみ。
      // join が通らずサーバ側から即切断される状況では open → close が
      // 繰り返され、open ごとに試行回数を 0 に戻すと上限に永久に到達せず、
      // 「5 回で諦める」という約束が効かなくなる。
      log(`connected, joining room ${roomId} as ${displayName}`);
      ws.send(JSON.stringify({
        type: \"join\",
        room_id: roomId,
        display_name: displayName,
      }));
    });

    ws.addEventListener(\"message\", (event) => {
      if (!isCurrent()) return;
      let message;
      try {
        message = JSON.parse(event.data);
      } catch (err) {
        log(`could not parse server message: ${event.data}`);
        return;
      }
      try {
        handleServerMessage(message);
      } catch (err) {
        log(`failed to handle server message: ${event.data} (${err?.message ?? err})`);
      }
    });

    ws.addEventListener(\"close\", () => {
      if (!isCurrent()) return;
      setConnected(false);
      resetRoomView();
      socket = null;
      log(\"disconnected\");
      scheduleReconnect();
    });

    ws.addEventListener(\"error\", () => {
      if (!isCurrent()) return;
      log(\"connection error\");
    });
  }

  joinForm.addEventListener(\"submit\", (event) => {
    event.preventDefault();
    if (socket) {
      log(\"already connecting or connected\");
      return;
    }

    const roomId = roomInput.value.trim();
    const displayName = nameInput.value.trim();
    if (!roomId || !displayName) {
      log(\"room ID と display name を入力してください\");
      return;
    }
    // maxlength=\"64\" は UTF-16 コード単位でのみ制限するが、サーバの
    // is_valid_field は UTF-8 バイト数(<=64)も要求する。マルチバイト文字は
    // maxlength を満たしても超過しうるため、送信前にここで検知する(#549)。
    if (byteLength(roomId) > 64 || byteLength(displayName) > 64) {
      log(\"room ID・display name は UTF-8 で64バイト以内にしてください（マルチバイト文字は文字数より少なく入力してください）\");
      return;
    }

    cancelReconnect();
    lastJoin = { roomId, displayName };
    connect(roomId, displayName);
  });

  function byteLength(value) {
    return new TextEncoder().encode(value).length;
  }

  function sendIfOpen(message) {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
      afterSend(message);
      return true;
    }
    log(\"not connected, ignoring \" + message.type);
    return false;
  }
"
