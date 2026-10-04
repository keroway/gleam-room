// scripts/check-duplication-inventory-refs.js(CIゲート)自身の単体テスト(#611)。
// 固定fixtureのツリーを一時ディレクトリに作り、子プロセスとして実行して
// 終了コードとメッセージを検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const script = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../scripts/check-duplication-inventory-refs.js"
);

// files: { "src/a.gleam": "line1\nline2", ... }, doc: markdown本文
function run(files, doc) {
  const root = mkdtempSync(join(tmpdir(), "dupref-"));
  try {
    for (const [rel, body] of Object.entries(files)) {
      mkdirSync(dirname(join(root, rel)), { recursive: true });
      writeFileSync(join(root, rel), body);
    }
    mkdirSync(join(root, "src"), { recursive: true });
    mkdirSync(join(root, "test"), { recursive: true });
    writeFileSync(join(root, "doc.md"), doc);
    const r = spawnSync("node", [script, "doc.md"], {
      env: { ...process.env, DUPLICATION_REFS_ROOT: root },
      encoding: "utf8",
    });
    return { code: r.status, out: r.stdout, err: r.stderr };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const FILE = "pub fn alpha() {\n  1\n}\n\npub fn beta() {\n  2\n}\n";

test("シンボルが範囲内にある引用は通る", () => {
  const r = run({ "src/a.gleam": FILE }, "- `alpha` は `a.gleam:1-3` にある\n");
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /1 citations checked/);
});

test("範囲がファイル長を超える引用はエラー", () => {
  const r = run({ "src/a.gleam": FILE }, "- `alpha` は `a.gleam:1-99`\n");
  assert.equal(r.code, 1);
  assert.match(r.err, /out of bounds/);
});

test("start > end の引用はエラー", () => {
  const r = run({ "src/a.gleam": FILE }, "- `alpha` は `a.gleam:3-1`\n");
  assert.equal(r.code, 1);
  assert.match(r.err, /out of bounds/);
});

test("直前のシンボルが範囲内に無ければドリフトとして検知する", () => {
  const r = run({ "src/a.gleam": FILE }, "- `beta` は `a.gleam:1-3`\n");
  assert.equal(r.code, 1);
  assert.match(r.err, /does not contain any of \[beta\]/);
});

test("汎用シンボルのみのbulletは境界チェックだけで通る", () => {
  const r = run({ "src/a.gleam": FILE }, "- `None` は `a.gleam:5-7`\n");
  assert.equal(r.code, 0, r.err);
});

test("汎用シンボルのみでも範囲外ならエラー", () => {
  const r = run({ "src/a.gleam": FILE }, "- `None` は `a.gleam:50`\n");
  assert.equal(r.code, 1);
  assert.match(r.err, /out of bounds/);
});

test("同名ファイルが複数ディレクトリにあれば ambiguous エラー", () => {
  const r = run(
    { "src/a.gleam": FILE, "test/a.gleam": FILE },
    "- `alpha` は `a.gleam:1-3`\n"
  );
  assert.equal(r.code, 1);
  assert.match(r.err, /ambiguous file: a\.gleam/);
});

test("存在しないファイルの引用はエラー", () => {
  const r = run({ "src/a.gleam": FILE }, "- `alpha` は `missing.gleam:1`\n");
  assert.equal(r.code, 1);
  assert.match(r.err, /file not found: missing\.gleam/);
});

test("複数行にまたがるbulletは1つとして扱い、空行で区切られる", () => {
  const ok = run(
    { "src/a.gleam": FILE },
    "- `beta` は\n  `a.gleam:5-7` にある\n"
  );
  assert.equal(ok.code, 0, ok.err);
  // 空行を挟むと別bulletになり、シンボルが引き継がれない(=境界チェックのみ)
  const split = run(
    { "src/a.gleam": FILE },
    "- `beta` はここ\n\n  `a.gleam:1-3`\n"
  );
  assert.equal(split.code, 0, split.err);
  assert.match(split.out, /0 citations checked/);
});

test("bulletでない散文段落内の引用も検証する(#605)", () => {
  const ok = run(
    { "src/a.gleam": FILE },
    "本文で `beta` を呼ぶ\n(`a.gleam:5-7`)。\n"
  );
  assert.equal(ok.code, 0, ok.err);
  assert.match(ok.out, /1 citations checked/);
  const drift = run(
    { "src/a.gleam": FILE },
    "本文で `beta` を呼ぶ\n(`a.gleam:1-3`)。\n"
  );
  assert.equal(drift.code, 1);
  assert.match(drift.err, /does not contain any of \[beta\]/);
});

test("カンマ区切りの複数範囲を個別に検証する", () => {
  const r = run(
    { "src/a.gleam": FILE },
    "- `alpha` は `a.gleam:1-3,50-60`\n"
  );
  assert.equal(r.code, 1);
  assert.match(r.err, /a\.gleam:50-60 out of bounds/);
});
