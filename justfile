# keroway 標準 justfile（Gleam リポジトリ向け: gleam コマンドへの薄い委譲のみ）

default:
    @just --list

build:
    gleam build

test:
    gleam test
    node --test 'test/client/*.test.mjs'

format:
    gleam format src test

# .github/workflows/ci.yml と同じ手順を直列実行する（#356）。typos は
# ci.yml ではなく .github/workflows/workflow-lint.yml（共有 reusable
# workflow 経由）で実行されているが、CIが実際に強制しているチェックと
# ローカル・Stop hook を一致させるためここにも含める（#548）。
# Stop hook（.claude/hooks/post-stop-check.sh）もこれを呼ぶ。
check:
    gleam format --check src test
    gleam build --warnings-as-errors
    gleam test
    node --test 'test/client/*.test.mjs'
    node scripts/check-duplication-inventory-refs.js
    shellcheck .claude/hooks/post-stop-check.sh
    typos
