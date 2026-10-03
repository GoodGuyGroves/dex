#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-forget.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

new_repo() { # <directory>
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email dex@example.test
  git -C "$repo_dir" config user.name "Dex Test"
  printf 'base\n' > "$repo_dir/file.txt"
  git -C "$repo_dir" add file.txt
  git -C "$repo_dir" commit -q -m "test: initialize repo"
  git -C "$repo_dir" branch -m main
}

run_sessions() { # <repo> <output> <arguments...>
  local repo_dir="$1" output_file="$2"
  shift 2
  if (cd "$repo_dir" && bash "$ROOT/bin/sessions.sh" "$@") \
    > "$output_file" 2>&1; then
    COMMAND_RESULT=0
  else
    COMMAND_RESULT=$?
  fi
}

run_sessions_unverifiable() { # <repo> <output> <arguments...>
  local repo_dir="$1" output_file="$2"
  shift 2
  if (
    cd "$repo_dir"
    DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/unverifiable-proc" \
      DX_SESSION_RUNTIME_PS_BIN="$TMP_DIR/missing-ps" \
      bash "$ROOT/bin/sessions.sh" "$@"
  ) > "$output_file" 2>&1; then
    COMMAND_RESULT=0
  else
    COMMAND_RESULT=$?
  fi
}

write_session_metadata() { # <repo> <sid> <ticket> <name> [runtime-workspace]
  local repo_dir="$1" session_id="$2" ticket="$3" workspace_name="$4"
  dx_meta_write "$session_id" \
    "ticket_number=$ticket" \
    "wt_name=$workspace_name" \
    "wt_dir=$repo_dir" \
    "workspace_mode=in-place"
  dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" 3
}

make_running_session() { # <repo> <sid> <ticket> <name> [runtime-workspace]
  local repo_dir="$1" session_id="$2" ticket="$3" workspace_name="$4"
  local runtime_workspace="${5:-$repo_dir}" runtime_token
  write_session_metadata "$repo_dir" "$session_id" "$ticket" "$workspace_name"
  runtime_token=$(dx_session_runtime_start \
    "$session_id" codex "$runtime_workspace" "$$")
  printf '%s\n' "$runtime_token" >> "$TMP_DIR/private-runtime-tokens"
  LAST_RUNTIME_TOKEN="$runtime_token"
}

make_terminal_session() { # <repo> <sid> <ticket> <name> [runtime-workspace]
  local repo_dir="$1" session_id="$2" ticket="$3" workspace_name="$4"
  local runtime_workspace="${5:-$repo_dir}"
  make_running_session \
    "$repo_dir" "$session_id" "$ticket" "$workspace_name" "$runtime_workspace"
  dx_session_runtime_finish "$session_id" "$LAST_RUNTIME_TOKEN" paused "$$"
}

