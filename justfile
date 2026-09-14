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

# .github/workflows/ci.yml と同じ手順を直列実行する（#356）。
# Stop hook（.claude/hooks/post-stop-check.sh）もこれを呼ぶ。
check:
    gleam format --check src test
    gleam build --warnings-as-errors
    gleam test
    node --test 'test/client/*.test.mjs'
    shellcheck .claude/hooks/post-stop-check.sh
