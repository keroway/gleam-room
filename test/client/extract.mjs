// `src/gleamroom/web.gleam` に埋め込まれたクライアント JS を取り出す。
//
// JS を別ファイルへ切り出さずに**埋め込みのまま**テストするのは、
// 二重管理を作らないため。切り出すと Gleam 側から読み込む仕組みが要り、
// 「片方だけ直して気づかない」経路が新しく生まれる。
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export function extractClientScript() {
  const source = fs.readFileSync(path.join(repoRoot, "src/gleamroom/web.gleam"), "utf8");
  const literal = /pub fn index_html\(\) -> String \{\s*"([\s\S]*)"\s*\}\s*$/.exec(source);
  if (!literal) {
    throw new Error("index_html() の文字列リテラルを取り出せませんでした（web.gleam の形が変わった可能性）");
  }
  const html = literal[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  const script = /<script>([\s\S]*?)<\/script>/.exec(html);
  if (!script) {
    throw new Error("<script> ブロックが見つかりませんでした");
  }
  return script[1];
}