populate_full_state() { # <sid>
  local session_id="$1" state_target completion_generation
  printf 'times\n' > "$(dx_times_file "$session_id")"
  printf 'context\n' > "$(dx_context_file "$session_id")"
  printf 'log\n' > "$(dx_log_file "$session_id")"
  printf 'outcome\n' > "$(dx_phase_outcomes_file "$session_id")"
  printf 'intervention\n' > "$DX_STATE_DIR/${session_id}.interventions"
  printf 'human-complete\n' > "$DX_STATE_DIR/${session_id}.human-complete"
  printf 'terminal\n' > "$DX_STATE_DIR/${session_id}.terminal-commit"
  printf 'run-forget-happy\n' > "$(dx_run_id_file "$session_id")"
  dx_record_session_branch "$session_id" "$REPO_A"
  dx_agent_session_handle_write "$session_id" claude \
    01999999-1111-4222-8333-444444444444
  dx_agent_session_handle_write "$session_id" codex \
    01999999-aaaa-4bbb-8ccc-dddddddddddd

  for state_target in \
    "$(dx_loop_file "$session_id")" \
    "$(dx_complete_file "$session_id")" \
    "$(dx_active_file "$session_id")" \
    "$(dx_owner_file "$session_id")" \
    "$(dx_prompt_file "$session_id")" \
    "$(dx_findings_file "$session_id")" \
    "$(dx_debt_file "$session_id")" \
    "$(dx_loop_config_file "$session_id")" \
    "$(dx_handoff_mode_file "$session_id")" \
    "$(dx_paused_file "$session_id")" \
    "$(dx_pause_state_file "$session_id")" \
    "$(dx_watch_pause_file "$session_id")" \
    "$(dx_lifecycle_control_file "$session_id")" \
    "$(dx_watch_lock_file "$session_id" ci)" \
    "$(dx_watch_lock_file "$session_id" pr)" \
    "$(dx_review_state_file "$session_id")" \
    "$(dx_review_result_file "$session_id")" \
    "$(dx_review_context_file "$session_id")" \
    "$(dx_review_input_file "$session_id")" \
    "$(dx_review_criteria_file "$session_id")" \
    "$(dx_review_criteria_approval_file "$session_id")" \
    "$(dx_review_evidence_file "$session_id")" \
    "$(dx_complete_state_file "$session_id")"; do
    printf 'state\n' > "$state_target"
  done
  printf 'engine=codex-plugin\nsession=%s\n' "$session_id" \
    > "$(dx_provider_state_file "$session_id")"
  printf 'receipt\n' > "$(dx_review_receipt_file "$session_id")"
  printf 'selection\n' > "$(dx_review_selection_file "$session_id")"
  printf 'ledger\n' > "$(dx_review_ledger_file "$session_id")"
  mkdir -p "$(dx_review_proof_dir "$session_id")/1"
  printf 'proof\n' > "$(dx_review_proof_dir "$session_id")/1/evidence.json"
  mkdir -p "$(dx_review_check_cache_dir "$session_id")" "$DX_LOOP_DIR/$session_id.review-report" \
    "$DX_LOOP_DIR/$session_id.review-publish-lock"
  printf 'cache\n' > "$(dx_review_check_cache_dir "$session_id")/fixture.json"
  printf 'report\n' > "$DX_LOOP_DIR/$session_id.review-report/context"
  printf 'stale\n' > "$DX_LOOP_DIR/$session_id.review-publish-lock/owner"
  for state_target in \
    "$(dx_phase_started_file "$session_id" 0)" \
    "$(dx_phase_ready_file "$session_id" 0)" \
    "$(dx_phase_busy_notice_file "$session_id" 3)" \
    "$(dx_phase_busy_cancel_file "$session_id" 3)" \
    "$(dx_phase_busy_quiesced_file "$session_id" 3)" \
    "$DX_LOOP_DIR/${session_id}.phase-prompt-loop.started" \
    "$DX_LOOP_DIR/${session_id}.phase-prompt-loop.ready"; do
    printf 'marker\n' > "$state_target"
  done
  completion_generation=$(dx_completion_issue \
    "$session_id" lifecycle phase 3)
  dx_completion_write_receipt "$session_id" "$completion_generation"
  printf 'legacy\n' > "$(dx_complete_file "$session_id")"
}

assert_forget_refused() { # <sid> <label> [runner]
  local session_id="$1" label="$2" runner="${3:-run_sessions}"
  local output_file="$TMP_DIR/${label}.out"
  "$runner" "$REPO_A" "$output_file" forget "session:$session_id"
  assert_eq "1" "$COMMAND_RESULT" "$label result"
  assert_contains "Session '$session_id' was not forgotten." "$output_file"
  assert_contains "Its state remains and requires repair." "$output_file"
  assert_file "$(dx_meta_file "$session_id")"
}

REPO_A="$TMP_DIR/repos/alpha"
REPO_B="$TMP_DIR/repos/bravo"
new_repo "$REPO_A"
new_repo "$REPO_B"
git -C "$REPO_A" checkout -q -b feature-forget

# Successful forget removes every session payload while leaving the checkout,
# branch, dirty files, run journal, and persistent mutation locks untouched.
HAPPY_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-happy)"
make_terminal_session "$REPO_A" "$HAPPY_SID" 801 forget-happy
populate_full_state "$HAPPY_SID"
mkdir -p "$DX_RUN_ROOT/run-forget-happy"
printf 'journal\n' > "$DX_RUN_ROOT/run-forget-happy/events.jsonl"
printf 'dirty tracked\n' >> "$REPO_A/file.txt"
printf 'dirty untracked\n' > "$REPO_A/untracked.txt"
BRANCH_BEFORE="$(git -C "$REPO_A" branch --show-current)"
REF_BEFORE="$(git -C "$REPO_A" rev-parse "refs/heads/$BRANCH_BEFORE")"
STATUS_BEFORE="$(git -C "$REPO_A" status --porcelain=v1)"

