#!/usr/bin/env bash
# Claude Code Stop hook: ターン終了時に変更領域だけ format / build / test を検証する。
#
# .claude/README.md が「意図的に未導入」としていた条件（Gleam プロジェクトの
# bootstrap = Issue #1、CI 整備 = Issue #10）は両方 CLOSED になり、
# .github/workflows/ci.yml の gleam format --check / gleam build / gleam test /
# node --test と同じコマンドが既に settings.json で許可済みだったため、ここで追加する。
#
# CI と一致させるコマンド（.github/workflows/ci.yml）:
#   gleam format --check src test
#   gleam build --warnings-as-errors
#   gleam test
#   node --test 'test/client/*.test.mjs'（test/client 配下が変わったときのみ）

set -u

INPUT="$(cat || true)"

# hook 由来の再起動で無限ループしないようにする。jq が無い環境向けにフォールバックも残す。
if command -v jq >/dev/null 2>&1; then
  STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
else
  COMPACT_INPUT="$(printf '%s' "$INPUT" | tr -d ' \t\n\r')"
  case "$COMPACT_INPUT" in
    *'"stop_hook_active":true'*) STOP_HOOK_ACTIVE=true ;;
    *) STOP_HOOK_ACTIVE=false ;;
  esac
fi
[ "$STOP_HOOK_ACTIVE" = true ] && exit 0

if [ "${GLEAM_ROOM_SKIP_STOP_HOOK:-}" = 1 ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if ! cd "$PROJECT_DIR" 2>/dev/null; then
  {
    echo "Stop hook: PROJECT_DIR ($PROJECT_DIR) に cd できません。検証は実行されていません。"
    echo "  一時的に回避する場合のみ GLEAM_ROOM_SKIP_STOP_HOOK=1"
  } >&2
  exit 2
fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  {
    echo "Stop hook: $(pwd) は Git リポジトリではありません。変更ファイルを判定できません。"
    echo "  一時的に回避する場合のみ GLEAM_ROOM_SKIP_STOP_HOOK=1"
  } >&2
  exit 2
fi

# 未コミット・未追跡・未 push のコミットをすべて含める。
COMMITTED_DIFF=""
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  COMMITTED_DIFF="$(git diff --name-only '@{u}' -- 2>/dev/null || true)"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
  COMMITTED_DIFF="$(git diff --name-only origin/main...HEAD -- 2>/dev/null || true)"
fi
CHANGED_FILES="$(
  {
    printf '%s\n' "$COMMITTED_DIFF"
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u
)"
[ -z "$CHANGED_FILES" ] && exit 0

GLEAM_CHANGED=0
CLIENT_TEST_CHANGED=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    src/*.gleam|test/*.gleam|gleam.toml|manifest.toml) GLEAM_CHANGED=1 ;;
  esac
  case "$file" in
    # web.gleam embeds the client JS as a string (see test/client/extract.mjs),
    # so a web.gleam-only change can break it without touching *.test.mjs (#183).
    test/client/*.test.mjs|src/gleamroom/web.gleam) CLIENT_TEST_CHANGED=1 ;;
  esac
done <<EOF
$CHANGED_FILES
EOF
[ "$GLEAM_CHANGED" -eq 0 ] && [ "$CLIENT_TEST_CHANGED" -eq 0 ] && exit 0

FAILED=0
REPORT=""
append_report() { REPORT="${REPORT}$1"$'\n'; }
run_step() {
  local label="$1"
  shift
  local output rc=0
  echo "→ [stop-hook] $label" >&2
  output="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILED=1
    append_report ""
    append_report "FAIL: $label (rc=$rc)"
    append_report "Command: $*"
    append_report "$output"
  fi
}

if ! command -v gleam >/dev/null 2>&1; then
  {
    echo "Stop hook: gleam コマンドが見つかりません。検証は実行されていません。"
    echo "  一時的に回避する場合のみ GLEAM_ROOM_SKIP_STOP_HOOK=1"
  } >&2
  exit 2
fi

if [ "$GLEAM_CHANGED" -eq 1 ]; then
  run_step "format" gleam format --check src test
  run_step "build" gleam build --warnings-as-errors
  run_step "test" gleam test
fi

if [ "$CLIENT_TEST_CHANGED" -eq 1 ]; then
  if command -v node >/dev/null 2>&1; then
    run_step "client-test" node --test 'test/client/*.test.mjs'
  else
    FAILED=1
    append_report ""
    append_report "FAIL: client-test (node が見つかりません)"
  fi
fi

if [ "$FAILED" -eq 1 ]; then
  {
    echo "Stop hook: 検証に失敗しました。報告された問題を直してから完了してください。"
    echo "  一時的に回避する場合のみ: GLEAM_ROOM_SKIP_STOP_HOOK=1"
    echo "$REPORT"
  } >&2
  exit 2
fi

exit 0
