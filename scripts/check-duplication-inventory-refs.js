#!/usr/bin/env node
// docs/duplication-inventory.md が引用する `file:line` / `file:start-end`
// が実ファイルの範囲内に収まっているか、直前に挙げた識別子(関数/型/定数名)が
// その範囲内に実在するかを機械的に検証する(#387)。
//
// 完全な意味検証ではなく、行番号ドリフトを検知するための軽量チェック。各
// bullet内をbacktickトークンの出現順に走査し、「直前に出た識別子トークン」を
// その後に続く引用の対応シンボルとして扱う。
"use strict";

const fs = require("fs");
const path = require("path");

const repoRoot = path.resolve(__dirname, "..");
const docPath = process.argv[2] || "docs/duplication-inventory.md";
const docAbsPath = path.isAbsolute(docPath)
  ? docPath
  : path.join(repoRoot, docPath);
const doc = fs.readFileSync(docAbsPath, "utf8");

const CITATION_SINGLE_RE = /^([A-Za-z0-9_.\-\/]+\.(?:gleam|mjs)):([0-9,\-]+)$/;
const SOURCE_FILE_RE = /\.(gleam|mjs|md)$/;

function findSourceFile(basename) {
  const candidates = [];
  for (const dir of ["src", "test"]) {
    const walk = (d) => {
      for (const entry of fs.readdirSync(path.join(repoRoot, d), {
        withFileTypes: true,
      })) {
        const rel = path.join(d, entry.name);
        if (entry.isDirectory()) {
          walk(rel);
        } else if (entry.name === basename) {
          candidates.push(rel);
        }
      }
    };
    walk(dir);
  }
  if (candidates.length === 1) return candidates[0];
  if (candidates.length > 1) return { ambiguous: candidates };
  return null;
}

function parseRanges(spec) {
  // "16-27" / "56" / "98-101,135-139" -> [[16,27],[56,56],...]
  return spec.split(",").map((part) => {
    const [a, b] = part.split("-").map(Number);
    return [a, b === undefined ? a : b];
  });
}

function leadingIdentifier(token) {
  const m = token.match(/^[A-Za-z_][A-Za-z0-9_]*/);
  return m ? m[0] : null;
}

// bullet単位に分割する: "- " で始まる行から、次の "- " / 見出し / 空行までを1bulletとする
function extractBullets(text) {
  const lines = text.split("\n");
  const bullets = [];
  let current = null;
  for (const line of lines) {
    if (/^- /.test(line)) {
      if (current) bullets.push(current);
      current = line;
    } else if (current && /^  \S/.test(line)) {
      current += " " + line.trim();
    } else {
      if (current) bullets.push(current);
      current = null;
    }
  }
  if (current) bullets.push(current);
  return bullets;
}

const fileCache = new Map();
function readLines(relPath) {
  if (!fileCache.has(relPath)) {
    fileCache.set(
      relPath,
      fs.readFileSync(path.join(repoRoot, relPath), "utf8").split("\n")
    );
  }
  return fileCache.get(relPath);
}

// 汎用すぎて「この範囲にある」ことの証拠にならない識別子(Gleamの組み込み型/
// バリアント)。これらはシンボル一致チェックをスキップし、範囲の境界チェックのみ行う。
const GENERIC_SYMBOLS = new Set([
  "None", "Some", "True", "False", "Ok", "Error", "Nil",
  "Bool", "String", "Int", "List", "Dict", "Option",
]);

let errors = [];
let checked = 0;

for (const bullet of extractBullets(doc)) {
  const seenSymbols = [];
  for (const m of bullet.matchAll(/`([^`]+)`/g)) {
    const token = m[1];
    const citationMatch = token.match(CITATION_SINGLE_RE);
    if (citationMatch) {
      checked++;
      const [, basename, rangeSpec] = citationMatch;
      const resolved = findSourceFile(basename);
      if (!resolved) {
        errors.push(`file not found: ${basename} (cited as \`${token}\`)`);
        continue;
      }
      if (resolved.ambiguous) {
        errors.push(
          `ambiguous file: ${basename} matches ${resolved.ambiguous.join(", ")}`
        );
        continue;
      }
      const lines = readLines(resolved);
      const candidates = seenSymbols.filter((s) => !GENERIC_SYMBOLS.has(s));
      for (const [start, end] of parseRanges(rangeSpec)) {
        if (start < 1 || end > lines.length || start > end) {
          errors.push(
            `${resolved}:${start}-${end} out of bounds (file has ${lines.length} lines), cited in: "${bullet.trim().slice(0, 90)}..."`
          );
          continue;
        }
        // このbulletで直前までに出た識別子のうち、どれか1つでもこの範囲に
        // 実在すれば良しとする(複数シンボルを1つの引用にまとめている場合の
        // 誤検知を避けるため)。汎用識別子しか無ければ境界チェックのみ。
        if (candidates.length > 0) {
          const slice = lines.slice(start - 1, end).join("\n");
          const found = candidates.some((symbol) => {
            const re = new RegExp(
              "\\b" + symbol.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\b"
            );
            return re.test(slice);
          });
          if (!found) {
            errors.push(
              `${resolved}:${start}-${end} does not contain any of [${candidates.join(", ")}], cited in: "${bullet.trim().slice(0, 90)}..."`
            );
          }
        }
      }
      continue;
    }
    if (SOURCE_FILE_RE.test(token)) {
      // ファイル名のみの言及(引用ではない)。シンボルは更新しない。
      continue;
    }
    const ident = leadingIdentifier(token);
    if (ident) seenSymbols.push(ident);
  }
}

if (errors.length > 0) {
  console.error(`${docPath}: ${errors.length} citation drift(s) found:\n`);
  for (const e of errors) console.error("  - " + e);
  process.exit(1);
}

console.log(`${docPath}: ${checked} citations checked, no drift detected.`);
