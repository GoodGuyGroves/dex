#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
CONTROL="$ROOT/bin/control.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-control-cli.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit --allow-empty -qm init
cd "$REPO"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
export DEX_SESSION_ID
DEX_SESSION_ID=$(dx_session_id)

write_cleanup_marker() { # <sid>
  local marker_sid="$1"
  printf 'dex-cleanup-journal-v1\t%s\n{}\n' "$marker_sid" \
    > "$DX_LOOP_DIR/${marker_sid}.cleanup-journal"
  chmod 600 "$DX_LOOP_DIR/${marker_sid}.cleanup-journal"
}

# A standalone Claude/Codex provider can keep session-scoped soft policy even
# when no phase loop is active. Assurance waivers still require a lifecycle.
STANDALONE_SESSION="$(dx_session_repo_key)-standalone-policy"
env DEX_SESSION_ID="$STANDALONE_SESSION" bash "$CONTROL" override \
  sync.budget-minutes 90 --scope session --source agent \
  --reason "The repository inventory needs a longer sync pass" \
  > "$TMP_DIR/standalone-override.out"
assert_eq "90" \
  "$(dx_override_effective "$STANDALONE_SESSION" sync.budget-minutes 60 -)" \
  "standalone session override"
env DEX_SESSION_ID="$STANDALONE_SESSION" bash "$CONTROL" status \
  > "$TMP_DIR/standalone-status.out"
assert_contains "sync.budget-minutes" "$TMP_DIR/standalone-status.out"
env DEX_SESSION_ID="$STANDALONE_SESSION" bash "$CONTROL" clear-override \
  sync.budget-minutes --scope session --source agent \
  --reason "The sync pass completed" > "$TMP_DIR/standalone-clear.out"

# Direct control, pause, and cancel writers share the transition lock with
# cleanup and cannot publish new lifecycle state after its journal appears.
CLEANUP_BARRIER_SESSION="$(dx_session_repo_key)-cleanup-control-barrier"
printf '2\n' > "$(dx_state_file "$CLEANUP_BARRIER_SESSION")"
printf 'inline\n' > "$(dx_handoff_mode_file "$CLEANUP_BARRIER_SESSION")"
touch "$(dx_active_file "$CLEANUP_BARRIER_SESSION")"
write_cleanup_marker "$CLEANUP_BARRIER_SESSION"
assert_rejected "$LINENO" \
  dx_write_lifecycle_control "$CLEANUP_BARRIER_SESSION" cancel "" terminal
assert_no_file "$(dx_lifecycle_control_file "$CLEANUP_BARRIER_SESSION")"
assert_rejected "$LINENO" \
  dx_lifecycle_pause "$CLEANUP_BARRIER_SESSION" cleanup-race lifecycle-control
assert_no_file "$(dx_paused_file "$CLEANUP_BARRIER_SESSION")"
assert_rejected "$LINENO" \
  dx_lifecycle_detach "$CLEANUP_BARRIER_SESSION" cleanup-race lifecycle-control
assert_file "$(dx_active_file "$CLEANUP_BARRIER_SESSION")"
assert_rejected "$LINENO" env DEX_SESSION_ID="$CLEANUP_BARRIER_SESSION" \
  bash "$CONTROL" pause > "$TMP_DIR/cleanup-barrier-pause.out" 2>&1
assert_rejected "$LINENO" env DEX_SESSION_ID="$CLEANUP_BARRIER_SESSION" \
  bash "$CONTROL" stop > "$TMP_DIR/cleanup-barrier-cancel.out" 2>&1
rm -f "$DX_LOOP_DIR/${CLEANUP_BARRIER_SESSION}.cleanup-journal" \
  "$(dx_state_file "$CLEANUP_BARRIER_SESSION")" \
  "$(dx_handoff_mode_file "$CLEANUP_BARRIER_SESSION")" \
  "$(dx_active_file "$CLEANUP_BARRIER_SESSION")"

printf '%s\n' 2 > "$(dx_state_file "$DEX_SESSION_ID")"
printf '%s\n' inline > "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
INITIAL_GENERATION=$(dx_completion_issue "$DEX_SESSION_ID" lifecycle phase 2)
printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$INITIAL_GENERATION" > "$(dx_loop_config_file "$DEX_SESSION_ID")"
touch "$(dx_active_file "$DEX_SESSION_ID")"
printf '%s\n' "claude-owner" > "$(dx_owner_file "$DEX_SESSION_ID")"

bash "$CONTROL" status > "$TMP_DIR/status.out"
grep -q "Phase: 2 (Implement)" "$TMP_DIR/status.out"

# The active agent can change an operational default without relaunching the
# provider. The status view surfaces attribution and justification.
bash "$CONTROL" override loop.max-iterations 45 --source agent \
  --reason "The migration audit needs more turns" > "$TMP_DIR/override.out"
assert_eq "45" \
  "$(dx_override_effective "$DEX_SESSION_ID" loop.max-iterations 30 2)" \
  "CLI override value"
bash "$CONTROL" status > "$TMP_DIR/status-with-override.out"
assert_contains "loop.max-iterations" "$TMP_DIR/status-with-override.out"
assert_contains "The migration audit needs more turns" \
  "$TMP_DIR/status-with-override.out"

assert_rejected "$LINENO" bash "$CONTROL" override loop.max-iterations 50 \
  --source agent > "$TMP_DIR/override-no-reason.out" 2>&1
assert_contains "--reason is required" "$TMP_DIR/override-no-reason.out"

bash "$CONTROL" clear-override loop.max-iterations --source agent \
  --reason "Return to the normal audit budget" > "$TMP_DIR/override-clear.out"
assert_eq "30" \
  "$(dx_override_effective "$DEX_SESSION_ID" loop.max-iterations 30 2)" \
  "cleared CLI override"

# pr.reviewers is session-scoped: the default scope becomes session, so it
# still holds in Phase 6, and an explicit phase scope is refused.
bash "$CONTROL" override pr.reviewers none --source agent \
  --reason "Fork PR: do not ping upstream reviewers" > "$TMP_DIR/reviewers-override.out"
assert_eq "none" "$(dx_override_effective "$DEX_SESSION_ID" pr.reviewers config 6)" \
  "pr.reviewers defaults to a session override"
assert_rejected "$LINENO" bash "$CONTROL" override pr.reviewers none --scope phase \
  --source agent --reason "Phase-scoped reviewer mode" > "$TMP_DIR/reviewers-phase.out" 2>&1
assert_contains "session-scoped" "$TMP_DIR/reviewers-phase.out"
bash "$CONTROL" clear-override pr.reviewers --source agent \
  --reason "Back to the reviewer table" > "$TMP_DIR/reviewers-clear.out"
assert_eq "config" "$(dx_override_effective "$DEX_SESSION_ID" pr.reviewers config 6)" \
  "cleared pr.reviewers session override"

