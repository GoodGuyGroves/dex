#!/usr/bin/env bash
# A lifecycle phase whose Claude session never started (a declined
# folder-trust dialog exits 0) is reported as such and fails; one that started
# is reported as before. "Never started" means no transcript: none for the
# conversation SessionStart captured, or, with none captured, none under the
# session's name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-unstarted.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export ZDOTDIR="$HOME"
export DEX_DIR="$ROOT"
export DEX_HOME="$TMP_DIR/dex-home"
export CLAUDE_CONFIG_DIR="$TMP_DIR/claude"
export CODEX_HOME="$TMP_DIR/codex"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export DEX_FACTORY_SYNC=false
unset DEX_SESSION_TITLE DEX_SESSION_ID DEX_LOOP_ACTIVE DEX_LOOP_PHASE
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT" "$TMP_DIR/bin" \
  "$CLAUDE_CONFIG_DIR/projects"

# The launcher checks for Claude before calling the stubbed provider.
printf '#!/usr/bin/env bash\nexit 97\n' > "$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

TEST_REPO="$TMP_DIR/repo"
git init -q -b main "$TEST_REPO"
git -C "$TEST_REPO" config user.email test@example.com
git -C "$TEST_REPO" config user.name Test
git -C "$TEST_REPO" commit --allow-empty -qm init
TEST_REPO=$(cd "$TEST_REPO" && pwd -P)
cd "$TEST_REPO"
PROJECT_DIR="$CLAUDE_CONFIG_DIR/projects/$(printf '%s\n' "$TEST_REPO" | sed 's/[^A-Za-z0-9]/-/g')"

# run_lifecycle <session-id> <record> <provider-exit> <behaviour>
# behaviour: none (no session), captured (SessionStart ran and Claude wrote the
# transcript), titled (a transcript under the session name, nothing captured).
run_lifecycle() {
  local session_id="$1" record="$2" provider_exit="$3" behaviour="$4" rc=0
  TEST_SESSION_ID="$session_id" TEST_REPO="$TEST_REPO" TEST_EXIT="$provider_exit" \
    TEST_BEHAVIOUR="$behaviour" TEST_PROJECT_DIR="$PROJECT_DIR" \
    DX_AGENT_OVERRIDE=claude zsh -fc '
      source "$DEX_DIR/dx.sh"
      __dx_refresh_provider
      unalias __dx_claude 2>/dev/null
      unfunction __dx_claude 2>/dev/null
      __dx_claude() {
        local conversation="conversation-$TEST_SESSION_ID"
        case "$TEST_BEHAVIOUR" in
          captured)
            dx_agent_session_handle_write "$TEST_SESSION_ID" claude "$conversation"
            mkdir -p "$TEST_PROJECT_DIR"
            printf "%s\n" "{\"type\":\"user\"}" > "$TEST_PROJECT_DIR/$conversation.jsonl"
            ;;
          titled)
            mkdir -p "$TEST_PROJECT_DIR"
            printf "%s\n" "{\"type\":\"custom-title\",\"customTitle\":\"ticket-17\"}" \
              > "$TEST_PROJECT_DIR/titled-$TEST_SESSION_ID.jsonl"
            ;;
        esac
        return "$TEST_EXIT"
      }
      __dx_run_phases_inline ticket-17 "$TEST_REPO" main 0 \
        "$(dx_state_file "$TEST_SESSION_ID")" "$(dx_times_file "$TEST_SESSION_ID")" \
        "dx 17" worktree "$TEST_SESSION_ID" "17"
    ' > "$record.out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$record.rc"
  rm -f "$PROJECT_DIR"/titled-*.jsonl
}

HINT="Claude exited before the session started"

# Declined before the session started: Claude exits 0 and leaves nothing.
run_lifecycle unstarted-zero "$TMP_DIR/zero" 0 none
[[ "$(cat "$TMP_DIR/zero.rc")" -ne 0 ]] || { cat "$TMP_DIR/zero.out" >&2; fail "unstarted session reported success"; }
assert_contains "$HINT" "$TMP_DIR/zero.out"
assert_contains "once in $TEST_REPO to trust it" "$TMP_DIR/zero.out"
# The run log says so too, for whoever reads the run rather than the terminal.
grep -rqs "Claude exited before the session started" "$DX_RUN_ROOT" \
  || fail "the run log does not record the session that never started"

# A non-zero exit before the session started keeps its code and gets the hint.
run_lifecycle unstarted-failed "$TMP_DIR/failed" 3 none
assert_eq 3 "$(cat "$TMP_DIR/failed.rc")" "provider exit code kept"
assert_contains "$HINT" "$TMP_DIR/failed.out"

# A session that started: its captured conversation has a transcript.
run_lifecycle started-captured "$TMP_DIR/captured" 0 captured
[[ "$(cat "$TMP_DIR/captured.rc")" -ne 0 ]] || fail "an early exit still pauses the lifecycle"
assert_not_contains "$HINT" "$TMP_DIR/captured.out"

# Nothing captured, but a transcript carries the session's name: started.
run_lifecycle started-titled "$TMP_DIR/titled" 0 titled
assert_not_contains "$HINT" "$TMP_DIR/titled.out"

# With no Claude store to read, Dex cannot tell and says nothing new.
rm -rf "$CLAUDE_CONFIG_DIR"
run_lifecycle unknown "$TMP_DIR/unknown" 0 none
assert_not_contains "$HINT" "$TMP_DIR/unknown.out"

printf '%s\n' "lifecycle unstarted tests passed"