run_sessions "$REPO_A" "$TMP_DIR/happy.out" forget "session:$HAPPY_SID"
assert_eq "0" "$COMMAND_RESULT" "successful forget result"
assert_contains "Session $HAPPY_SID was forgotten." "$TMP_DIR/happy.out"
assert_dir "$REPO_A"
assert_eq "$BRANCH_BEFORE" "$(git -C "$REPO_A" branch --show-current)" \
  "preserved checkout branch"
assert_eq "$REF_BEFORE" "$(git -C "$REPO_A" rev-parse "refs/heads/$BRANCH_BEFORE")" \
  "preserved branch ref"
assert_eq "$STATUS_BEFORE" "$(git -C "$REPO_A" status --porcelain=v1)" \
  "preserved dirty files"
assert_contains "dirty tracked" "$REPO_A/file.txt"
assert_contains "dirty untracked" "$REPO_A/untracked.txt"
assert_file "$DX_RUN_ROOT/run-forget-happy/events.jsonl"
assert_file "$(dx_session_runtime_file "$HAPPY_SID")-lock"
assert_file "$(dx_completion_lock_file "$HAPPY_SID")"
find "$DX_STATE_DIR" "$DX_LOOP_DIR" -maxdepth 1 \
  -name "${HAPPY_SID}.*" -print | LC_ALL=C sort \
  > "$TMP_DIR/happy-residue.actual"
printf '%s\n' \
  "$(dx_session_runtime_file "$HAPPY_SID")-lock" \
  "$(dx_completion_lock_file "$HAPPY_SID")" | LC_ALL=C sort \
  > "$TMP_DIR/happy-residue.expected"
cmp -s "$TMP_DIR/happy-residue.expected" "$TMP_DIR/happy-residue.actual" \
  || fail "successful forget left unexpected session state"
if dx_session_catalog_select "session:$HAPPY_SID" --repo "$REPO_A" \
    >/dev/null 2>&1; then
  fail "forgotten session remains catalog-visible"
fi

# Selection stays current-repository scoped and excludes review children.
run_sessions "$REPO_A" "$TMP_DIR/missing.out" \
  forget session:does-not-exist
assert_eq "1" "$COMMAND_RESULT" "missing selector result"
assert_contains "No session matches 'session:does-not-exist'" \
  "$TMP_DIR/missing.out"

AMBIGUOUS_ONE="$(cd "$REPO_A" && dx_scoped_session_id forget-ambiguous-one)"
AMBIGUOUS_TWO="$(cd "$REPO_A" && dx_scoped_session_id forget-ambiguous-two)"
make_terminal_session "$REPO_A" "$AMBIGUOUS_ONE" 899 ambiguous-one
make_terminal_session "$REPO_A" "$AMBIGUOUS_TWO" 899 ambiguous-two
run_sessions "$REPO_A" "$TMP_DIR/invalid.out" forget 'session:../bad'
assert_eq "3" "$COMMAND_RESULT" "invalid selector result"
assert_contains "session selector is invalid" "$TMP_DIR/invalid.out"
run_sessions "$REPO_A" "$TMP_DIR/ambiguous.out" forget ticket:899
assert_eq "2" "$COMMAND_RESULT" "ambiguous selector result"
assert_contains "matches 2 sessions" "$TMP_DIR/ambiguous.out"
assert_file "$(dx_meta_file "$AMBIGUOUS_ONE")"
assert_file "$(dx_meta_file "$AMBIGUOUS_TWO")"

CHILD_SID="${AMBIGUOUS_ONE}-pass-0123456789abcdef0123456789abcdef"
dx_meta_write "$CHILD_SID" \
  "session_role=review-child" \
  "parent_session_id=$AMBIGUOUS_ONE" \
  "child_kind=pass"
dx_lifecycle_atomic_write "$(dx_state_file "$CHILD_SID")" 3
run_sessions "$REPO_A" "$TMP_DIR/child.out" forget "session:$CHILD_SID"
assert_eq "1" "$COMMAND_RESULT" "child selector result"
assert_contains "No session matches 'session:$CHILD_SID'" "$TMP_DIR/child.out"
assert_file "$(dx_meta_file "$CHILD_SID")"

CROSS_REPO_SID="$(cd "$REPO_B" && dx_scoped_session_id forget-cross-repo)"
make_terminal_session "$REPO_B" "$CROSS_REPO_SID" 802 cross-repo
run_sessions "$REPO_A" "$TMP_DIR/cross-repo.out" \
  forget "session:$CROSS_REPO_SID"
assert_eq "1" "$COMMAND_RESULT" "cross-repository selector result"
assert_contains "No session matches 'session:$CROSS_REPO_SID'" \
  "$TMP_DIR/cross-repo.out"