WAIVER_SESSION="$(dx_session_repo_key)-agent-waiver"
printf '%s\n' 2 > "$(dx_state_file "$WAIVER_SESSION")"
printf '%s\n' inline > "$(dx_handoff_mode_file "$WAIVER_SESSION")"
WAIVER_COMPLETION=$(dx_completion_issue "$WAIVER_SESSION" lifecycle phase 2)
printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$WAIVER_COMPLETION" > "$(dx_loop_config_file "$WAIVER_SESSION")"
touch "$(dx_active_file "$WAIVER_SESSION")"
env DEX_SESSION_ID="$WAIVER_SESSION" bash "$CONTROL" waive \
  verification.required-gates --source agent \
  --reason "The platform-specific checker is unavailable in this environment" \
  > "$TMP_DIR/waiver.out"
assert_eq "agent" "$(dx_lifecycle_control_read "$WAIVER_SESSION" source)" \
  "agent waiver attribution"
assert_eq "enforce" \
  "$(dx_override_effective "$WAIVER_SESSION" verification.required-gates \
    enforce 2)" "named assurance waiver is not a live gate value"
grep -Fq $'waive\tverification.required-gates\twaived\tphase\t2\tagent\t0\tThe platform-specific checker is unavailable in this environment' \
  "$(dx_override_file "$WAIVER_SESSION")" || assert_at $LINENO
assert_contains "transition to Phase 3 is pending" "$TMP_DIR/waiver.out"
dx_cleanup_session "$WAIVER_SESSION"

# setup_attribution_lifecycle <sid> — an active inline lifecycle at Phase 2.
setup_attribution_lifecycle() {
  local attribution_sid="$1" attribution_completion
  printf '%s\n' 2 > "$(dx_state_file "$attribution_sid")"
  printf '%s\n' inline > "$(dx_handoff_mode_file "$attribution_sid")"
  attribution_completion=$(dx_completion_issue "$attribution_sid" lifecycle phase 2)
  printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
    "$ROOT" "$attribution_completion" > "$(dx_loop_config_file "$attribution_sid")"
  touch "$(dx_active_file "$attribution_sid")"
}

# assert_done_outcome <sid> <source> <reason> — apply the published done
# receipt as the lifecycle does and check the outcome ledger's attribution.
assert_done_outcome() {
  local outcome_sid="$1" expected_source="$2" expected_reason="$3"
  dx_record_control_phase_outcomes "$outcome_sid" 2 3 complete \
    "$(dx_lifecycle_control_read "$outcome_sid" generation)" \
    "$(dx_lifecycle_control_read "$outcome_sid" source)" || assert_at $LINENO
  assert_eq "waived $expected_source $expected_reason" \
    "$(awk -F '\t' '$2 == 2 { print $3, $4, $6 }' "$(dx_phase_outcomes_file "$outcome_sid")")" \
    "done outcome attribution"
}

# Inside a Dex launch the agent runs control.sh, so an unattributed control is
# the agent's, and an agent control needs a reason. A human is credited only
# with a quote of their words.
LAUNCH_SESSION="$(dx_session_repo_key)-launched-attribution"
setup_attribution_lifecycle "$LAUNCH_SESSION"
assert_rejected "$LINENO" env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" \
  bash "$CONTROL" "done" > "$TMP_DIR/launched-done-no-reason.out" 2>&1
assert_contains "recorded as --source agent" "$TMP_DIR/launched-done-no-reason.out"
assert_no_file "$(dx_lifecycle_control_file "$LAUNCH_SESSION")"
assert_rejected "$LINENO" env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" \
  bash "$CONTROL" waive verification.required-gates --source human \
  --reason "Baseline failures only" > "$TMP_DIR/launched-human-no-quote.out" 2>&1
assert_contains "--source human needs --quote" "$TMP_DIR/launched-human-no-quote.out"
assert_no_file "$(dx_lifecycle_control_file "$LAUNCH_SESSION")"
assert_no_file "$(dx_override_file "$LAUNCH_SESSION")"
assert_rejected "$LINENO" env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" \
  bash "$CONTROL" "done" --source agent --quote "skip it" \
  --reason "Baseline failures only" > "$TMP_DIR/launched-agent-quote.out" 2>&1
assert_contains "--quote records a human's words" "$TMP_DIR/launched-agent-quote.out"
assert_rejected "$LINENO" env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" \
  bash "$CONTROL" "done" --source human --quote "$(printf 'two\tparts')" \
  > "$TMP_DIR/launched-bad-quote.out" 2>&1
assert_contains "--quote must be" "$TMP_DIR/launched-bad-quote.out"
assert_no_file "$(dx_lifecycle_control_file "$LAUNCH_SESSION")"

env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" waive \
  verification.required-gates --reason "Only the dex#1 baseline fails" \
  > "$TMP_DIR/launched-waive.out"
assert_eq "agent" "$(dx_lifecycle_control_read "$LAUNCH_SESSION" source)" \
  "launched waive defaults to agent"
grep -Fq $'waive\tverification.required-gates\twaived\tphase\t2\tagent\t0\tOnly the dex#1 baseline fails' \
  "$(dx_override_file "$LAUNCH_SESSION")" || assert_at $LINENO
dx_cleanup_session "$LAUNCH_SESSION"

setup_attribution_lifecycle "$LAUNCH_SESSION"
env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" "done" \
  --reason "Phase 2 work is complete and pushed" > "$TMP_DIR/launched-done.out"
assert_eq "agent" "$(dx_lifecycle_control_read "$LAUNCH_SESSION" source)" \
  "launched done defaults to agent"
assert_contains "marked done by agent override" "$TMP_DIR/launched-done.out"
assert_done_outcome "$LAUNCH_SESSION" agent agent-complete
dx_cleanup_session "$LAUNCH_SESSION"

# A Codex lifecycle has no DEX_LAUNCHED, but its phase loop marks it the same.
setup_attribution_lifecycle "$LAUNCH_SESSION"
assert_rejected "$LINENO" env -u DEX_LAUNCHED DEX_LOOP_ACTIVE=1 \
  DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" "done" \
  > "$TMP_DIR/loop-done-no-reason.out" 2>&1
assert_contains "recorded as --source agent" "$TMP_DIR/loop-done-no-reason.out"
env -u DEX_LAUNCHED DEX_LOOP_ACTIVE=1 DEX_SESSION_ID="$LAUNCH_SESSION" \
  bash "$CONTROL" "done" --reason "Codex finished the phase" > "$TMP_DIR/loop-done.out"
assert_eq "agent" "$(dx_lifecycle_control_read "$LAUNCH_SESSION" source)" \
  "a phase-loop done defaults to agent"
dx_cleanup_session "$LAUNCH_SESSION"

QUOTE_RUN_ID="run_20261003T000000Z_1_q00ted00"
dx_run_write_for_session "$LAUNCH_SESSION" "$QUOTE_RUN_ID"
setup_attribution_lifecycle "$LAUNCH_SESSION"
env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" "done" \
  --source human --quote 'Skip verification, the "baseline" is known' \
  > "$TMP_DIR/launched-human-quote.out"
assert_eq "terminal" "$(dx_lifecycle_control_read "$LAUNCH_SESSION" source)" \
  "a quoted human control keeps the human receipt source"
