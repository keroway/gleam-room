# gleam-room — Claude Code setup

このディレクトリには、リポジトリで共有する Claude Code 固有の設定を置きます。
プロジェクト共通の指示はルートの `CLAUDE.md` を正とし、Codex / pi は
`AGENTS.md` から同じ内容を参照します。

## 現在の構成

```text
.claude/
├── settings.json        # 承認なしで実行してよいコマンドの共有許可
├── settings.local.json  # 個人設定（gitignore、コミット対象外）
└── README.md            # この設定の説明
```

### `settings.json` の許可の基準

**「読み取り専用」ではない**（#133）。`gleam build` / `format` / `clean` や
`node --test` のように、**プロジェクト内に書き込む・消す・実行する**コマンドも
含まれる。基準は「読むだけか」ではなく:

- **プロジェクト外へ影響しないこと。** ビルド成果物の生成や `build/` の削除は
  やり直せるが、リポジトリの外を触るものは入れない
- **任意コマンド実行の逃げ道が無いこと。** 末尾を `*` で開くのは、そのフラグに
  任意実行や任意パス書き込みが無い場合だけ。例えば
  `Bash(node --test 'test/client/*.test.mjs')` は呼び出し形を固定しており、
  `node --test *` にはしていない（任意のファイルをテストとして実行できるため）
- 破壊的な git 操作（`git reset --hard` / `branch -D` 等）は含めない。
  `git diff` / `log` / `branch` も**個別の安全な呼び出し形だけ**を列挙している

## 意図的に未導入の設定

- Stop hook: Gleam アプリケーションと CI の決定的な検証コマンドがまだ存在しないため。
- format-on-write hook: formatter の対象範囲が Issue #1 の bootstrap で確定していないため。
- `justfile` / lefthook: 実際の Gleam プロジェクト構成と CI を薄く委譲できる段階で追加する。

Issue #1 で Gleam プロジェクトを作成し、Issue #10 で CI を整備した後、
`agent-assets/templates/` を基に `gleam format --check`、`gleam build
--warnings-as-errors`、`gleam test` と整合する構成を検討します。検証できない状態を
成功扱いする hook は追加しません。

codex stop review gate は、ワークスペース共通方針どおり無効のまま運用します。
