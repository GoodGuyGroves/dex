#!/usr/bin/env bash
# dex-test-lane: fast
# A lifecycle whose Phase 7 terminal proof is committed is complete however the
# provider then exits. An /exit that the session reap cut short returns 143;
# that must not record "interrupted" or skip teardown (#52). Without a valid
# proof, a nonzero exit is still an interruption.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-exit-complete.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" HOME="$TMP_DIR/home" ZDOTDIR="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs" DEX_HOME="$TMP_DIR/dex-home"
export CLAUDE_CONFIG_DIR="$TMP_DIR/claude-config" CODEX_HOME="$TMP_DIR/home/.codex"
export DEXCODE_SYNC=0 DEX_FACTORY_SYNC=false DX_AGENT_OVERRIDE=claude DX_RTK_ENABLED=0
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT" "$DEX_HOME" \
  "$CLAUDE_CONFIG_DIR/projects" "$TMP_DIR/bin"
# The launcher checks for the provider executable before reaching the stub.
printf '#!/usr/bin/env bash\nexit 97\n' > "$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

if ! command -v zsh >/dev/null 2>&1; then
  printf 'skip: zsh is not installed, so dx.sh cannot be exercised\n'
  exit 0
fi

# run_case <name> <provider-exit> <proof:1|0> <worktree_teardown>
# Drives the real __dx_run_phases_inline at Phase 6. The stub provider plays
# the Phase 6 Stop hook's terminal transaction (state 7, live files removed,
# proof published under the control lock) when <proof> is 1, then exits.
run_case() {
  local name="$1" provider_exit="$2" proof="$3" teardown="$4"
  local repo="$TMP_DIR/$name/repo" wt_name="ticket-$name"
  CASE_WT="$repo/.dex/worktrees/$wt_name"
  CASE_OUT="$TMP_DIR/$name/out"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  mkdir -p "$repo/.dex"
  printf '# Project\n\n## Worktree Teardown\n\n```yaml\nworktree_teardown: %s\n```\n' \
    "$teardown" > "$repo/.dex/dex.md"
  printf '.dex/worktrees/\n' > "$repo/.gitignore"
  git -C "$repo" add .dex/dex.md .gitignore
  git -C "$repo" commit -qm init
  git -C "$repo" worktree add -q "$CASE_WT" -b "worktree-$wt_name" HEAD
  CASE_STATUS=0
  ( cd "$CASE_WT" && TEST_WT_NAME="$wt_name" TEST_WT="$CASE_WT" \
      TEST_EXIT="$provider_exit" TEST_PROOF="$proof" zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_refresh_provider
    session_id=$(dx_session_id "$TEST_WT_NAME")
    export TEST_SESSION_ID="$session_id"
    unalias __dx_claude 2>/dev/null
    unfunction __dx_claude 2>/dev/null
    __dx_claude() {
      local sid="$TEST_SESSION_ID"
      if [[ "$TEST_PROOF" == 1 ]]; then
        dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7 || return 90
        rm -f "$(dx_lifecycle_control_file "$sid")" "$(dx_paused_file "$sid")" \
          "$(dx_pause_state_file "$sid")" "$(dx_active_file "$sid")" \
          "$(dx_owner_file "$sid")" "$(dx_loop_config_file "$sid")" \
          "$(dx_handoff_mode_file "$sid")" "$(dx_completion_expectation_file "$sid")"
        dx_lifecycle_control_lock_acquire "$sid" || return 91
        dx_lifecycle_terminal_commit_publish_unlocked "$sid" \
          0123456789abcdef0123456789abcdef || return 92
        dx_lifecycle_control_lock_release "$sid" || return 93
      fi
      return "$TEST_EXIT"
    }
    state_file=$(dx_state_file "$session_id")
    times_file=$(dx_times_file "$session_id")
    dx_lifecycle_atomic_write "$state_file" 6
    __dx_run_phases_inline "$TEST_WT_NAME" "$TEST_WT" main 6 "$state_file" \
      "$times_file" "dx exit-test" worktree "$session_id" "exit test"
  ' ) > "$CASE_OUT" 2>&1 || CASE_STATUS=$?
}

events_with() { # <type> — run events of that type across every run
  cat "$DX_RUN_ROOT"/*/events.jsonl 2>/dev/null | grep -c "\"type\":\"$1\"" || true
}

for provider_exit in 143 130; do
  # on_complete: the worktree is removed even though the provider was cut short.
  run_case "complete-$provider_exit" "$provider_exit" 1 on_complete
  if [[ "$CASE_STATUS" -ne 0 ]]; then
    cat "$CASE_OUT" >&2
    fail "exit $provider_exit with a valid proof: dx returned $CASE_STATUS"
  fi
  assert_contains "Ticket lifecycle complete." "$CASE_OUT"
  assert_not_contains "Paused at Phase 7" "$CASE_OUT"
  [[ ! -d "$CASE_WT" ]] || fail "exit $provider_exit: on_complete kept the worktree"
  cat "$DX_RUN_ROOT"/*/logs.txt > "$TMP_DIR/logs" 2>/dev/null || true
  assert_contains "Provider exited with code ${provider_exit} after the lifecycle completed" \
    "$TMP_DIR/logs"
done
assert_eq 0 "$(events_with run.failed)" "no run.failed for a completed lifecycle"

# caller: completion is recorded and the worktree is kept for the caller.
run_case complete-caller 143 1 caller
[[ "$CASE_STATUS" -eq 0 ]] || { cat "$CASE_OUT" >&2; fail "caller teardown: dx returned $CASE_STATUS"; }
assert_contains "Ticket lifecycle complete." "$CASE_OUT"
assert_contains "worktree_teardown: caller" "$CASE_OUT"
[[ -d "$CASE_WT" ]] || fail "worktree_teardown: caller removed the worktree"

# No valid proof: a 143 is still an interruption, and nothing is torn down.
run_case no-proof 143 0 on_complete
[[ "$CASE_STATUS" -eq 143 ]] || { cat "$CASE_OUT" >&2; fail "no proof: dx returned $CASE_STATUS, want 143"; }
assert_contains "Paused at Phase 6" "$CASE_OUT"
assert_not_contains "Ticket lifecycle complete." "$CASE_OUT"
[[ -d "$CASE_WT" ]] || fail "an interrupted lifecycle removed its worktree"
assert_eq 1 "$(events_with run.failed)" "the interrupted run records run.failed"

printf 'lifecycle exit complete tests passed\n'
