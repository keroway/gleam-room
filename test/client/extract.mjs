// `src/gleamroom/web.gleam` に埋め込まれたクライアント JS を取り出す。
//
// JS を別ファイルへ切り出さずに**埋め込みのまま**テストするのは、
// 二重管理を作らないため。切り出すと Gleam 側から読み込む仕組みが要り、
// 「片方だけ直して気づかない」経路が新しく生まれる。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

const DEFAULT_MODULE_PATH = "src/gleamroom/web.gleam";
const DEFAULT_FUNCTION_NAME = "index_html";

function extractIndexHtml(
  modulePath = DEFAULT_MODULE_PATH,
  functionName = DEFAULT_FUNCTION_NAME,
) {
  const source = fs.readFileSync(path.join(repoRoot, modulePath), "utf8");
  const literal = new RegExp(
    `pub fn ${functionName}\\(\\) -> String \\{\\s*"([\\s\\S]*)"\\s*\\}\\s*$`,
  ).exec(source);
  if (!literal) {
    throw new Error(
      `${functionName}() の文字列リテラルを取り出せませんでした（${modulePath} の形が変わった可能性）`,
    );
  }
  return literal[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
}

export function extractClientScript(modulePath, functionName) {
  const html = extractIndexHtml(modulePath, functionName);
  const script = /<script>([\s\S]*?)<\/script>/.exec(html);
  if (!script) {
    throw new Error("<script> ブロックが見つかりませんでした");
  }
  return script[1];
}

/// 指定したモジュールの HTML 内に実在する要素 id の集合を返す。
/// harness.mjs の DOM スタブが、JS 側の getElementById 呼び出しと
/// HTML 側の id 定義との不一致を検知するために使う。
export function extractElementIds(modulePath, functionName) {
  const html = extractIndexHtml(modulePath, functionName);
  const ids = new Set();
  for (const match of html.matchAll(/\sid="([^"]+)"/g)) {
    ids.add(match[1]);
  }
  return ids;
}
