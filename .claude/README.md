# gleam-room — Claude Code setup

このディレクトリには、リポジトリで共有する Claude Code 固有の設定を置きます。
プロジェクト共通の指示はルートの `CLAUDE.md` を正とし、Codex / pi は
`AGENTS.md` から同じ内容を参照します。

## 現在の構成

```text
.claude/
├── settings.json        # 安全な読み取り専用コマンドの共有許可
├── settings.local.json  # 個人設定（gitignore、コミット対象外）
└── README.md            # この設定の説明
```

## 意図的に未導入の設定

- Stop hook: Gleam アプリケーションと CI の決定的な検証コマンドがまだ存在しないため。
- format-on-write hook: formatter の対象範囲が Issue #1 の bootstrap で確定していないため。
- `justfile` / lefthook: 実際の Gleam プロジェクト構成と CI を薄く委譲できる段階で追加する。

Issue #1 で Gleam プロジェクトを作成し、Issue #10 で CI を整備した後、
`agent-assets/templates/` を基に `gleam format --check`、`gleam build
--warnings-as-errors`、`gleam test` と整合する構成を検討します。検証できない状態を
成功扱いする hook は追加しません。

codex stop review gate は、ワークスペース共通方針どおり無効のまま運用します。
