// 招待 URL の QR コード生成（#767）。外部サービスへ URL を送らないよう、ページ内の
// 小さな実装で生成している。
//
// qr-fixtures.json は segno 1.6.6（Python）で同じ文字列・同じマスクから生成した
// 行列。データがちょうど容量いっぱいになる長さを選んでいるので、パディングの
// 入れ方の違い（segno は終端の後に 0x00 を1バイト足す）に左右されず、型番
// 1/2/3/4/7/10（単一・複数ブロック、型番情報あり）の配置と誤り訂正を比べられる。
// 生成手順: segno.make_qr(text.encode(), error="m", mask=mask, mode="byte",
// boost_error=False).matrix の各行を2進数として16進で書いたもの。
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { clientJsConst } from "./extract.mjs";

const { qrMatrix } = new Function(`${clientJsConst("qr_code")}; return { qrMatrix };`)();
const fixtures = JSON.parse(
  fs.readFileSync(new URL("./qr-fixtures.json", import.meta.url), "utf8"),
);

const toHexRows = (matrix) =>
  matrix.map((row) => {
    const bits = row.map(Number).join("");
    return BigInt(`0b${bits}`).toString(16).padStart(Math.ceil(bits.length / 4), "0");
  });

for (const { text, mask, version, rows } of fixtures) {
  test(`型番 ${version}・マスク ${mask} の行列が参照実装と一致する`, () => {
    const matrix = qrMatrix(text, mask);
    assert.equal(matrix.length, version * 4 + 17);
    assert.deepEqual(toHexRows(matrix), rows);
  });
}

test("マスクを指定しなければ8種のどれかを選び、選んだマスクの行列と同じになる", () => {
  const text = "http://192.168.1.20:4000/r/ZX9K2M";
  const auto = toHexRows(qrMatrix(text));
  const candidates = [0, 1, 2, 3, 4, 5, 6, 7].map((m) => toHexRows(qrMatrix(text, m)));
  assert.equal(candidates.filter((c) => JSON.stringify(c) === JSON.stringify(auto)).length, 1);
});

test("データの後ろは終端・バイト境界・規定のパディング（0xEC/0x11）で埋まる", () => {
  // 型番1-M は 16 データコード語。"x" は 0100 00000001 01111000 + 終端 0000。
  // 読み取りは配置の逆（右下から2列ずつジグザグ）。
  const matrix = qrMatrix("x", 0);
  const size = matrix.length;
  const isFunction = (x, y) =>
    (x < 9 && y < 9) || (x >= size - 8 && y < 9) || (x < 9 && y >= size - 8) || x === 6 || y === 6;
  const bits = [];
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const y = ((right + 1) & 2) === 0 ? size - 1 - vert : vert;
        if (!isFunction(x, y)) bits.push(matrix[y][x] !== ((x + y) % 2 === 0));
      }
    }
  }
  const codewords = [];
  for (let i = 0; i + 8 <= 16 * 8; i += 8) {
    codewords.push(bits.slice(i, i + 8).reduce((acc, bit) => (acc << 1) | Number(bit), 0));
  }
  assert.deepEqual(codewords, [0x40, 0x17, 0x80, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec]);
});

test("型番10に収まらない長さは null", () => {
  assert.equal(qrMatrix("a".repeat(214)), null);
  assert.notEqual(qrMatrix("a".repeat(213)), null);
});