assert_file "$(dx_meta_file "$CROSS_REPO_SID")"

# The cleanup core owns mutation eligibility. Every unsafe or unverifiable
# selected record fails without a public success claim.
LIVE_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-live)"
make_running_session "$REPO_A" "$LIVE_SID" 803 live
LIVE_TOKEN="$LAST_RUNTIME_TOKEN"
assert_forget_refused "$LIVE_SID" live

UNVERIFIABLE_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-unverifiable)"
make_running_session "$REPO_A" "$UNVERIFIABLE_SID" 804 unverifiable
UNVERIFIABLE_TOKEN="$LAST_RUNTIME_TOKEN"
mkdir -p "$TMP_DIR/unverifiable-proc"
assert_forget_refused \
  "$UNVERIFIABLE_SID" unverifiable run_sessions_unverifiable

CORRUPT_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-corrupt)"
make_terminal_session "$REPO_A" "$CORRUPT_SID" 805 corrupt
CORRUPT_SECRET='DO_NOT_PRINT_THIS_CORRUPT_RUNTIME_SECRET'
printf '{"token":"%s"\n' "$CORRUPT_SECRET" \
  > "$(dx_session_runtime_file "$CORRUPT_SID")"
assert_forget_refused "$CORRUPT_SID" corrupt

UNSAFE_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-unsafe)"
make_terminal_session "$REPO_A" "$UNSAFE_SID" 806 unsafe
chmod 666 "$(dx_state_file "$UNSAFE_SID")"
assert_forget_refused "$UNSAFE_SID" unsafe

INCONSISTENT_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-inconsistent)"
INCONSISTENT_WORKSPACE="$REPO_A/.dex/worktrees/inconsistent"
mkdir -p "$INCONSISTENT_WORKSPACE"
make_terminal_session "$REPO_A" "$INCONSISTENT_SID" 807 inconsistent \
  "$INCONSISTENT_WORKSPACE"
assert_forget_refused "$INCONSISTENT_SID" inconsistent

# A failure after recovery ownership begins must remain visible and repairable.
PARTIAL_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-partial)"
make_terminal_session "$REPO_A" "$PARTIAL_SID" 808 partial
PARTIAL_BUSY_TOKEN="$(dx_phase_busy_begin "$PARTIAL_SID" 3 review-child)"
assert_forget_refused "$PARTIAL_SID" partial
assert_eq "failed" "$(dx_session_runtime_field "$PARTIAL_SID" status)" \
  "partial failure runtime status"
assert_eq "$PARTIAL_BUSY_TOKEN" "$(dx_phase_busy_token "$PARTIAL_SID" 3)" \
  "partial failure busy fence"
run_sessions "$REPO_A" "$TMP_DIR/partial-show.out" \
  show "session:$PARTIAL_SID"
assert_eq "0" "$COMMAND_RESULT" "partial failure catalog visibility"
assert_contains "Session: $PARTIAL_SID" "$TMP_DIR/partial-show.out"

assert_no_private_output() {
  find "$TMP_DIR" -type f -name '*.out' -exec cat {} + \
    > "$TMP_DIR/all-command-output"
  while IFS= read -r private_token; do
    [[ -n "$private_token" ]] || continue
    assert_not_contains "$private_token" "$TMP_DIR/all-command-output"
  done < "$TMP_DIR/private-runtime-tokens"
  assert_not_contains "$CORRUPT_SECRET" "$TMP_DIR/all-command-output"
  assert_not_contains '"token"' "$TMP_DIR/all-command-output"
  assert_not_contains '.runtime-owners' "$TMP_DIR/all-command-output"
}
assert_no_private_output

dx_session_runtime_finish "$LIVE_SID" "$LIVE_TOKEN" paused "$$"
dx_session_runtime_finish \
  "$UNVERIFIABLE_SID" "$UNVERIFIABLE_TOKEN" paused "$$"

# A session created under a default umask (#81). Its .meta is written 0600,
# and one an older Dex left at 0644 is narrowed and forgotten. A .meta that is
# a symlink is still refused. This file runs under umask 077, so these cases
# switch to 022 themselves.
file_mode() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))[2:])' "$1"; }

UMASK_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-umask)"
umask 022
make_terminal_session "$REPO_A" "$UMASK_SID" 811 forget-umask
umask 077
assert_eq "600" "$(file_mode "$(dx_meta_file "$UMASK_SID")")" "meta written under umask 022 is private"
run_sessions "$REPO_A" "$TMP_DIR/umask.out" forget "session:$UMASK_SID"
assert_eq "0" "$COMMAND_RESULT" "forget a session created under umask 022"
assert_no_file "$(dx_meta_file "$UMASK_SID")"

