# gleam-room — Claude Code setup

このディレクトリには、リポジトリで共有する Claude Code 固有の設定を置きます。
プロジェクト共通の指示はルートの `CLAUDE.md` を正とし、Codex / pi は
`AGENTS.md` から同じ内容を参照します。

## 現在の構成

```text
.claude/
├── settings.json        # 承認なしで実行してよいコマンドの共有許可 + Stop hook
├── settings.local.json  # 個人設定（gitignore、コミット対象外。beamsg アダプタもここ）
├── hooks/
│   └── post-stop-check.sh  # Stop hook 本体
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

## Stop hook

`hooks/post-stop-check.sh` が、変更されたファイルに応じて `.github/workflows/ci.yml`
と同じコマンドをターン終了ごとに実行する（`agent-assets/templates/post-stop-check.sh`
を基にした構成）:

- `src/*.gleam` / `test/*.gleam` / `gleam.toml` / `manifest.toml` が変わった場合:
  `gleam format --check src test` → `gleam build --warnings-as-errors` → `gleam test`
- `test/client/*.test.mjs` が変わった場合: `node --test 'test/client/*.test.mjs'`
  （web.gleam に埋め込まれたクライアント JS の回帰テスト。Gleam 側からは検証できない）

Issue #1（Gleam プロジェクト bootstrap）・Issue #10（CI 整備）が両方 CLOSED になり
検証できない状態を成功扱いする心配が無くなったため導入した。

## 意図的に未導入の設定

- format-on-write hook: formatter の対象範囲が広がるたびに個別リポジトリの都合で
  分岐させたくないため、現時点では Stop hook の `gleam format --check` のみに留める。
- `justfile` / lefthook: 実際の Gleam プロジェクト構成と CI を薄く委譲できる段階で追加する。

codex stop review gate は、ワークスペース共通方針どおり無効のまま運用します。
