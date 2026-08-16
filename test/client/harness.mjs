// クライアント JS を Node 上で動かすための最小スタブ。
//
// ブラウザ自動化（Playwright 等）は入れない。検証したいのは再接続の
// **試行回数とタイマー解除**であって描画ではなく、そのためにブラウザを
// 起動するのは割に合わない。DOM は「呼ばれても落ちない」程度に留める。
import { extractClientScript, extractElementIds } from "./extract.mjs";

export function startClient() {
  const knownIds = extractElementIds();
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
      replaceChildren() {},
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
      constructor() {
        this.handlers = {};
        sockets.push(this);
      }
      addEventListener(type, fn) {
        this.handlers[type] = fn;
      }
      send() {}
      close() {}
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
  // eslint-disable-next-line no-eval
  (0, eval)(extractClientScript());

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
    /// status 要素の接続状態（"connected"/"disconnected"）を読む。
    connectionState() {
      return nodes.get("status")?.dataset.state;
    },
    /// #log 要素が保持している子要素（ログ行）の件数。
    logEntryCount() {
      return nodes.get("log")?.children.length ?? 0;
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
    /// 差し替えたグローバルを元に戻す。テストごとに必ず呼ぶ。
    dispose() {
      for (const key of Object.keys(sandbox)) globalThis[key] = saved[key];
    },
  };
}