OLD_META_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-old-meta)"
umask 022
make_terminal_session "$REPO_A" "$OLD_META_SID" 812 forget-old-meta
umask 077
chmod 644 "$(dx_meta_file "$OLD_META_SID")"
run_sessions "$REPO_A" "$TMP_DIR/old-meta.out" forget "session:$OLD_META_SID"
assert_eq "0" "$COMMAND_RESULT" "forget a session whose .meta an older Dex left at 0644"
assert_contains "Session $OLD_META_SID was forgotten." "$TMP_DIR/old-meta.out"
assert_no_file "$(dx_meta_file "$OLD_META_SID")"

LINK_META_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-link-meta)"
make_terminal_session "$REPO_A" "$LINK_META_SID" 813 forget-link-meta
mv "$(dx_meta_file "$LINK_META_SID")" "$TMP_DIR/link-meta-target"
chmod 644 "$TMP_DIR/link-meta-target"
ln -s "$TMP_DIR/link-meta-target" "$(dx_meta_file "$LINK_META_SID")"
run_sessions "$REPO_A" "$TMP_DIR/link-meta.out" forget "session:$LINK_META_SID"
[[ "$COMMAND_RESULT" -ne 0 ]] || assert_at $LINENO
[[ -L "$(dx_meta_file "$LINK_META_SID")" ]] || assert_at $LINENO
assert_eq "644" "$(file_mode "$TMP_DIR/link-meta-target")" "a symlinked .meta target is not narrowed"
rm -f "$(dx_meta_file "$LINK_META_SID")"

# An orphaned .runtime (#88): teardown before #86 deleted .meta and left
# .runtime, .runtime-lock and .run-id. Forget removes a dead one whose status
# is completed, failed, stopped or abandoned, and keeps .runtime-lock. A live,
# running, paused or blocked runtime, or any other leftover beside it, is kept.
make_orphan_runtime() { # <sid> <status|running> [owner-pid]
  local session_id="$1" runtime_status="$2" owner_pid="${3:-$$}" runtime_token
  runtime_token=$(dx_session_runtime_start \
    "$session_id" codex "$REPO_A" "$owner_pid")
  printf '%s\n' "$runtime_token" >> "$TMP_DIR/private-runtime-tokens"
  if [[ "$runtime_status" != "running" ]]; then
    dx_session_runtime_finish \
      "$session_id" "$runtime_token" "$runtime_status" "$owner_pid"
  fi
  printf 'run_orphan\n' > "$(dx_run_id_file "$session_id")"
}

assert_orphan_forgotten() { # <sid> <label>
  local session_id="$1" label="$2"
  run_sessions "$REPO_A" "$TMP_DIR/${label}.out" forget "session:$session_id"
  assert_eq "0" "$COMMAND_RESULT" "$label result"
  assert_contains "Session $session_id was forgotten." "$TMP_DIR/${label}.out"
  find "$DX_STATE_DIR" "$DX_LOOP_DIR" -maxdepth 1 \
    -name "${session_id}.*" -print > "$TMP_DIR/${label}-residue.actual"
  printf '%s\n' "$(dx_session_runtime_file "$session_id")-lock" \
    > "$TMP_DIR/${label}-residue.expected"
  cmp -s "$TMP_DIR/${label}-residue.expected" "$TMP_DIR/${label}-residue.actual" \
    || fail "$label left more than .runtime-lock behind"
  run_sessions "$REPO_A" "$TMP_DIR/${label}-again.out" forget "session:$session_id"
  assert_eq "1" "$COMMAND_RESULT" "$label second forget result"
  assert_contains "No session matches 'session:$session_id'" \
    "$TMP_DIR/${label}-again.out"
}

assert_orphan_kept() { # <sid> <label>
  local session_id="$1" label="$2" runtime_file
  runtime_file=$(dx_session_runtime_file "$session_id")
  cp "$runtime_file" "$TMP_DIR/${label}.runtime-before"
  run_sessions "$REPO_A" "$TMP_DIR/${label}.out" forget "session:$session_id"
  assert_eq "1" "$COMMAND_RESULT" "$label result"
  assert_contains "Session '$session_id' was not forgotten." "$TMP_DIR/${label}.out"
  cmp -s "$TMP_DIR/${label}.runtime-before" "$runtime_file" \
    || fail "$label changed the kept .runtime"
  assert_file "$(dx_run_id_file "$session_id")"
  assert_no_file "$(dx_meta_file "$session_id")"
}