python3 - "$(dx_run_events_file "$QUOTE_RUN_ID")" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
quoted = [event for event in events if event.get("type") == "control.quoted"]
assert len(quoted) == 1, events
data = quoted[0]["data"]
assert data["command"] == "done", data
assert data["source"] == "human", data
assert data["quote"] == 'Skip verification, the "baseline" is known', data
PY
grep -Fq 'dx control done source=human reason= quote=Skip verification, the "baseline" is known' \
  "$(dx_run_logs_file "$QUOTE_RUN_ID")" || assert_at $LINENO
dx_cleanup_session "$LAUNCH_SESSION"

# A quoted waiver's run-log line also names its gate and reason.
dx_run_write_for_session "$LAUNCH_SESSION" "$QUOTE_RUN_ID"
setup_attribution_lifecycle "$LAUNCH_SESSION"
env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" waive \
  verification.required-gates --source human --quote "Waive the gates, I checked them" \
  --reason "Human checked the baseline" > "$TMP_DIR/launched-human-waive.out"
grep -Fq 'dx control waive gate=verification.required-gates source=human reason=Human checked the baseline quote=Waive the gates, I checked them' \
  "$(dx_run_logs_file "$QUOTE_RUN_ID")" || assert_at $LINENO
dx_cleanup_session "$LAUNCH_SESSION"

# Resume follows the same rule inside a launch.
setup_attribution_lifecycle "$LAUNCH_SESSION"
env DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" pause > "$TMP_DIR/launched-pause.out"
assert_rejected "$LINENO" env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/launched-resume-no-reason.out" 2>&1
assert_contains "recorded as --source agent" "$TMP_DIR/launched-resume-no-reason.out"
env DEX_LAUNCHED=1 DEX_SESSION_ID="$LAUNCH_SESSION" bash "$CONTROL" resume \
  --reason "The blocking state was repaired" > "$TMP_DIR/launched-resume.out"
grep -Fq $'control.resume\trequested\tphase\t2\tagent' \
  "$(dx_override_file "$LAUNCH_SESSION")" || assert_at $LINENO
dx_cleanup_session "$LAUNCH_SESSION"

# Outside a launch the defaults are unchanged: a bare done is the human's.
OUTSIDE_SESSION="$(dx_session_repo_key)-terminal-attribution"
setup_attribution_lifecycle "$OUTSIDE_SESSION"
env -u DEX_LAUNCHED DEX_SESSION_ID="$OUTSIDE_SESSION" bash "$CONTROL" "done" \
  > "$TMP_DIR/terminal-done.out"
assert_eq "terminal" "$(dx_lifecycle_control_read "$OUTSIDE_SESSION" source)" \
  "terminal done defaults to human"
assert_contains "marked done by human override" "$TMP_DIR/terminal-done.out"
assert_done_outcome "$OUTSIDE_SESSION" terminal human-complete
dx_cleanup_session "$OUTSIDE_SESSION"
setup_attribution_lifecycle "$OUTSIDE_SESSION"
env -u DEX_LAUNCHED DEX_SESSION_ID="$OUTSIDE_SESSION" bash "$CONTROL" "done" \
  --source human > "$TMP_DIR/terminal-human-no-quote.out"
assert_eq "terminal" "$(dx_lifecycle_control_read "$OUTSIDE_SESSION" source)" \
  "a terminal human needs no quote"
dx_cleanup_session "$OUTSIDE_SESSION"

