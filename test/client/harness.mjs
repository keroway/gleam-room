// クライアント JS を Node 上で動かすための最小スタブ。
//
// ブラウザ自動化（Playwright 等）は入れない。中心的な検証対象は再接続の
// **試行回数とタイマー解除**であって、そのためにブラウザを起動するのは
// 割に合わない。DOM は基本的に「呼ばれても落ちない」程度に留めるが、
// replaceChildren() だけは実際に children に反映する（#389）。
// renderParticipants/renderVotes/renderBuzzes が書き込んだ内容を
// childTextContents() 経由でテストから検証できるようにするため。
import { extractClientScript, extractElementIds } from "./extract.mjs";

/// join が成立しないまま open→close を繰り返す状況を作る。
/// サーバが接続直後に切る場合がこれにあたる。
export function flapWithoutJoining(client, rounds) {
  for (let i = 0; i < rounds; i += 1) {
    const before = client.sockets.length;
    const socket = client.latestSocket();
    socket.handlers.open?.();
    socket.handlers.close?.();
    client.runTimers();
    if (client.sockets.length === before) return i + 1; // 再接続を諦めた回
  }
  return null;
}

export function startClient({ modulePath, functionName } = {}) {
  const knownIds = extractElementIds(modulePath, functionName);
  const nodes = new Map();
  const listeners = new Map();
  const logs = [];

  const makeNode = (id) => {
    const children = [];
    return {
      id,
      value: "",
      textContent: "",
      innerHTML: "",
      disabled: false,
      dataset: {},
      attributes: {},
      setAttribute(name, value) {
        this.attributes[name] = String(value);
      },
      getAttribute(name) {
        return this.attributes[name] ?? null;
      },
      children,
      get firstElementChild() {
        return children[0] ?? null;
      },
      classList: { add() {}, remove() {}, toggle() {} },
      appendChild() {},
      append(child) {
        if (!child) return;
        children.push(child);
        child.remove = () => {
          const index = children.indexOf(child);
          if (index !== -1) children.splice(index, 1);
        };
        if (typeof child.textContent === "string") logs.push(child.textContent);
      },
      remove() {},
      replaceChildren(...newChildren) {
        children.length = 0;
        children.push(...newChildren);
      },
      addEventListener(type, fn) {
        listeners.set(`${id}:${type}`, fn);
      },
    };
  };

  const sockets = [];
  let timers = [];
  let nextTimerId = 1;

  const sandbox = {
    document: {
      getElementById(id) {
        if (!knownIds.has(id)) return null;
        if (!nodes.has(id)) nodes.set(id, makeNode(id));
        return nodes.get(id);
      },
      createElement: () => makeNode("created"),
    },
    location: { protocol: "http:", host: "127.0.0.1:4000" },
    setTimeout: (fn, delay) => {
      const id = nextTimerId;
      nextTimerId += 1;
      timers.push({ id, fn, delay });
      return id;
    },
    clearTimeout: (id) => {
      timers = timers.filter((timer) => timer.id !== id);
    },
    WebSocket: class {
      static CONNECTING = 0;
      static OPEN = 1;
      static CLOSING = 2;
      static CLOSED = 3;
      constructor() {
        this.handlers = {};
        this.readyState = this.constructor.CONNECTING;
        this.sent = [];
        sockets.push(this);
      }
      addEventListener(type, fn) {
        // ブラウザは open/close イベント発火前に readyState を更新してから
        // ハンドラを呼ぶ。テストは socket.handlers.open?.() 等でイベントを
        // 直接発火させるため、その経路でも readyState が追従するようにする。
        if (type === "open") {
          this.handlers.open = (...args) => {
            this.readyState = this.constructor.OPEN;
            return fn(...args);
          };
        } else if (type === "close") {
          this.handlers.close = (...args) => {
            this.readyState = this.constructor.CLOSED;
            return fn(...args);
          };
        } else {
          this.handlers[type] = fn;
        }
      }
      send(data) {
        this.sent.push(data);
      }
      close() {
        this.readyState = this.constructor.CLOSED;
      }
    },
  };

  // グローバルを差し替える。**eval 直後には戻せない** — クライアントの
  // クロージャは後から（イベント発火時に）これらを参照するため、
  // 戻すのは dispose() まで遅らせる。
  const saved = {};
  for (const key of Object.keys(sandbox)) {
    saved[key] = globalThis[key];
    globalThis[key] = sandbox[key];
  }
  // 抽出したクライアントスクリプトを差し替え済みグローバルの文脈で実行するために eval を使う。
  (0, eval)(extractClientScript(modulePath, functionName));

  return {
    logs,
    sockets,
    /// 参加フォームを送信して最初の接続を開始する。
    submitJoin(roomId = "R", displayName = "N") {
      nodes.get("room-id").value = roomId;
      nodes.get("display-name").value = displayName;
      listeners.get("join-form:submit")({ preventDefault() {} });
    },
    latestSocket() {
      return sockets[sockets.length - 1];
    },
    /// 指定した id の要素の click リスナーを発火させる。
    click(id) {
      listeners.get(`${id}:click`)?.();
    },
    /// status 要素の接続状態（"connected"/"disconnected"）を読む。
    connectionState() {
      return nodes.get("status")?.dataset.state;
    },
    /// #log 要素が保持している子要素（ログ行）の件数。
    logEntryCount() {
      return nodes.get("log")?.children.length ?? 0;
    },
    /// 指定した id の要素が replaceChildren() で保持している子要素の
    /// textContent 一覧（renderParticipants/renderVotes/renderBuzzes の
    /// 描画結果を検証するためのアクセサ）。
    childTextContents(id) {
      return (nodes.get(id)?.children ?? []).map((child) => child.textContent);
    },
    /// 指定した id の要素の disabled プロパティ。
    isDisabled(id) {
      return nodes.get(id)?.disabled;
    },
    /// 指定した id の要素の指定属性値（setAttribute で設定した値）。
    getAttribute(id, name) {
      return nodes.get(id)?.getAttribute(name) ?? null;
    },
    /// 保留中の setTimeout をすべて発火させる（再接続待ちを進める）。
    /// 実ブラウザの相対順序に合わせ、delay の昇順（同値は登録順）で発火する。
    runTimers() {
      const pending = [...timers].sort((a, b) => a.delay - b.delay);
      timers = [];
      pending.forEach(({ fn }) => fn());
      return pending.length;
    },
    pendingTimers() {
      return timers.length;
    },
    /// 発火前の pending timer の delay 値一覧（登録順）。
    /// 特定の delay 値（例: RECONNECT_DELAY_MS）そのものをテストから
    /// アサートするためのアクセサ。
    timerDelays() {
      return timers.map((timer) => timer.delay);
    },
    /// 差し替えたグローバルを元に戻す。テストごとに必ず呼ぶ。
    dispose() {
      for (const key of Object.keys(sandbox)) globalThis[key] = saved[key];
    },
  };
}
