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
│   └── post-stop-check.sh  # Stop hook 本体（just check を呼ぶ）
└── README.md            # この設定の説明

（リポジトリ直下）
├── justfile              # build / test / format / check の標準動詞
└── lefthook.yml          # pre-commit / pre-push の決定的検証ゲート
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

`hooks/post-stop-check.sh` は、次のいずれかのファイルが変わったターンでのみ
`just check`（`justfile` 参照）を実行する:

`src/*.gleam` / `test/*.gleam` / `gleam.toml` / `manifest.toml` /
`test/client/*.test.mjs` / `test/client/harness.mjs` / `test/client/extract.mjs`

（bash の `case` パターンは（ファイルグロブと違い）`*` が `/` をまたいでマッチするため、
`src/*.gleam` だけで `src/gleamroom/web.gleam` / `web_poker.gleam` のようなネストした
ファイルも正しく拾える。#499 はこの挙動を誤認した報告で、実際には検知漏れはなかった）

以前は「Gleam側の変更なら format/build/test」「client JS側の変更なら node --test」と
2系統に分けてトリガー対象ファイルを個別に列挙していたが、web.gleam / web_poker.gleam の
ようにどちらのカテゴリにも影響するファイルをリストへ追加し忘れるたびに検知漏れバグを
作っていた（#183, #305, #466）。`just check` に一本化し、トリガーが立ったら常に
`.github/workflows/ci.yml` と同じ全チェック（format → build → test → client JS test →
shellcheck）を回すことで、この種のバグの発生源そのものを消した（#356）。

Issue #1（Gleam プロジェクト bootstrap）・Issue #10（CI 整備）が両方 CLOSED になり
検証できない状態を成功扱いする心配が無くなったため導入した。

`.codex/hooks/post-stop-check.sh` は上記と同種の Stop hook だが、`.codex/` 自体が
`.gitignore` 対象の個人ローカル層（Codex CLI / pi のローカル生成物と同様）であり、
このリポジトリの共有状態ではない。したがって `.claude/hooks/post-stop-check.sh` への
修正は自動的には反映されず、他クローン・他コントリビューター環境にも存在するとは
限らない（#337）。同じ理由で CI の shellcheck（`scandir: ./.claude/hooks`）は
`.codex/hooks/post-stop-check.sh` を対象にできない（CI の checkout に `.codex/` 自体が
存在しない）。`scandir` に `./.codex/hooks` を追加しても走査対象が無いだけなので、
そちらでの解決は避ける（#461）。

Codex を使う場合は、内容を手動コピーして同期し続けるのではなく、
`.codex/hooks/post-stop-check.sh` を `.claude/hooks/post-stop-check.sh` への
シンボリックリンクにすること。実体は1つだけになり、CI の shellcheck も
（`.claude/hooks` 経由で）実質的にカバーする。

```sh
rm -f .codex/hooks/post-stop-check.sh
ln -s ../../.claude/hooks/post-stop-check.sh .codex/hooks/post-stop-check.sh
```

## justfile / lefthook

- `justfile`: `build` / `test` / `format` / `check` の標準動詞（`just --list` で一覧）。
  `check` が `.github/workflows/ci.yml` と同じ手順を直列実行する唯一の場所で、
  Stop hook もこれを呼ぶ（#356）。以前は「Stop hook と CI がすでに決定的チェックを
  担っているので不要」として意図的に未導入だったが、その二重管理自体が
  検知漏れバグ（#305, #466）の温床になっていたため方針を変更した。
- `lefthook.yml`: pre-commit で `gleam format --check`（変更 .gleam のみ）と
  `typos`、pre-push で `gleam test` を実行する（導入: `lefthook install`）。

## 意図的に未導入の設定

- format-on-write hook: formatter の対象範囲が広がるたびに個別リポジトリの都合で
  分岐させたくないため、現時点では Stop hook の `gleam format --check` のみに留める。

codex stop review gate は、ワークスペース共通方針どおり無効のまま運用します。