for unsafe_control_kind in symlink fifo directory wrong-mode; do
  case "$unsafe_control_kind" in
    symlink) ln -s /dev/null "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ;;
    fifo) mkfifo "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ;;
    directory) mkdir "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ;;
    wrong-mode)
      printf 'version=1\n' > "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
      chmod 0644 "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
      ;;
  esac
  assert_rejected "$LINENO" bash "$CONTROL" status \
    > "$TMP_DIR/unsafe-control-${unsafe_control_kind}.out" 2>&1
  assert_contains "unsafe or unreadable control receipt" \
    "$TMP_DIR/unsafe-control-${unsafe_control_kind}.out"
  if [[ -d "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]]; then
    rmdir "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
  else
    rm -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")"
  fi
done

set +e
bash "$CONTROL" pause unexpected > "$TMP_DIR/extra-arg.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "does not accept arguments" "$TMP_DIR/extra-arg.out"
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO

bash "$CONTROL" pause > "$TMP_DIR/pause.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "pause" ]] || assert_at $LINENO
[[ -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_owner_file "$DEX_SESSION_ID")")" == "claude-owner" ]] || assert_at $LINENO

# An unsafe activation target cannot turn resume into a false success. The
# pause/control remain retryable, while the fresh authorization is revoked.
mkdir "$(dx_active_file "$DEX_SESSION_ID")"
set +e
bash "$CONTROL" resume > "$TMP_DIR/resume-activation-failure.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
assert_contains "Could not create fresh completion authorization" \
  "$TMP_DIR/resume-activation-failure.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "resume" ]] || \
  assert_at $LINENO
assert_file "$(dx_paused_file "$DEX_SESSION_ID")"
assert_no_file "$(dx_completion_expectation_file "$DEX_SESSION_ID")"
assert_file "$(dx_loop_config_file "$DEX_SESSION_ID")"
assert_file "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
rmdir "$(dx_active_file "$DEX_SESSION_ID")"

bash "$CONTROL" resume --source agent \
  --reason "The transient state-file conflict has been removed" \
  > "$TMP_DIR/resume.out"
[[ ! -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ ! -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
RESUME_GENERATION=$(dx_completion_current_generation "$DEX_SESSION_ID" lifecycle phase 2)
[[ "$RESUME_GENERATION" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
[[ "$RESUME_GENERATION" != "$INITIAL_GENERATION" ]] || assert_at $LINENO
assert_eq "requested" \
  "$(dx_override_effective "$DEX_SESSION_ID" control.resume none 2)" \
  "agent resume attribution"
[[ "$(cut -d: -f5-7 "$(dx_loop_config_file "$DEX_SESSION_ID")")" == "lifecycle:phase:${RESUME_GENERATION}" ]] || assert_at $LINENO
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$DEX_SESSION_ID\" \"$RESUME_GENERATION\"" "$TMP_DIR/resume.out"

# A wrapper-processed pause keeps a durable pause marker even after its live
# receipt and activation files are gone. Terminal controls can resume or move
# that recorded phase without relaunching the old provider process first.
bash "$CONTROL" pause > "$TMP_DIR/durable-pause.out"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_owner_file "$DEX_SESSION_ID")" \
  "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
bash "$CONTROL" status > "$TMP_DIR/durable-status.out"
grep -q "Lifecycle: paused (manual-pause)" "$TMP_DIR/durable-status.out"
bash "$CONTROL" "done" > "$TMP_DIR/durable-done.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "complete" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_handoff_mode_file "$DEX_SESSION_ID")")" == "inline" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")"
dx_lifecycle_atomic_write "$(dx_paused_file "$DEX_SESSION_ID")" paused
bash "$CONTROL" resume > "$TMP_DIR/durable-resume.out"
[[ ! -f "$(dx_paused_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ -f "$(dx_active_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
[[ "$(cat "$(dx_handoff_mode_file "$DEX_SESSION_ID")")" == "inline" ]] || assert_at $LINENO
DURABLE_GENERATION=$(dx_completion_current_generation "$DEX_SESSION_ID" lifecycle phase 2)
[[ "$DURABLE_GENERATION" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
[[ "$DURABLE_GENERATION" != "$RESUME_GENERATION" ]] || assert_at $LINENO
grep -Fq "bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$DEX_SESSION_ID\" \"$DURABLE_GENERATION\"" "$TMP_DIR/durable-resume.out"

# A durable metadata record is independently sufficient to hold the pause.
# Status must surface it and resume must consume it under the transition lock.
bash "$CONTROL" pause > "$TMP_DIR/metadata-pause.out"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_paused_file "$DEX_SESSION_ID")"
bash "$CONTROL" status > "$TMP_DIR/metadata-status.out"
assert_contains "Lifecycle: paused (manual-pause)" "$TMP_DIR/metadata-status.out"
bash "$CONTROL" resume > "$TMP_DIR/metadata-resume.out"
assert_no_file "$(dx_paused_file "$DEX_SESSION_ID")"
assert_no_file "$(dx_pause_state_file "$DEX_SESSION_ID")"

# An unsafe metadata inode is an error, not an absent pause that automation may
# overwrite. Both the diagnostic and mutating surfaces stay closed.
printf 'reason=manual-pause\nsource=terminal\n' \
  > "$(dx_pause_state_file "$DEX_SESSION_ID")"
chmod 0644 "$(dx_pause_state_file "$DEX_SESSION_ID")"
assert_rejected "$LINENO" bash "$CONTROL" status \
  > "$TMP_DIR/unsafe-pause-status.out" 2>&1
assert_contains "unsafe or malformed pause state" \
  "$TMP_DIR/unsafe-pause-status.out"
assert_rejected "$LINENO" bash "$CONTROL" resume \
  > "$TMP_DIR/unsafe-pause-resume.out" 2>&1
assert_contains "unsafe or malformed pause state" \
  "$TMP_DIR/unsafe-pause-resume.out"
rm -f "$(dx_pause_state_file "$DEX_SESSION_ID")"

# If a review selection could not be invalidated, ordinary resume cannot
# clear the brake and silently reuse that selection.
SELECTION_BRAKE_SESSION="$(dx_session_repo_key)-selection-brake"
dx_lifecycle_atomic_write "$(dx_state_file "$SELECTION_BRAKE_SESSION")" 3
SELECTION_BRAKE_GENERATION=$(dx_completion_issue \
  "$SELECTION_BRAKE_SESSION" lifecycle phase 3)
printf '3:PHASE_3_COMPLETE:%s/prompts/phase-audits/3-review-loop.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$SELECTION_BRAKE_GENERATION" \
  > "$(dx_loop_config_file "$SELECTION_BRAKE_SESSION")"
dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$SELECTION_BRAKE_SESSION")" inline
dx_lifecycle_pause "$SELECTION_BRAKE_SESSION" \
  assessment-selection-revocation-failed review-loop
assert_rejected "$LINENO" env DEX_SESSION_ID="$SELECTION_BRAKE_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/selection-brake-resume.out" 2>&1
assert_file "$(dx_paused_file "$SELECTION_BRAKE_SESSION")"
assert_eq "assessment-selection-revocation-failed" \
  "$(dx_pause_state_read "$SELECTION_BRAKE_SESSION" reason)" \
  "selection revocation failure stays non-resumable"
assert_no_file "$(dx_completion_expectation_file "$SELECTION_BRAKE_SESSION")"
dx_lifecycle_atomic_write "$(dx_state_file "$SELECTION_BRAKE_SESSION")" 7
assert_rejected "$LINENO" env DEX_SESSION_ID="$SELECTION_BRAKE_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/selection-brake-phase7-resume.out" 2>&1
assert_eq "7" "$(dx_lifecycle_current_phase "$SELECTION_BRAKE_SESSION")" \
  "selection revocation failure cannot use terminal-failure rollback"
assert_file "$(dx_paused_file "$SELECTION_BRAKE_SESSION")"
assert_no_file "$(dx_lifecycle_terminal_commit_file "$SELECTION_BRAKE_SESSION")"
assert_no_file "$(dx_completion_expectation_file "$SELECTION_BRAKE_SESSION")"

bash "$CONTROL" "done" > "$TMP_DIR/done.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "complete" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" expected_phase)" == "2" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "3" ]] || assert_at $LINENO

dx_clear_lifecycle_control "$DEX_SESSION_ID"
bash "$CONTROL" jump verify > "$TMP_DIR/jump.out"
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" action)" == "jump" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_control_read "$DEX_SESSION_ID" target_phase)" == "4" ]] || assert_at $LINENO

# An irreparable coordination lock must not produce a false "pause accepted"
# result while the old completion expectation is still live.
dx_clear_lifecycle_control "$DEX_SESSION_ID"
touch "$(dx_active_file "$DEX_SESSION_ID")"
COMPLETION_LOCK=$(dx_completion_lock_file "$DEX_SESSION_ID")
rm -f "$COMPLETION_LOCK"
mkdir "$COMPLETION_LOCK"
set +e
bash "$CONTROL" pause > "$TMP_DIR/unsafe-lock-pause.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "could not prove that completion authorization was revoked" "$TMP_DIR/unsafe-lock-pause.out"
if grep -q "accepted for Phase" "$TMP_DIR/unsafe-lock-pause.out"; then
  printf 'unsafe completion lock produced a false pause success\n' >&2
  exit 1
fi
rmdir "$COMPLETION_LOCK"
dx_completion_abandon "$DEX_SESSION_ID"
dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_paused_file "$DEX_SESSION_ID")" "$(dx_pause_state_file "$DEX_SESSION_ID")"

# Numeric standalone phases must not be mistaken for lifecycle phases. Resume
# rotates their exact purpose without creating inline handoff state, while
# done/jump remain lifecycle-only controls.
STANDALONE_SESSION_ID="$(dx_session_repo_key)-standalone-control"
STANDALONE_CONFIG=$(dx_loop_config_file "$STANDALONE_SESSION_ID")
STANDALONE_GENERATION=$(dx_completion_issue \
  "$STANDALONE_SESSION_ID" standalone dxcomplete 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:%s\n' \
  "$ROOT" "$STANDALONE_GENERATION" > "$STANDALONE_CONFIG"
printf '7\n' > "$(dx_state_file "$STANDALONE_SESSION_ID")"
touch "$(dx_active_file "$STANDALONE_SESSION_ID")"
DEX_SESSION_ID="$STANDALONE_SESSION_ID" bash "$CONTROL" pause \
  > "$TMP_DIR/standalone-complete-pause.out"
assert_contains "pause accepted for Phase 6" \
  "$TMP_DIR/standalone-complete-pause.out"
assert_file "$(dx_paused_file "$STANDALONE_SESSION_ID")"
assert_no_file "$(dx_completion_expectation_file "$STANDALONE_SESSION_ID")"
DEX_SESSION_ID="$STANDALONE_SESSION_ID" bash "$CONTROL" resume \
  > "$TMP_DIR/standalone-complete-resume.out"
STANDALONE_RESUMED=$(dx_completion_current_generation \
  "$STANDALONE_SESSION_ID" standalone dxcomplete 6)
[[ "$STANDALONE_RESUMED" =~ ^[0-9a-f]{32}$ \
  && "$STANDALONE_RESUMED" != "$STANDALONE_GENERATION" ]] || assert_at $LINENO
assert_eq "standalone:dxcomplete:${STANDALONE_RESUMED}" \
  "$(cut -d: -f5-7 "$STANDALONE_CONFIG")" \
  "terminal preserves dxcomplete context"
assert_no_file "$(dx_handoff_mode_file "$STANDALONE_SESSION_ID")"
assert_rejected "$LINENO" env DEX_SESSION_ID="$STANDALONE_SESSION_ID" \
  bash "$CONTROL" "done" > "$TMP_DIR/standalone-done.out" 2>&1
assert_contains "only to an inline Dex lifecycle" "$TMP_DIR/standalone-done.out"

dx_completion_cleanup "$STANDALONE_SESSION_ID"
rm -f "$(dx_active_file "$STANDALONE_SESSION_ID")" "$STANDALONE_CONFIG" \
  "$(dx_state_file "$STANDALONE_SESSION_ID")"
STANDALONE_GENERATION=$(dx_completion_issue \
  "$STANDALONE_SESSION_ID" standalone dxloop-plan 1)
printf '1:PHASE_1_COMPLETE:%s/prompts/phase-audits/1-plan.md:1:standalone:dxloop-plan:%s\n' \
  "$ROOT" "$STANDALONE_GENERATION" > "$STANDALONE_CONFIG"
touch "$(dx_active_file "$STANDALONE_SESSION_ID")"
assert_rejected "$LINENO" env DEX_SESSION_ID="$STANDALONE_SESSION_ID" \
  bash "$CONTROL" jump verify > "$TMP_DIR/standalone-jump.out" 2>&1
assert_contains "only to an inline Dex lifecycle" "$TMP_DIR/standalone-jump.out"
assert_eq "standalone:dxloop-plan:${STANDALONE_GENERATION}" \
  "$(cut -d: -f5-7 "$STANDALONE_CONFIG")" \
  "terminal jump preserves dxloop plan context"
assert_no_file "$(dx_handoff_mode_file "$STANDALONE_SESSION_ID")"

dx_completion_cleanup "$STANDALONE_SESSION_ID"
rm -f "$(dx_active_file "$STANDALONE_SESSION_ID")"
STANDALONE_GENERATION=$(dx_completion_issue \
  "$STANDALONE_SESSION_ID" standalone dxloop-prompt prompt-loop)
printf 'prompt-loop:PROMPT_COMPLETE:%s/prompts/phase-audits/prompt-loop.md:1:standalone:dxloop-prompt:%s\n' \
  "$ROOT" "$STANDALONE_GENERATION" > "$STANDALONE_CONFIG"
dx_lifecycle_atomic_write "$(dx_paused_file "$STANDALONE_SESSION_ID")" paused
DEX_SESSION_ID="$STANDALONE_SESSION_ID" bash "$CONTROL" resume \
  > "$TMP_DIR/standalone-prompt-resume.out"
STANDALONE_RESUMED=$(dx_completion_current_generation \
  "$STANDALONE_SESSION_ID" standalone dxloop-prompt prompt-loop)
[[ "$STANDALONE_RESUMED" =~ ^[0-9a-f]{32}$ \
  && "$STANDALONE_RESUMED" != "$STANDALONE_GENERATION" ]] || assert_at $LINENO
assert_eq "standalone:dxloop-prompt:${STANDALONE_RESUMED}" \
  "$(cut -d: -f5-7 "$STANDALONE_CONFIG")" \
  "terminal preserves prompt-loop context"
assert_no_file "$(dx_handoff_mode_file "$STANDALONE_SESSION_ID")"
dx_completion_cleanup "$STANDALONE_SESSION_ID"
rm -f "$(dx_active_file "$STANDALONE_SESSION_ID")" "$STANDALONE_CONFIG"

RESUME_RELEASE_SESSION="$(dx_session_repo_key)-resume-release-failure"
RESUME_RELEASE_GENERATION=$(dx_completion_issue \
  "$RESUME_RELEASE_SESSION" standalone dxcomplete 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:%s\n' \
  "$ROOT" "$RESUME_RELEASE_GENERATION" \
  > "$(dx_loop_config_file "$RESUME_RELEASE_SESSION")"
dx_lifecycle_atomic_write "$(dx_paused_file "$RESUME_RELEASE_SESSION")" paused
set +e
(
  dx_lifecycle_control_lock_release() { return 1; }
  dx_lifecycle_resume_completion_context "$RESUME_RELEASE_SESSION" >/dev/null
)
RESUME_RELEASE_RC=$?
set -e
[[ "$RESUME_RELEASE_RC" -ne 0 ]] || assert_at $LINENO
assert_no_file "$(dx_completion_expectation_file "$RESUME_RELEASE_SESSION")"
assert_no_file "$(dx_active_file "$RESUME_RELEASE_SESSION")"
assert_file "$(dx_paused_file "$RESUME_RELEASE_SESSION")"
rm -f "$(dx_lifecycle_control_lock_dir "$RESUME_RELEASE_SESSION")/owner"
rmdir "$(dx_lifecycle_control_lock_dir "$RESUME_RELEASE_SESSION")"
rm -f "$(dx_paused_file "$RESUME_RELEASE_SESSION")" \
  "$(dx_pause_state_file "$RESUME_RELEASE_SESSION")" \
  "$(dx_loop_config_file "$RESUME_RELEASE_SESSION")"

# Resume cannot cross a live Phase 3 child fence. The pause remains intact and
# no generation is minted until the exact child token acknowledges quiescence;
# that acknowledgement is then retired in the same resume transaction.
BUSY_RESUME_SESSION="$(dx_session_repo_key)-busy-resume"
dx_lifecycle_atomic_write "$(dx_state_file "$BUSY_RESUME_SESSION")" 3
dx_lifecycle_control_lock_acquire "$BUSY_RESUME_SESSION"
BUSY_RESUME_GENERATION=$(dx_lifecycle_completion_issue_unlocked \
  "$BUSY_RESUME_SESSION" lifecycle phase 3)
dx_lifecycle_atomic_write "$(dx_loop_config_file "$BUSY_RESUME_SESSION")" \
  "$(dx_completion_context_config lifecycle phase 3 "$BUSY_RESUME_GENERATION")"
dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$BUSY_RESUME_SESSION")" inline
dx_lifecycle_atomic_write "$(dx_active_file "$BUSY_RESUME_SESSION")" active
dx_lifecycle_control_lock_release "$BUSY_RESUME_SESSION"
BUSY_RESUME_TOKEN=$(dx_phase_busy_begin "$BUSY_RESUME_SESSION" 3 review-pass)
dx_lifecycle_pause "$BUSY_RESUME_SESSION" manual-pause lifecycle-control
env DEX_SESSION_ID="$BUSY_RESUME_SESSION" bash "$CONTROL" status \
  > "$TMP_DIR/busy-recover-live-status.out"
assert_contains "Review fence: active" "$TMP_DIR/busy-recover-live-status.out"
assert_rejected "$LINENO" env DEX_SESSION_ID="$BUSY_RESUME_SESSION" \
  bash "$CONTROL" recover review --source agent \
  > "$TMP_DIR/busy-recover-no-reason.out" 2>&1
assert_contains "--reason is required" "$TMP_DIR/busy-recover-no-reason.out"
assert_rejected "$LINENO" env DEX_SESSION_ID="$BUSY_RESUME_SESSION" \
  bash "$CONTROL" recover review --source agent \
  --reason "The review command was interrupted" \
  > "$TMP_DIR/busy-recover-live.out" 2>&1
assert_contains "still alive" "$TMP_DIR/busy-recover-live.out"
assert_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_completion_expectation_file "$BUSY_RESUME_SESSION")"
assert_rejected "$LINENO" env DEX_SESSION_ID="$BUSY_RESUME_SESSION" \
  bash "$CONTROL" resume > "$TMP_DIR/busy-resume-rejected.out" 2>&1
assert_file "$(dx_paused_file "$BUSY_RESUME_SESSION")"
assert_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_completion_expectation_file "$BUSY_RESUME_SESSION")"
dx_phase_busy_acknowledge "$BUSY_RESUME_SESSION" 3 "$BUSY_RESUME_TOKEN"
DEX_SESSION_ID="$BUSY_RESUME_SESSION" bash "$CONTROL" resume \
  > "$TMP_DIR/busy-resume-accepted.out"
BUSY_RESUMED_GENERATION=$(dx_completion_current_generation \
  "$BUSY_RESUME_SESSION" lifecycle phase 3)
[[ "$BUSY_RESUMED_GENERATION" =~ ^[0-9a-f]{32}$ \
  && "$BUSY_RESUMED_GENERATION" != "$BUSY_RESUME_GENERATION" ]] || assert_at $LINENO
assert_no_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_cancel_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_quiesced_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_paused_file "$BUSY_RESUME_SESSION")"

# An interrupted review owner can leave its fence behind. Recovery is an
# attributed, fail-closed detach: it proves the recorded PID is dead, revokes
# completion, removes only the review fence, and leaves Phase 3 paused.
STALE_BUSY_EPOCH=$(date +%s)
STALE_BUSY_PID=99999999
while __dx_lock_pid_alive "$STALE_BUSY_PID"; do
  STALE_BUSY_PID=$((STALE_BUSY_PID + 1))
done
STALE_BUSY_TOKEN="${STALE_BUSY_EPOCH}-${STALE_BUSY_PID}-1"
dx_lifecycle_atomic_write "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)" \
  "${STALE_BUSY_EPOCH}"$'\t'"${STALE_BUSY_TOKEN}"$'\t'"${STALE_BUSY_PID}"$'\t'"interrupted review wave"
dx_lifecycle_atomic_write "$(dx_phase_busy_notice_file "$BUSY_RESUME_SESSION" 3)" \
  "${STALE_BUSY_EPOCH}"$'\t'"interrupted review wave"
env DEX_SESSION_ID="$BUSY_RESUME_SESSION" bash "$CONTROL" status \
  > "$TMP_DIR/busy-recover-dead-status.out"
assert_contains "Review fence: stale" "$TMP_DIR/busy-recover-dead-status.out"
assert_contains "dx control recover review --source agent" \
  "$TMP_DIR/busy-recover-dead-status.out"
env DEX_SESSION_ID="$BUSY_RESUME_SESSION" bash "$CONTROL" recover review \
  --source agent --reason "The review command was interrupted and its owner exited" \
  > "$TMP_DIR/busy-recover-dead.out"
assert_contains "remains paused" "$TMP_DIR/busy-recover-dead.out"
assert_contains "/dxresume" "$TMP_DIR/busy-recover-dead.out"
assert_contains "/dxskip" "$TMP_DIR/busy-recover-dead.out"
assert_no_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_notice_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_cancel_file "$BUSY_RESUME_SESSION" 3)"
assert_no_file "$(dx_phase_busy_quiesced_file "$BUSY_RESUME_SESSION" 3)"
assert_file "$(dx_paused_file "$BUSY_RESUME_SESSION")"
assert_eq "stale-review-fence-recovered" \
  "$(dx_pause_state_read "$BUSY_RESUME_SESSION" reason)" \
  "stale review recovery pause reason"
assert_no_file "$(dx_completion_expectation_file "$BUSY_RESUME_SESSION")"
assert_no_file "$(dx_active_file "$BUSY_RESUME_SESSION")"

dx_lifecycle_atomic_write "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)" \
  "malformed review fence"
assert_rejected "$LINENO" env DEX_SESSION_ID="$BUSY_RESUME_SESSION" \
  bash "$CONTROL" recover review --source agent \
  --reason "The interrupted review left malformed state" \
  > "$TMP_DIR/busy-recover-malformed.out" 2>&1
assert_contains "malformed" "$TMP_DIR/busy-recover-malformed.out"
assert_file "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"
rm -f "$(dx_phase_busy_file "$BUSY_RESUME_SESSION" 3)"

# If the Stop hook applies a terminal transition before the CLI can reactivate
# it, the activation helper reports the committed result without resurrecting
# the completed loop.
ACTIVATION_RACE_SESSION="$(dx_session_repo_key)-terminal-activation-race"
printf '6\n' > "$(dx_state_file "$ACTIVATION_RACE_SESSION")"
ACTIVATION_RACE_COMPLETION=$(dx_completion_issue \
  "$ACTIVATION_RACE_SESSION" lifecycle phase 6)
printf '6:DEX_TICKET_COMPLETE:%s/prompts/phase-audits/6-complete.md:1:lifecycle:phase:%s\n' \
  "$ROOT" "$ACTIVATION_RACE_COMPLETION" \
  > "$(dx_loop_config_file "$ACTIVATION_RACE_SESSION")"
printf 'inline\n' > "$(dx_handoff_mode_file "$ACTIVATION_RACE_SESSION")"
touch "$(dx_active_file "$ACTIVATION_RACE_SESSION")"
dx_write_lifecycle_control "$ACTIVATION_RACE_SESSION" complete 7 terminal "" 6 ""
ACTIVATION_RACE_CONTROL="$DX_LIFECYCLE_CONTROL_GENERATION"
dx_completion_abandon "$ACTIVATION_RACE_SESSION"
dx_lifecycle_atomic_write "$(dx_state_file "$ACTIVATION_RACE_SESSION")" 7
dx_clear_lifecycle_control "$ACTIVATION_RACE_SESSION"
rm -f "$(dx_active_file "$ACTIVATION_RACE_SESSION")" \
  "$(dx_handoff_mode_file "$ACTIVATION_RACE_SESSION")" \
  "$(dx_loop_config_file "$ACTIVATION_RACE_SESSION")"
dx_lifecycle_control_lock_acquire "$ACTIVATION_RACE_SESSION"
dx_lifecycle_terminal_commit_publish_unlocked "$ACTIVATION_RACE_SESSION" \
  "$ACTIVATION_RACE_CONTROL"
dx_lifecycle_control_lock_release "$ACTIVATION_RACE_SESSION"
assert_eq "applied" \
  "$(dx_lifecycle_activate_pending_control "$ACTIVATION_RACE_SESSION" \
    complete 7 6 "$ACTIVATION_RACE_CONTROL")" \
  "already-applied terminal transition"
assert_no_file "$(dx_active_file "$ACTIVATION_RACE_SESSION")"
assert_no_file "$(dx_handoff_mode_file "$ACTIVATION_RACE_SESSION")"

# A terminal lifecycle cannot be complete while any Phase 3 child fence or
# sidecar remains, even when that path is an unsafe inode.
for terminal_busy_path in \
  "$(dx_phase_busy_file "$ACTIVATION_RACE_SESSION" 3)" \
  "$(dx_phase_busy_cancel_file "$ACTIVATION_RACE_SESSION" 3)" \
  "$(dx_phase_busy_quiesced_file "$ACTIVATION_RACE_SESSION" 3)"; do
  mkdir "$terminal_busy_path"
  if dx_lifecycle_terminal_commit_valid "$ACTIVATION_RACE_SESSION"; then
    printf 'terminal proof accepted Phase 3 child-fence residue: %s\n' \
      "$terminal_busy_path" >&2
    exit 1
  fi
  rmdir "$terminal_busy_path"
done
dx_lifecycle_terminal_commit_valid "$ACTIVATION_RACE_SESSION" || assert_at $LINENO

# A crash after Phase 7 publication but before its proof is recoverable only
# from Dex's trusted terminal-failure pause. Resume rolls back to Phase 6 and
# creates a fresh, exact authorization instead of accepting the partial 7.
TERMINAL_REPAIR_SESSION="$(dx_session_repo_key)-terminal-repair"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPAIR_SESSION")" 7
dx_write_pause_state "$TERMINAL_REPAIR_SESSION" terminal-proof-missing phase-loop
dx_lifecycle_atomic_write "$(dx_paused_file "$TERMINAL_REPAIR_SESSION")" paused
DEX_SESSION_ID="$TERMINAL_REPAIR_SESSION" bash "$CONTROL" resume \
  > "$TMP_DIR/terminal-repair.out"
assert_eq "6" "$(dx_lifecycle_phase_state "$TERMINAL_REPAIR_SESSION")" \
  "terminal repair returns to Phase 6"
TERMINAL_REPAIR_GENERATION=$(dx_completion_current_generation \
  "$TERMINAL_REPAIR_SESSION" lifecycle phase 6)
[[ "$TERMINAL_REPAIR_GENERATION" =~ ^[0-9a-f]{32}$ ]] || assert_at $LINENO
assert_no_file "$(dx_lifecycle_terminal_commit_file "$TERMINAL_REPAIR_SESSION")"
assert_no_file "$(dx_paused_file "$TERMINAL_REPAIR_SESSION")"
assert_contains "resumed at Phase 6" "$TMP_DIR/terminal-repair.out"

# A fresh lifecycle generation always erases an older terminal proof. Returning
# to Phase 7 without a new proof must therefore remain incomplete.
TERMINAL_REPLAY_SESSION="$(dx_session_repo_key)-terminal-replay"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPLAY_SESSION")" 7
dx_lifecycle_control_lock_acquire "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_terminal_commit_publish_unlocked "$TERMINAL_REPLAY_SESSION" \
  0123456789abcdef0123456789abcdef
dx_lifecycle_control_lock_release "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_terminal_commit_valid "$TERMINAL_REPLAY_SESSION" || assert_at $LINENO
dx_lifecycle_control_lock_acquire "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPLAY_SESSION")" 4
dx_lifecycle_completion_issue_unlocked \
  "$TERMINAL_REPLAY_SESSION" lifecycle phase 4 >/dev/null
