#!/usr/bin/env bash
# Claude Code Stop hook: 関連ファイルが変わったターンだけ `just check` を実行する。
#
# .claude/README.md が「意図的に未導入」としていた条件（Gleam プロジェクトの
# bootstrap = Issue #1、CI 整備 = Issue #10）は両方 CLOSED になり、
# .github/workflows/ci.yml の gleam format --check / gleam build / gleam test /
# node --test と同じコマンドが既に settings.json で許可済みだったため、ここで追加する。
#
# `just check`（justfile）が .github/workflows/ci.yml と同じ手順を直列実行する。
# 以前はここで GLEAM_CHANGED / CLIENT_TEST_CHANGED を別々に判定し、変更領域だけ
# 実行していたが、変更を検知するトリガー用 case パターンにファイルを追加し忘れる
# たびに検知漏れバグを作っていた（#305, #466）。`just check` に一本化し、
# トリガーが立ったら常に全チェックを回すことで、この種のバグの発生源を消す（#356）。

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

CHECK_TRIGGERED=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    # web.gleam/web_poker.gleam embed the client JS as a string (see
    # test/client/extract.mjs), so a web.gleam/web_poker.gleam-only change can
    # break it without touching *.test.mjs (#183, #305/#466).
    # harness.mjs/extract.mjs are the shared test harness the *.test.mjs files
    # import, so changing either without touching a *.test.mjs file can also
    # change what the tests actually verify (#186).
    src/*.gleam|test/*.gleam|gleam.toml|manifest.toml|test/client/*.test.mjs|test/client/harness.mjs|test/client/extract.mjs)
      CHECK_TRIGGERED=1 ;;
  esac
done <<EOF
$CHANGED_FILES
EOF
[ "$CHECK_TRIGGERED" -eq 0 ] && exit 0

if ! command -v just >/dev/null 2>&1; then
  {
    echo "Stop hook: just コマンドが見つかりません。検証は実行されていません。"
    echo "  一時的に回避する場合のみ GLEAM_ROOM_SKIP_STOP_HOOK=1"
  } >&2
  exit 2
fi

echo "→ [stop-hook] just check" >&2
OUTPUT="$(just check 2>&1)" || {
  {
    echo "Stop hook: 検証に失敗しました（just check）。報告された問題を直してから完了してください。"
    echo "  一時的に回避する場合のみ: GLEAM_ROOM_SKIP_STOP_HOOK=1"
    echo ""
    echo "$OUTPUT"
  } >&2
  exit 2
}

exit 0