ORPHAN_FAILED_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-orphan-failed)"
make_orphan_runtime "$ORPHAN_FAILED_SID" failed
assert_no_file "$(dx_meta_file "$ORPHAN_FAILED_SID")"
assert_orphan_forgotten "$ORPHAN_FAILED_SID" orphan-failed

ORPHAN_COMPLETED_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-orphan-completed)"
make_orphan_runtime "$ORPHAN_COMPLETED_SID" completed
assert_orphan_forgotten "$ORPHAN_COMPLETED_SID" orphan-completed

ORPHAN_LIVE_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-orphan-live)"
make_orphan_runtime "$ORPHAN_LIVE_SID" running
assert_orphan_kept "$ORPHAN_LIVE_SID" orphan-live

sleep 300 &
ORPHAN_OWNER_PID=$!
ORPHAN_RUNNING_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-orphan-running)"
make_orphan_runtime "$ORPHAN_RUNNING_SID" running "$ORPHAN_OWNER_PID"
kill "$ORPHAN_OWNER_PID" 2>/dev/null || true
wait "$ORPHAN_OWNER_PID" 2>/dev/null || true
assert_orphan_kept "$ORPHAN_RUNNING_SID" orphan-running-dead-owner

for orphan_status in paused blocked; do
  ORPHAN_HELD_SID="$(cd "$REPO_A" && dx_scoped_session_id "forget-orphan-${orphan_status}")"
  make_orphan_runtime "$ORPHAN_HELD_SID" "$orphan_status"
  assert_orphan_kept "$ORPHAN_HELD_SID" "orphan-${orphan_status}"
done

ORPHAN_EXTRA_SID="$(cd "$REPO_A" && dx_scoped_session_id forget-orphan-extra)"
make_orphan_runtime "$ORPHAN_EXTRA_SID" completed
dx_lifecycle_atomic_write "$(dx_state_file "$ORPHAN_EXTRA_SID")" 7
assert_orphan_kept "$ORPHAN_EXTRA_SID" orphan-extra-phase
assert_file "$(dx_state_file "$ORPHAN_EXTRA_SID")"

# An exact cleanup that stopped after removing .meta keeps its journal. Forget
# resumes that journal through the exact cleanup, not the orphan path.
# Its own repo keeps the orphan fixtures above out of its cleanup plan.
REPO_C="$TMP_DIR/repos/charlie"
new_repo "$REPO_C"
JOURNAL_SID="$(cd "$REPO_C" && dx_scoped_session_id forget-journal-resume)"
make_terminal_session "$REPO_C" "$JOURNAL_SID" 88 journal-resume
# A separate bash runs the fault seam, away from this suite's ERR trap.
if JOURNAL_SID="$JOURNAL_SID" REPO_C="$REPO_C" bash -c '
  source "$DEX_DIR/lib/common.sh"
  source "$DEX_DIR/lib/session-management.sh"
  eval "$(declare -f __dx_session_management_artifacts | \
    sed "1s/^__dx_session_management_artifacts /__journal_artifacts_original /")"
  __dx_session_management_artifacts() {
    if [[ "$1" == "remove-payload" && "$2" == "$JOURNAL_SID" ]]; then
      command rm -f "$(dx_meta_file "$2")"
      return 1
    fi
    __journal_artifacts_original "$@"
  }
  __dx_session_management_cleanup_exact "$REPO_C" "$JOURNAL_SID"
' > "$TMP_DIR/journal-partial.out" 2>&1; then
  fail "the partial cleanup fixture did not fail"
fi
assert_no_file "$(dx_meta_file "$JOURNAL_SID")"
assert_file "$(dx_session_cleanup_journal_file "$JOURNAL_SID")"
run_sessions "$REPO_C" "$TMP_DIR/journal-resume.out" forget "session:$JOURNAL_SID"
assert_eq "0" "$COMMAND_RESULT" "journal resume result"
assert_contains "Session $JOURNAL_SID was forgotten." "$TMP_DIR/journal-resume.out"
assert_no_file "$(dx_session_cleanup_journal_file "$JOURNAL_SID")"
assert_no_file "$(dx_session_runtime_file "$JOURNAL_SID")"

# The orphan and journal cases above print no runtime token either.
assert_no_private_output

printf '%s\n' "session forget tests passed"