assert_no_file "$(dx_lifecycle_terminal_commit_file "$TERMINAL_REPLAY_SESSION")"
dx_lifecycle_control_lock_release "$TERMINAL_REPLAY_SESSION"
dx_completion_abandon "$TERMINAL_REPLAY_SESSION"
dx_lifecycle_atomic_write "$(dx_state_file "$TERMINAL_REPLAY_SESSION")" 7
if dx_lifecycle_terminal_commit_valid "$TERMINAL_REPLAY_SESSION"; then
  printf 'stale terminal proof authorized a later Phase 7\n' >&2
  exit 1
fi

set +e
DEX_SESSION_ID="foreign-session" bash "$CONTROL" status > "$TMP_DIR/foreign.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "does not belong to this repository" "$TMP_DIR/foreign.out"

dx_clear_lifecycle_control "$DEX_SESSION_ID"
rm -f "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")" \
  "$(dx_loop_config_file "$DEX_SESSION_ID")"
set +e
bash "$CONTROL" stop > "$TMP_DIR/inactive.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "No active Dex lifecycle" "$TMP_DIR/inactive.out"

printf '%s\n' 7 > "$(dx_state_file "$DEX_SESSION_ID")"
set +e
DEX_LOOP_ACTIVE=1 bash "$CONTROL" stop --reason "The lifecycle is already complete" \
  > "$TMP_DIR/completed.out" 2>&1
