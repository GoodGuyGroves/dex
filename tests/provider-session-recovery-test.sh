#!/usr/bin/env bash
# Missing conversations retry once; other provider exits retain their status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-provider-session-recovery.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/home" "$TMP_DIR/work"

# Claude's transcripts: projects/<launch dir, each non-alphanumeric character as
# '-'>/<id>.jsonl. The lookup cases below resume conversations Claude has, so
# their recovery runs on the diagnostic; the precheck cases use an empty store.
WORK_DIR=$(cd "$TMP_DIR/work" && pwd -P)
encode_dir() { printf '%s\n' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
CLAUDE_STORE="$TMP_DIR/claude-config"
EMPTY_STORE="$TMP_DIR/claude-empty"
mkdir -p "$CLAUDE_STORE/projects/$(encode_dir "$WORK_DIR")" "$EMPTY_STORE/projects"
printf '%s\n' '{"type":"user","sessionId":"saved-conversation"}' \
  > "$CLAUDE_STORE/projects/$(encode_dir "$WORK_DIR")/saved-conversation.jsonl"
printf '%s\n' '{"type":"user"}' '{"type":"custom-title","customTitle":"ticket-3119","sessionId":"legacy-uuid"}' \
  > "$CLAUDE_STORE/projects/$(encode_dir "$WORK_DIR")/legacy-uuid.jsonl"

cat > "$TMP_DIR/scenario.sh" <<'SH'
set -eu
source "$DEX_DIR/lib/common.sh"
__dx_claude() {
  local invocation=1
  [[ ! -f "$TEST_RECORD.count" ]] || invocation=$(($(cat "$TEST_RECORD.count") + 1))
  printf '%s\n' "$invocation" > "$TEST_RECORD.count"
  printf '%s\n' "$@" > "$TEST_RECORD.args.$invocation"
  printf '%s\n' "$DEX_SESSION_ID" "$DEX_LOOP_PHASE" "$PWD" > "$TEST_RECORD.context.$invocation"
  printf 'provider stdout %s\n' "$invocation"
  if [[ "$invocation" -eq 1 ]]; then
    # Include terminal colour and an unterminated final line.
    printf '\033[31m%s\033[0m' "$TEST_DIAGNOSTIC" >&2
    return "$TEST_FIRST_EXIT"
  fi
  printf '%s\n' "$TEST_DIAGNOSTIC" >&2
  return "$TEST_SECOND_EXIT"
}
dx_provider_run_session "ticket-3119" "$TEST_RESUMING" "$TEST_HANDLE" \
  --model "test-model" --append-system-prompt-file "phase-context.md" \
  "Continue the saved phase."
SH

run_case() {
  local case_name="$1" engine="$2" resuming="$3" handle="$4"
  local first_exit="$5" diagnostic="$6" second_exit="${7:-0}"
  CASE_RECORD="$TMP_DIR/${TEST_SHELL}-${case_name}"
  CASE_RESULT=0
  cd "$WORK_DIR"
  env HOME="$TMP_DIR/home" ZDOTDIR="$TMP_DIR/home" DEX_DIR="$ROOT" TMPDIR="$TMP_DIR" \
    CLAUDE_CONFIG_DIR="${CASE_STORE:-$CLAUDE_STORE}" \
    DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" \
    DEX_SESSION_ID=recovery-test DEX_LOOP_PHASE=1 DX_PROVIDER_ENGINE="$engine" \
    TEST_RECORD="$CASE_RECORD" TEST_RESUMING="$resuming" TEST_HANDLE="$handle" \
    TEST_FIRST_EXIT="$first_exit" TEST_SECOND_EXIT="$second_exit" \
    TEST_DIAGNOSTIC="$diagnostic" \
    "$TEST_SHELL" "$TMP_DIR/scenario.sh" > "$CASE_RECORD.out" 2> "$CASE_RECORD.err" \
    || CASE_RESULT=$?
  cd "$ROOT"
  if compgen -G "$TMP_DIR/dx-provider-resume.*" >/dev/null; then
    cat "$CASE_RECORD.err" >&2
    fail "provider recovery left temporary state behind ($TEST_SHELL/$case_name)"
  fi
}

CLAUDE_DIAGNOSTIC="No conversation found with session ID: saved-conversation"
CODEX_DIAGNOSTIC='No saved session found with ID saved-conversation. Run `codex resume` without an ID to choose from existing sessions.'
for TEST_SHELL in bash zsh; do
  for engine in claude anthropic-gateway ccr codex-plugin; do
    diagnostic="$CLAUDE_DIAGNOSTIC"
    [[ "$engine" != codex-plugin ]] || diagnostic="$CODEX_DIAGNOSTIC"
    run_case "missing-$engine" "$engine" 1 saved-conversation 1 "$diagnostic"
    assert_eq 0 "$CASE_RESULT" "fresh launch result ($TEST_SHELL/$engine)"
    assert_eq 2 "$(cat "$CASE_RECORD.count")" "one retry ($TEST_SHELL/$engine)"
    assert_contains --resume "$CASE_RECORD.args.1"
    assert_contains saved-conversation "$CASE_RECORD.args.1"
    assert_not_contains --resume "$CASE_RECORD.args.2"
    assert_not_contains --continue "$CASE_RECORD.args.2"
    assert_not_contains saved-conversation "$CASE_RECORD.args.2"
    assert_contains ticket-3119 "$CASE_RECORD.args.2"
    assert_contains test-model "$CASE_RECORD.args.2"
    assert_contains phase-context.md "$CASE_RECORD.args.2"
    assert_contains "Continue the saved phase." "$CASE_RECORD.args.2"
    cmp "$CASE_RECORD.context.1" "$CASE_RECORD.context.2"
    assert_contains "provider stdout 1" "$CASE_RECORD.out"
    assert_contains "provider stdout 2" "$CASE_RECORD.out"
    assert_contains "$diagnostic" "$CASE_RECORD.err"
    assert_not_contains "provider stdout" "$CASE_RECORD.err"
    assert_contains "starting a new conversation at the current Dex phase" "$CASE_RECORD.err"
  done

  run_case legacy-claude claude 1 "" 1 "No conversation found with session ID: ticket-3119"
  assert_eq 0 "$CASE_RESULT" "legacy Claude recovery"
  assert_eq 2 "$(cat "$CASE_RECORD.count")" "legacy Claude retry"

  run_case legacy-codex codex-plugin 1 "" 0 ""
  assert_eq 0 "$CASE_RESULT" "legacy Codex success"
  assert_eq 1 "$(cat "$CASE_RECORD.count")" "legacy Codex not retried"
  assert_contains --continue "$CASE_RECORD.args.1"

  for first_exit in 0 2 130 143; do
    run_case "exit-$first_exit" claude 1 saved-conversation "$first_exit" "$CLAUDE_DIAGNOSTIC"
    assert_eq "$first_exit" "$CASE_RESULT" "provider exit preserved"
    assert_eq 1 "$(cat "$CASE_RECORD.count")" "non-lookup exit not retried"
  done
  for diagnostic in "Authentication failed" "No conversation found with session ID: unrelated-conversation"; do
    run_case unrelated-error claude 1 saved-conversation 1 "$diagnostic"
    assert_eq 1 "$CASE_RESULT" "unrelated error preserved"
    assert_eq 1 "$(cat "$CASE_RECORD.count")" "unrelated error not retried"
    rm "$CASE_RECORD.count"
  done

  run_case fresh-failure claude 0 "" 1 "$CLAUDE_DIAGNOSTIC"
  assert_eq 1 "$CASE_RESULT" "new launch error preserved"
  assert_eq 1 "$(cat "$CASE_RECORD.count")" "new launch not retried"

  run_case retry-failure claude 1 saved-conversation 1 "$CLAUDE_DIAGNOSTIC" 1
  assert_eq 1 "$CASE_RESULT" "retry error preserved"
  assert_eq 2 "$(cat "$CASE_RECORD.count")" "retry limited to one attempt"

  # No transcript, as after a launch that never started: no --resume at all,
  # since newer Claude answers one with an interactive picker, not a message.
  for engine in claude anthropic-gateway ccr; do
    CASE_STORE="$EMPTY_STORE" run_case "precheck-$engine" "$engine" 1 saved-conversation 0 ""
    assert_eq 0 "$CASE_RESULT" "precheck fresh launch ($TEST_SHELL/$engine)"
    assert_eq 1 "$(cat "$CASE_RECORD.count")" "precheck single launch ($TEST_SHELL/$engine)"
    assert_not_contains --resume "$CASE_RECORD.args.1"
    assert_contains ticket-3119 "$CASE_RECORD.args.1"
    assert_contains "Continue the saved phase." "$CASE_RECORD.args.1"
    assert_contains "starting a new conversation at the current Dex phase" "$CASE_RECORD.err"
  done
  CASE_STORE="$EMPTY_STORE" run_case precheck-legacy claude 1 "" 0 ""
  assert_eq 1 "$(cat "$CASE_RECORD.count")" "legacy name with no transcript"
  assert_not_contains --resume "$CASE_RECORD.args.1"
  # Codex keeps its own lookup.
  CASE_STORE="$EMPTY_STORE" run_case precheck-codex codex-plugin 1 saved-conversation 1 "$CODEX_DIAGNOSTIC"
  assert_contains --resume "$CASE_RECORD.args.1"
  assert_eq 2 "$(cat "$CASE_RECORD.count")" "codex lookup unchanged"
  # A transcript Claude has is resumed by its exact ID, and a legacy name by
  # its custom-title record.
  run_case precheck-found claude 1 saved-conversation 0 ""
  assert_eq 1 "$(cat "$CASE_RECORD.count")" "existing transcript resumed once"
  assert_contains --resume "$CASE_RECORD.args.1"
  assert_contains saved-conversation "$CASE_RECORD.args.1"
  run_case precheck-legacy-found claude 1 "" 0 ""
  assert_contains --resume "$CASE_RECORD.args.1"
  assert_contains ticket-3119 "$CASE_RECORD.args.1"
done

# dx_provider_claude_transcript_exists: 0 found, 1 missing, 2 unknown.
mkdir -p "$TMP_DIR/links"
ln -s "$WORK_DIR" "$TMP_DIR/links/work"
other_dir=$(mkdir -p "$TMP_DIR/other" && cd "$TMP_DIR/other" && pwd -P)
# Claude shortens a project name past 200 characters and appends a hash.
long_dir="$WORK_DIR/$(printf 'deep%.0s' {1..60})"
long_store="$TMP_DIR/claude-long"
long_project="$long_store/projects/$(encode_dir "$long_dir" | cut -c1-200)-1a2b3c"
mkdir -p "$long_project"
: > "$long_project/long-conversation.jsonl"
# A torn line is skipped, not fatal.
printf '%s\n' '{"type":"custom-title","customTitle":"broken' \
  > "$CLAUDE_STORE/projects/$(encode_dir "$WORK_DIR")/torn.jsonl"
mkdir -p "$TMP_DIR/no-projects-yet"
for TEST_SHELL in bash zsh; do
  lookup() { # <expected> <store> <launch-dir> <id> [name]
    local expected="$1" result=0
    env DEX_DIR="$ROOT" HOME="$TMP_DIR/home" CLAUDE_CONFIG_DIR="$2" \
      "$TEST_SHELL" -c 'source "$DEX_DIR/lib/common.sh"
        dx_provider_claude_transcript_exists "$@"' lookup "$3" "$4" "${5:-}" || result=$?
    assert_eq "$expected" "$result" "transcript lookup ($TEST_SHELL: ${4:-name ${5:-}} in $3)"
  }
  lookup 0 "$CLAUDE_STORE" "$WORK_DIR" saved-conversation
  lookup 0 "$CLAUDE_STORE" "$TMP_DIR/links/work" saved-conversation  # physical dir
  lookup 1 "$CLAUDE_STORE" "$WORK_DIR" other-conversation
  lookup 1 "$CLAUDE_STORE" "$other_dir" saved-conversation           # another project
  lookup 1 "$EMPTY_STORE" "$WORK_DIR" saved-conversation
  lookup 0 "$CLAUDE_STORE" "$WORK_DIR" "" ticket-3119
  lookup 1 "$CLAUDE_STORE" "$WORK_DIR" "" ticket-9999
  lookup 0 "$long_store" "$long_dir" long-conversation               # shortened project dir
  lookup 1 "$long_store" "$long_dir" other-conversation
  lookup 1 "$long_store" "$WORK_DIR" long-conversation
  lookup 1 "$TMP_DIR/no-projects-yet" "$WORK_DIR" saved-conversation   # Claude never ran
  lookup 2 "$TMP_DIR/no-such-config" "$WORK_DIR" saved-conversation
  lookup 2 "$CLAUDE_STORE" "$WORK_DIR" "../escape"
  lookup 2 "$CLAUDE_STORE" "$WORK_DIR" ""
  lookup 2 "$CLAUDE_STORE" "" saved-conversation
done

python3 - "$ROOT" "$TMP_DIR" <<'PY'
import os
import pty
import subprocess
import sys

root, temporary = sys.argv[1:]
script = r'''
source "$DEX_DIR/lib/common.sh"
__dx_claude() {
  [[ -t 0 && -t 1 ]] || return 90
  if [[ "$1" == --resume ]]; then
    printf '%s\n' 'No conversation found with session ID: saved-conversation' >&2
    return 1
  fi
  return 0
}
dx_provider_run_session ticket-3119 1 saved-conversation prompt
'''
for shell in ("bash", "zsh"):
    master, slave = pty.openpty()
    try:
        result = subprocess.run(
            [shell, "-c", script], stdin=slave, stdout=slave,
            stderr=subprocess.PIPE, timeout=15,
            env={**os.environ, "DEX_DIR": root, "TMPDIR": temporary,
                 "HOME": temporary + "/home", "ZDOTDIR": temporary + "/home",
                 "DX_PROVIDER_ENGINE": "claude"},
        )
        assert result.returncode == 0, (shell, result.returncode, result.stderr)
        assert b"starting a new conversation" in result.stderr, (shell, result.stderr)
    finally:
        os.close(master)
        os.close(slave)
PY

if compgen -G "$TMP_DIR/dx-provider-resume.*" >/dev/null; then
  fail "provider recovery left temporary state behind"
fi
printf '%s\n' "provider session recovery tests passed"
