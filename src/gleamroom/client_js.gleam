/// Browser-client JS shared by the buzzer (`web.gleam`) and Planning Poker
/// (`web_poker.gleam`) pages.
///
/// Both pages stay a single static HTML document with inline JS and no build
/// step: this constant is concatenated into each page's `<script>` with Gleam's
/// `<>`, so it runs inside the page's own IIFE and shares its scope. The page
/// must declare, before this snippet is spliced in:
///
/// - DOM refs `joinForm`, `roomInput`, `nameInput`, `logEl`, `statusEl`,
///   `joinButton`
/// - `let socket = null`
/// - `const WS_PATH` (e.g. `"/ws"`)
/// - `function joinMessage(roomId, displayName)` returning the first message
///   sent on each connection (the buzzer adds its protocol version and sends
///   `resume` instead of `join` when it holds a resume token, #766)
/// - `const afterSend = (message) => {...}` (called after a successful send)
/// - functions `setConnected(connected)`, `resetRoomView()` (clear the
///   page's room state and re-render) and `handleServerMessage(message)`
///
/// and may call `handleConnectionError(code)` from its `error` case.
/// The test extractor (`test/client/extract.mjs`) resolves the same
/// concatenation, so the client JS tests exercise the spliced result.
pub const shared =
  "
  // What a reconnect sends is up to the page (`joinMessage`): Planning Poker
  // re-joins as a new participant, the buzzer resumes the same participant
  // with its resume token (#766). A fixed, small retry count keeps this
  // \"simple\" rather than a full exponential-backoff strategy.
  const RECONNECT_DELAY_MS = 1500;
  const MAX_RECONNECT_ATTEMPTS = 5;
  let lastJoin = null;
  let reconnectAttempts = 0;
  let reconnectTimer = null;
  // 接続開始から join 成立（最初の state）までの待機上限（#696）。通知が途絶えても
  // socket が残り続けて再 join も自動再接続もできなくなるのを防ぐ。
  const JOIN_TIMEOUT_MS = 10000;
  let joinTimer = null;

  // アプリレベルの keepalive（#764）。サーバは30秒窓で、窓内にクライアントから
  // 1フレームも届かなければ接続を閉じる。無操作でも窓あたり2回送れる間隔にする。
  // ブラウザが背面タブでタイマーを間引いた場合は切断されうるが、close から
  // 既存の自動再接続（lastJoin）で再 join する。
  const PING_INTERVAL_MS = 15000;
  let pingTimer = null;

  function stopPing() {
    if (pingTimer) {
      clearInterval(pingTimer);
      pingTimer = null;
    }
  }

  function startPing(ws, isCurrent) {
    stopPing();
    const timer = setInterval(() => {
      if (!isCurrent() || ws.readyState !== WebSocket.OPEN) {
        clearInterval(timer);
        if (pingTimer === timer) pingTimer = null;
        return;
      }
      ws.send(JSON.stringify({ type: \"ping\" }));
    }, PING_INTERVAL_MS);
    pingTimer = timer;
  }

  function clearJoinTimer() {
    if (joinTimer) {
      clearTimeout(joinTimer);
      joinTimer = null;
    }
  }

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

  // token をログに出さない（#767）。ログは画面に表示され、会場のスクリーンに
  // 映ることもある。受信メッセージを丸ごと書く行でも値を伏せる。
  function redactTokens(line) {
    return String(line).replace(/(\"[A-Za-z_]*token\"\\s*:\\s*\")[^\"]*\"/g, '$1[redacted]\"');
  }

  function log(line) {
    const entry = document.createElement(\"div\");
    entry.textContent = `[${new Date().toLocaleTimeString()}] ${redactTokens(line)}`;
    logEl.append(entry);
    while (logEl.children.length > MAX_LOG_ENTRIES) {
      logEl.firstElementChild.remove();
    }
    logEl.scrollTop = logEl.scrollHeight;
  }

  // サーバとページの版が合わない（#765）。再読み込みでしか直らないので、
  // 自動再接続を止めて利用者に再読み込みを促す。
  function markOutdated() {
    clearJoinTimer();
    stopPing();
    cancelReconnect();
    if (socket) socket.close();
    socket = null;
    lastJoin = null;
    setConnected(false);
    resetRoomView();
    statusEl.textContent = \"ページを再読み込みしてください\";
    statusEl.dataset.state = \"outdated\";
    joinButton.disabled = true;
    log(\"このページは古い版です。ページを再読み込みしてください\");
  }

  // Handles the join/connection-level error codes common to both pages.
  // Returns true when the code was consumed.
  function handleConnectionError(code) {
    if (code === \"client_outdated\") {
      markOutdated();
      return true;
    }
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
      clearJoinTimer();
      stopPing();
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

    // join 成立（state 受信）・拒否・切断のいずれでも解除される。期限超過時は旧 socket を
    // 破棄して既存の回数制限付き再接続へ進む。以後の旧 socket のイベントは isCurrent で無視。
    clearJoinTimer();
    joinTimer = setTimeout(() => {
      joinTimer = null;
      if (!isCurrent()) return;
      log(\"join timed out\");
      stopPing();
      socket = null;
      ws.close();
      setConnected(false);
      resetRoomView();
      scheduleReconnect();
    }, JOIN_TIMEOUT_MS);

    ws.addEventListener(\"open\", () => {
      if (!isCurrent()) return;
      // **ここでは setConnected(true) を呼ばない・試行回数も戻さない（#62, #87）。**
      // WebSocket が開いただけでは join できたことにならない。UI が
      // \"connected\" になるのはサーバから state（join成立）が届いたときのみ。
      // join が通らずサーバ側から即切断される状況では open → close が
      // 繰り返され、open ごとに試行回数を 0 に戻すと上限に永久に到達せず、
      // 「5 回で諦める」という約束が効かなくなる。
      startPing(ws, isCurrent);
      const first = joinMessage(roomId, displayName);
      const action =
        first.type === \"create\"
          ? \"creating a room\"
          : `${first.type === \"resume\" ? \"resuming\" : \"joining\"} room ${roomId}`;
      log(`connected, ${action} as ${displayName}`);
      ws.send(JSON.stringify(first));
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
      // keepalive への応答。画面にもログにも出さない（#764）。
      if (message && message.type === \"pong\") return;
      // Join 期限の解除は各ページが state を妥当と確認した後に行う（#706）。
      try {
        handleServerMessage(message);
      } catch (err) {
        log(`failed to handle server message: ${event.data} (${err?.message ?? err})`);
      }
    });

    ws.addEventListener(\"close\", () => {
      if (!isCurrent()) return;
      clearJoinTimer();
      stopPing();
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
      statusEl.textContent = \"部屋コードと名前を入力してください\";
      return;
    }
    // maxlength=\"64\" は UTF-16 コード単位でのみ制限するが、サーバの
    // is_valid_field は UTF-8 バイト数(<=64)も要求する。マルチバイト文字は
    // maxlength を満たしても超過しうるため、送信前にここで検知する(#549)。
    if (byteLength(roomId) > 64 || byteLength(displayName) > 64) {
      const problem = \"room ID・display name は UTF-8 で64バイト以内にしてください（マルチバイト文字は文字数より少なく入力してください）\";
      log(problem);
      statusEl.textContent = problem;
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

/// QR code encoder for the buzzer's invite URL (#767), spliced into the
/// buzzer page only. Generated in the page so the invite URL is never sent to
/// an external QR service. It defines `qrMatrix(text, mask?)`; the client
/// tests (`test/client/qr.test.mjs`) compare its output with reference
/// matrices.
pub const qr_code =
  "
  // 招待 URL の QR コード（#767）。外部サービスへ URL を送らないよう、ページ内で
  // 生成する。対象は短い URL だけなので、バイトモード・誤り訂正レベル M・
  // 型番 1〜10 に限った最小の実装にしている（JIS X 0510 / ISO/IEC 18004）。
  // 戻り値は行ごとの真偽値の配列（true が暗）。収まらなければ null。
  // mask を指定しなければ減点が最小のマスクを選ぶ。
  const QR_EC_CODEWORDS_PER_BLOCK = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];
  const QR_EC_BLOCKS = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];

  function qrRawModules(ver) {
    let result = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
      const numAlign = Math.floor(ver / 7) + 2;
      result -= (25 * numAlign - 10) * numAlign - 55;
      if (ver >= 7) result -= 36;
    }
    return result;
  }

  function qrDataCodewords(ver) {
    return Math.floor(qrRawModules(ver) / 8) - QR_EC_CODEWORDS_PER_BLOCK[ver] * QR_EC_BLOCKS[ver];
  }

  function qrAlignmentPositions(ver) {
    if (ver === 1) return [];
    const numAlign = Math.floor(ver / 7) + 2;
    const step = Math.ceil((ver * 4 + 4) / (numAlign * 2 - 2)) * 2;
    const result = [6];
    for (let pos = ver * 4 + 10; result.length < numAlign; pos -= step) {
      result.splice(1, 0, pos);
    }
    return result;
  }

  function qrMultiply(x, y) {
    let z = 0;
    for (let i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >>> 7) * 0x11d);
      z ^= ((y >>> i) & 1) * x;
    }
    return z;
  }

  function qrReedSolomon(data, degree) {
    const divisor = new Array(degree).fill(0);
    divisor[degree - 1] = 1;
    let root = 1;
    for (let i = 0; i < degree; i++) {
      for (let j = 0; j < degree; j++) {
        divisor[j] = qrMultiply(divisor[j], root);
        if (j + 1 < degree) divisor[j] ^= divisor[j + 1];
      }
      root = qrMultiply(root, 0x02);
    }
    const result = new Array(degree).fill(0);
    for (const b of data) {
      const factor = b ^ result.shift();
      result.push(0);
      divisor.forEach((coef, i) => {
        result[i] ^= qrMultiply(coef, factor);
      });
    }
    return result;
  }

  function qrMatrix(text, mask) {
    const bytes = [...new TextEncoder().encode(text)];
    let ver = 1;
    while (ver <= 10 && 4 + (ver < 10 ? 8 : 16) + bytes.length * 8 > qrDataCodewords(ver) * 8) ver++;
    if (ver > 10) return null;

    const capacity = qrDataCodewords(ver) * 8;
    const bits = [];
    const put = (value, length) => {
      for (let i = length - 1; i >= 0; i--) bits.push((value >>> i) & 1);
    };
    put(0b0100, 4);
    put(bytes.length, ver < 10 ? 8 : 16);
    bytes.forEach((b) => put(b, 8));
    put(0, Math.min(4, capacity - bits.length));
    put(0, (8 - (bits.length % 8)) % 8);
    for (let pad = 0xec; bits.length < capacity; pad ^= 0xec ^ 0x11) put(pad, 8);
    const data = [];
    for (let i = 0; i < bits.length; i += 8) {
      data.push(bits.slice(i, i + 8).reduce((acc, bit) => (acc << 1) | bit, 0));
    }

    // 誤り訂正符号を付け、ブロックを交互に並べる。
    const numBlocks = QR_EC_BLOCKS[ver];
    const eccLen = QR_EC_CODEWORDS_PER_BLOCK[ver];
    const rawCodewords = Math.floor(qrRawModules(ver) / 8);
    const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
    const shortBlockLen = Math.floor(rawCodewords / numBlocks);
    const blocks = [];
    for (let i = 0, k = 0; i < numBlocks; i++) {
      const dat = data.slice(k, k + shortBlockLen - eccLen + (i < numShortBlocks ? 0 : 1));
      k += dat.length;
      const ecc = qrReedSolomon(dat, eccLen);
      if (i < numShortBlocks) dat.push(0);
      blocks.push(dat.concat(ecc));
    }
    const codewords = [];
    for (let i = 0; i < blocks[0].length; i++) {
      blocks.forEach((block, j) => {
        if (i !== shortBlockLen - eccLen || j >= numShortBlocks) codewords.push(block[i]);
      });
    }

    const size = ver * 4 + 17;
    const modules = Array.from({ length: size }, () => new Array(size).fill(false));
    const isFunction = Array.from({ length: size }, () => new Array(size).fill(false));
    const setFunction = (x, y, dark) => {
      modules[y][x] = dark;
      isFunction[y][x] = true;
    };

    for (let i = 0; i < size; i++) {
      setFunction(6, i, i % 2 === 0);
      setFunction(i, 6, i % 2 === 0);
    }
    for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
      for (let dy = -4; dy <= 4; dy++) {
        for (let dx = -4; dx <= 4; dx++) {
          const dist = Math.max(Math.abs(dx), Math.abs(dy));
          const x = cx + dx;
          const y = cy + dy;
          if (x >= 0 && x < size && y >= 0 && y < size) setFunction(x, y, dist !== 2 && dist !== 4);
        }
      }
    }
    const align = qrAlignmentPositions(ver);
    align.forEach((ay, i) => {
      align.forEach((ax, j) => {
        const corner =
          (i === 0 && j === 0) || (i === 0 && j === align.length - 1) || (i === align.length - 1 && j === 0);
        if (corner) return;
        for (let dy = -2; dy <= 2; dy++) {
          for (let dx = -2; dx <= 2; dx++) {
            setFunction(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
          }
        }
      });
    });

    const drawFormat = (maskId) => {
      // 誤り訂正レベル M の書式ビットは 00。
      const formatData = maskId;
      let rem = formatData;
      for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
      const format = ((formatData << 10) | rem) ^ 0x5412;
      const bit = (i) => ((format >>> i) & 1) !== 0;
      for (let i = 0; i <= 5; i++) setFunction(8, i, bit(i));
      setFunction(8, 7, bit(6));
      setFunction(8, 8, bit(7));
      setFunction(7, 8, bit(8));
      for (let i = 9; i < 15; i++) setFunction(14 - i, 8, bit(i));
      for (let i = 0; i < 8; i++) setFunction(size - 1 - i, 8, bit(i));
      for (let i = 8; i < 15; i++) setFunction(8, size - 15 + i, bit(i));
      setFunction(8, size - 8, true);
    };
    drawFormat(0);
    if (ver >= 7) {
      let rem = ver;
      for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
      const version = (ver << 12) | rem;
      for (let i = 0; i < 18; i++) {
        const dark = ((version >>> i) & 1) !== 0;
        const a = size - 11 + (i % 3);
        const b = Math.floor(i / 3);
        setFunction(a, b, dark);
        setFunction(b, a, dark);
      }
    }

    // データを右下から 2 列ずつジグザグに置く。
    let index = 0;
    for (let right = size - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let vert = 0; vert < size; vert++) {
        for (let j = 0; j < 2; j++) {
          const x = right - j;
          const upward = ((right + 1) & 2) === 0;
          const y = upward ? size - 1 - vert : vert;
          if (!isFunction[y][x] && index < codewords.length * 8) {
            modules[y][x] = ((codewords[index >>> 3] >>> (7 - (index & 7))) & 1) !== 0;
            index++;
          }
        }
      }
    }

    const masks = [
      (x, y) => (x + y) % 2 === 0,
      (x, y) => y % 2 === 0,
      (x, y) => x % 3 === 0,
      (x, y) => (x + y) % 3 === 0,
      (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
      (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
      (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
      (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
    ];
    const applyMask = (maskId) => {
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
          if (!isFunction[y][x] && masks[maskId](x, y)) modules[y][x] = !modules[y][x];
        }
      }
    };

    const penalty = () => {
      let result = 0;
      const finderLike = (history) => {
        const n = history[1];
        const core = n > 0 && history[2] === n && history[3] === n * 3 && history[4] === n && history[5] === n;
        return (
          (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0) +
          (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
        );
      };
      const addHistory = (length, history) => {
        if (history[0] === 0) length += size;
        history.pop();
        history.unshift(length);
      };
      const scanLine = (get) => {
        let runColor = false;
        let run = 0;
        const history = [0, 0, 0, 0, 0, 0, 0];
        for (let i = 0; i < size; i++) {
          if (get(i) === runColor) {
            run++;
            if (run === 5) result += 3;
            else if (run > 5) result++;
          } else {
            addHistory(run, history);
            if (!runColor) result += finderLike(history) * 40;
            runColor = get(i);
            run = 1;
          }
        }
        if (runColor) {
          addHistory(run, history);
          run = 0;
        }
        addHistory(run + size, history);
        result += finderLike(history) * 40;
      };
      for (let y = 0; y < size; y++) scanLine((x) => modules[y][x]);
      for (let x = 0; x < size; x++) scanLine((y) => modules[y][x]);
      for (let y = 0; y < size - 1; y++) {
        for (let x = 0; x < size - 1; x++) {
          const c = modules[y][x];
          if (c === modules[y][x + 1] && c === modules[y + 1][x] && c === modules[y + 1][x + 1]) result += 3;
        }
      }
      const dark = modules.reduce((sum, row) => sum + row.filter(Boolean).length, 0);
      const total = size * size;
      result += (Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
      return result;
    };

    let chosen = mask;
    if (chosen === undefined) {
      let best = Infinity;
      for (let m = 0; m < 8; m++) {
        applyMask(m);
        drawFormat(m);
        const score = penalty();
        if (score < best) {
          best = score;
          chosen = m;
        }
        applyMask(m);
      }
    }
    applyMask(chosen);
    drawFormat(chosen);
    return modules;
  }
"