RC=$?
set -e
[[ "$RC" -ne 0 ]] || assert_at $LINENO
grep -q "No active Dex lifecycle" "$TMP_DIR/completed.out"
[[ ! -f "$(dx_lifecycle_control_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO

# A checkout with no lifecycle state at all. Every case above wrote a phase
# file first, which hid the fact that dx_lifecycle_current_phase reported "no
# phase" by returning 1: control.sh reads it into CURRENT_PHASE on line 64
# under `set -e`, so the whole command died there without printing a word —
# `status` and `--help` included. The messages below were always written; they
# were simply unreachable.
rm -f "$(dx_state_file "$DEX_SESSION_ID")" "$(dx_paused_file "$DEX_SESSION_ID")" \
  "$(dx_active_file "$DEX_SESSION_ID")" "$(dx_handoff_mode_file "$DEX_SESSION_ID")" \
  "$(dx_loop_config_file "$DEX_SESSION_ID")" "$(dx_owner_file "$DEX_SESSION_ID")"
dx_clear_lifecycle_control "$DEX_SESSION_ID"

bash "$CONTROL" status > "$TMP_DIR/bare-status.out" 2>&1
assert_contains "No Dex lifecycle state was found" "$TMP_DIR/bare-status.out"

bash "$CONTROL" --help > "$TMP_DIR/bare-help.out" 2>&1
assert_contains "Usage: dx control" "$TMP_DIR/bare-help.out"

assert_rejected "$LINENO" bash "$CONTROL" stop > "$TMP_DIR/bare-stop.out" 2>&1
assert_contains "No active Dex lifecycle" "$TMP_DIR/bare-stop.out"

# waiver_comment (#60): an agent waiver's reason goes on the open PR when the
# project opts in. gh is faked: FAKE_GH_PR is the open PR number (empty for
# none), and FAKE_GH_LIST / FAKE_GH_COMMENT=error make that call fail.
FAKE_GH_BIN="$TMP_DIR/fake-gh-bin"
export FAKE_GH_LOG="$TMP_DIR/fake-gh.log" FAKE_GH_COMMENTS="$TMP_DIR/fake-gh-comments"
mkdir -p "$FAKE_GH_BIN"
cat > "$FAKE_GH_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "pr list")
    [[ "${FAKE_GH_LIST:-}" != error ]] || exit 1
    printf '%s\n' "${FAKE_GH_PR:-}"
    ;;
  "pr comment")
    [[ "${FAKE_GH_COMMENT:-}" != error ]] || exit 1
    while [[ $# -gt 0 && "$1" != --body-file ]]; do shift; done
    { printf 'PR %s\n' "${FAKE_GH_PR:-}"; cat "$2"; printf '%s\n' '---'; } >> "$FAKE_GH_COMMENTS"
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$FAKE_GH_BIN/gh"

set_waiver_comment() { # <value>
  mkdir -p "$REPO/.dex"
  printf '# Test\n\n## Pull Requests\n\n```yaml\nwaiver_comment: %s\n```\n' "$1" > "$REPO/.dex/dex.md"
}

run_waiver() { # <sid> <out> [extra control args...]
  local run_sid="$1" run_out="$2"
  shift 2
  setup_attribution_lifecycle "$run_sid"
  : > "$FAKE_GH_LOG"
  : > "$FAKE_GH_COMMENTS"
  env PATH="$FAKE_GH_BIN:$PATH" DEX_SESSION_ID="$run_sid" bash "$CONTROL" waive \
    verification.required-gates "$@" > "$run_out" 2>&1
}

waiver_row_count() { # <sid>
  local count_file
  count_file=$(dx_override_file "$1")
  [[ -f "$count_file" ]] || { printf '0\n'; return 0; }
  awk -F '\t' '$3 == "waive"' "$count_file" | wc -l | tr -d ' '
}

WC_SESSION="$(dx_session_repo_key)-waiver-comment"

# No setting: nothing reaches gh and the waiver records as before.
rm -rf "$REPO/.dex"
FAKE_GH_PR=7 run_waiver "$WC_SESSION" "$TMP_DIR/wc-unset.out" --reason "Only the dex#1 baseline fails"
assert_eq "" "$(cat "$FAKE_GH_LOG")" "unset waiver_comment makes no gh call"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "unset waiver_comment records the waiver"
dx_cleanup_session "$WC_SESSION"

# off: the same.
set_waiver_comment off
FAKE_GH_PR=7 run_waiver "$WC_SESSION" "$TMP_DIR/wc-off.out" --reason "Only the dex#1 baseline fails"
assert_eq "" "$(cat "$FAKE_GH_LOG")" "waiver_comment off makes no gh call"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "waiver_comment off records the waiver"
dx_cleanup_session "$WC_SESSION"

# on, with an open PR: one comment naming the gate, source, phase and reason,
# with every @ stripped so nobody is mentioned.
set_waiver_comment on
FAKE_GH_PR=42 run_waiver "$WC_SESSION" "$TMP_DIR/wc-on.out" \
  --reason "Flaky upstream check; ask @someone or @copilot later"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "waiver_comment on records the waiver"
assert_eq "1" "$(grep -c '^PR 42$' "$FAKE_GH_COMMENTS")" "waiver_comment on posts one comment"
assert_contains 'the `verification.required-gates` gate was waived in Phase 2' "$FAKE_GH_COMMENTS"
assert_contains "Source: agent" "$FAKE_GH_COMMENTS"
assert_contains "Reason: Flaky upstream check; ask someone or copilot later" "$FAKE_GH_COMMENTS"
! grep -Fq '@' "$FAKE_GH_COMMENTS" || assert_at $LINENO
assert_contains "pr list --state open --head" "$FAKE_GH_LOG"
dx_cleanup_session "$WC_SESSION"

# on, with no open PR: nothing is posted and the waiver still records.
FAKE_GH_PR='' run_waiver "$WC_SESSION" "$TMP_DIR/wc-on-no-pr.out" --reason "Only the dex#1 baseline fails"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "no PR still records the waiver"
assert_eq "" "$(cat "$FAKE_GH_COMMENTS")" "no PR posts nothing"
dx_cleanup_session "$WC_SESSION"

# on, when the post fails: the waiver is recorded and the failure only warns.
FAKE_GH_PR=42 FAKE_GH_COMMENT=error run_waiver "$WC_SESSION" "$TMP_DIR/wc-on-fail.out" \
  --reason "Only the dex#1 baseline fails"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "a failed post under on keeps the waiver"
assert_contains "its PR comment could not be posted" "$TMP_DIR/wc-on-fail.out"
dx_cleanup_session "$WC_SESSION"

# A human waiver never posts.
FAKE_GH_PR=42 run_waiver "$WC_SESSION" "$TMP_DIR/wc-human.out" --source human \
  --reason "The operator accepted the baseline failure"
assert_eq "" "$(cat "$FAKE_GH_LOG")" "a human waiver makes no gh call"
dx_cleanup_session "$WC_SESSION"

# required: a failed post, or a failed PR lookup, refuses the waiver.
set_waiver_comment required
if FAKE_GH_PR=42 FAKE_GH_COMMENT=error run_waiver "$WC_SESSION" "$TMP_DIR/wc-required-fail.out" \
  --reason "Only the dex#1 baseline fails"; then
  assert_at $LINENO
fi
assert_contains "The waiver was not recorded" "$TMP_DIR/wc-required-fail.out"
assert_eq "0" "$(waiver_row_count "$WC_SESSION")" "a failed required post records nothing"
dx_cleanup_session "$WC_SESSION"
if FAKE_GH_LIST=error run_waiver "$WC_SESSION" "$TMP_DIR/wc-required-list.out" \
  --reason "Only the dex#1 baseline fails"; then
  assert_at $LINENO
fi
assert_contains "could not look up the open PR" "$TMP_DIR/wc-required-list.out"
assert_eq "0" "$(waiver_row_count "$WC_SESSION")" "a failed required lookup records nothing"
dx_cleanup_session "$WC_SESSION"

# required, posted: the comment goes up before the waiver records.
FAKE_GH_PR=42 run_waiver "$WC_SESSION" "$TMP_DIR/wc-required.out" --reason "Only the dex#1 baseline fails"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "required with a posted comment records the waiver"
assert_eq "1" "$(grep -c '^PR 42$' "$FAKE_GH_COMMENTS")" "required posts one comment"
dx_cleanup_session "$WC_SESSION"

# required, with no open PR: nothing to post, so the waiver records.
FAKE_GH_PR='' run_waiver "$WC_SESSION" "$TMP_DIR/wc-required-no-pr.out" --reason "Only the dex#1 baseline fails"
assert_eq "1" "$(waiver_row_count "$WC_SESSION")" "required with no PR records the waiver"
dx_cleanup_session "$WC_SESSION"

# An unrecognised value warns and behaves as off.
set_waiver_comment always
FAKE_GH_PR=42 run_waiver "$WC_SESSION" "$TMP_DIR/wc-bad.out" --reason "Only the dex#1 baseline fails"
assert_contains "expected off, on or required" "$TMP_DIR/wc-bad.out"
assert_eq "" "$(cat "$FAKE_GH_LOG")" "an unrecognised waiver_comment makes no gh call"
dx_cleanup_session "$WC_SESSION"
rm -rf "$REPO/.dex"

printf 'lifecycle control CLI tests passed\n'
