#!/usr/bin/env bash
# dex-test-lane: fast
# A run's state outlives its worktree in DEX_HOME. dxrm must take the runtime
# lease with the rest of the session (#29), and `dx <ticket>` must not quietly
# reattach a run whose worktree was removed (#55): it asks on a terminal and
# otherwise starts a new run, and it never discards a runtime that is live.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-stale-run.XXXXXX")"
LIVE_PID=""
cleanup() {
  [[ -z "$LIVE_PID" ]] || kill "$LIVE_PID" 2>/dev/null || true
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home" ZDOTDIR="$TMP_DIR/home" DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs" DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools" DEXCODE_SYNC=0 DEX_FACTORY_SYNC=false
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

if ! command -v zsh >/dev/null 2>&1; then
  printf 'skip: zsh is not installed, so dx.sh cannot be exercised\n'
  exit 0
fi

export TEST_REPO="$TMP_DIR/repo"
git init -q -b main "$TEST_REPO"
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
mkdir -p "$TEST_REPO/.dex"
printf '# Project\n' > "$TEST_REPO/.dex/dex.md"
printf '.dex/worktrees/\n' > "$TEST_REPO/.gitignore"
git -C "$TEST_REPO" add .dex/dex.md .gitignore
git -C "$TEST_REPO" commit -qm init

# dx_zsh <script> — run zsh with dx.sh loaded, in the repository.
dx_zsh() {
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; '"$1"
}

# seed_run <worktree-name> <phase> <runtime: finished|live|none>
# A run as an earlier lifecycle leaves it: meta, phase, run ID and a runtime
# record. A finished runtime is paused; a live one belongs to a running process.
seed_run() {
  TEST_WT_NAME="$1" TEST_PHASE="$2" TEST_RUNTIME="$3" TEST_LIVE_PID="${LIVE_PID:-}" dx_zsh '
    set -e
    sid=$(__dx_session_id_for_workspace worktree "$TEST_WT_NAME")
    wt_dir="$TEST_REPO/.dex/worktrees/$TEST_WT_NAME"
    dx_meta_write "$sid" "wt_name=$TEST_WT_NAME" "wt_dir=$wt_dir" "workspace_mode=worktree"
    dx_lifecycle_atomic_write "$(dx_state_file "$sid")" "$TEST_PHASE"
    print -r -- "run_old_${TEST_WT_NAME}" > "$(dx_run_id_file "$sid")"
    case "$TEST_RUNTIME" in
      finished)
        token=$(dx_session_runtime_start "$sid" claude "$wt_dir" "$$")
        dx_session_runtime_finish "$sid" "$token" paused "$$" >/dev/null
        ;;
      live)
        dx_session_runtime_start "$sid" claude "$wt_dir" "$TEST_LIVE_PID" >/dev/null
        ;;
    esac
    print -r -- "$sid"
  '
}

state_of() { # <sid> — which of phase, run-id, runtime still exist
  local sid="$1" present=""
  [[ ! -e "$DX_STATE_DIR/$sid.phase" ]] || present="$present phase"
  [[ ! -e "$(dx_zsh "dx_run_id_file $sid")" ]] || present="$present run-id"
  [[ ! -e "$(dx_zsh "dx_session_runtime_file $sid")" ]] || present="$present runtime"
  printf '%s\n' "${present# }"
}

lock_of() { # <sid> — "runtime-lock" while the persistent runtime lock exists
  [[ ! -e "$DX_STATE_DIR/$1.runtime-lock" ]] || printf 'runtime-lock\n'
}

# ── #29: dxrm takes the runtime lease with the session ─────────────────────
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-21" -b worktree-ticket-21 HEAD
SID=$(seed_run ticket-21 3 finished)
[[ "$(state_of "$SID")" == "phase run-id runtime" ]] || assert_at $LINENO
dx_zsh 'dxrm 21' > "$TMP_DIR/dxrm.out" 2>&1 || { cat "$TMP_DIR/dxrm.out" >&2; fail "dxrm 21 failed"; }
assert_eq "" "$(state_of "$SID")" "dxrm leaves no phase, run ID or runtime behind"
assert_eq "runtime-lock" "$(lock_of "$SID")" "the persistent runtime lock outlives the session"

# A ticket close waiting for the merge outlives the session, as it did before
# dxrm took the runtime lease too.
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-23" -b worktree-ticket-23 HEAD
SID=$(seed_run ticket-23 3 finished)
TEST_SID="$SID" dx_zsh 'dx_meta_write "$TEST_SID" ticket_close_pending=1 ticket_close_target=Done'
dx_zsh 'dxrm 23' > "$TMP_DIR/dxrm-close.out" 2>&1 || { cat "$TMP_DIR/dxrm-close.out" >&2; fail "dxrm 23 failed"; }
assert_eq "" "$(state_of "$SID")" "dxrm with a pending ticket close still drops the run"
assert_eq "1" "$(TEST_SID="$SID" dx_zsh 'dx_meta_read "$TEST_SID" ticket_close_pending')" \
  "the pending ticket close is kept for the merge sweep"
assert_eq "" "$(TEST_SID="$SID" dx_zsh 'dx_meta_read "$TEST_SID" wt_dir')" \
  "only the ticket close part of the metadata is kept"

# A runtime whose owner is still running keeps its lease, and dxrm says so.
# Started outside this shell's job table, so stopping it at the end is quiet.
LIVE_PID=$(sleep 300 >/dev/null 2>&1 & printf '%s\n' "$!")
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-22" -b worktree-ticket-22 HEAD
SID=$(seed_run ticket-22 3 live)
dx_zsh 'dxrm 22' > "$TMP_DIR/dxrm-live.out" 2>&1 || true
assert_eq "runtime" "$(state_of "$SID")" "a live runtime keeps its lease; the rest goes"
assert_contains "is still live or not finished" "$TMP_DIR/dxrm-live.out"

# The same when the worktree directory is already gone (#84): dxrm finds the
# run through its branch and still takes a finished runtime's lease. The
# persistent .runtime-lock inode stays, as it does with the worktree present.
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-24" -b worktree-ticket-24 HEAD
SID=$(seed_run ticket-24 3 finished)
[[ "$(lock_of "$SID")" == "runtime-lock" ]] || assert_at $LINENO
git -C "$TEST_REPO" worktree remove "$TEST_REPO/.dex/worktrees/ticket-24"
dx_zsh 'dxrm 24' > "$TMP_DIR/dxrm-gone.out" 2>&1 || { cat "$TMP_DIR/dxrm-gone.out" >&2; fail "dxrm 24 failed"; }
assert_eq "" "$(state_of "$SID")" "dxrm without a worktree leaves no phase, run ID or runtime"
assert_eq "runtime-lock" "$(lock_of "$SID")" "dxrm without a worktree keeps the lock as with one"
assert_not_contains "still live or not finished" "$TMP_DIR/dxrm-gone.out"

git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-25" -b worktree-ticket-25 HEAD
SID=$(seed_run ticket-25 3 live)
git -C "$TEST_REPO" worktree remove "$TEST_REPO/.dex/worktrees/ticket-25"
dx_zsh 'dxrm 25' > "$TMP_DIR/dxrm-gone-live.out" 2>&1 || true
assert_eq "runtime" "$(state_of "$SID")" "without a worktree, a live runtime still keeps its lease"
assert_contains "is still live or not finished" "$TMP_DIR/dxrm-gone-live.out"

# ── #55: a run whose worktree was removed is not reattached silently ────────
setup_ticket() { # <ticket> — the worktree setup `dx <ticket>` runs
  TEST_TICKET="$1" dx_zsh '__dx_setup_worktree "$TEST_TICKET" && __dx_startup_claim_release'
}

# No terminal: start a new run, say so, and drop the old state.
SID=$(seed_run ticket-31 3 finished)
setup_ticket 31 > "$TMP_DIR/stale.out" 2>&1 || { cat "$TMP_DIR/stale.out" >&2; fail "setup after removal failed"; }
assert_contains "stopped at Phase 3 and its worktree was removed" "$TMP_DIR/stale.out"
assert_contains "Starting a new run" "$TMP_DIR/stale.out"
assert_eq "" "$(state_of "$SID")" "a new run starts from Phase 0 with a fresh run ID"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-31" ]] || fail "the new run has no worktree"

# A terminal and the answer `r`: resume the earlier run where it stopped.
SID=$(seed_run ticket-32 4 finished)
python3 - "$TMP_DIR/resume.out" <<'PTY'
import os, pty, select, subprocess, sys, time
master, slave = pty.openpty()
process = subprocess.Popen(
    ["zsh", "-fc", 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; '
     '__dx_setup_worktree 32 && __dx_startup_claim_release'],
    stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
output, sent, deadline = b"", False, time.monotonic() + 60
while time.monotonic() < deadline:
    if select.select([master], [], [], .1)[0]:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        if not sent and b"[r/N]" in output:
            os.write(master, b"r\n")
            sent = True
    elif process.poll() is not None:
        break
process.wait(timeout=30)
os.close(master)
open(sys.argv[1], "wb").write(output)
assert sent, output
assert process.returncode == 0, (process.returncode, output)
PTY
assert_contains "Resuming the earlier run of ticket-32 at Phase 4" "$TMP_DIR/resume.out"
assert_eq "phase run-id runtime" "$(state_of "$SID")" "resume keeps the earlier run"
assert_eq "4" "$(cat "$DX_STATE_DIR/$SID.phase")" "resume keeps the phase"

# A live runtime is never discarded: Dex refuses rather than attach or wipe.
SID=$(seed_run ticket-33 2 live)
rc=0
setup_ticket 33 > "$TMP_DIR/stale-live.out" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "a live runtime was replaced by a new run"
assert_contains "still has a live or unfinished runtime" "$TMP_DIR/stale-live.out"
assert_eq "phase run-id runtime" "$(state_of "$SID")" "the live run is left in place"
[[ ! -d "$TEST_REPO/.dex/worktrees/ticket-33" ]] || fail "a worktree was created for a refused run"

# A worktree that exists is the ordinary resume path: no question, no discard.
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-34" -b worktree-ticket-34 HEAD
SID=$(seed_run ticket-34 5 finished)
setup_ticket 34 > "$TMP_DIR/present.out" 2>&1 || { cat "$TMP_DIR/present.out" >&2; fail "setup with the worktree present failed"; }
assert_not_contains "its worktree was removed" "$TMP_DIR/present.out"
assert_eq "phase run-id runtime" "$(state_of "$SID")" "an existing worktree resumes as before"

# ── #84: dxclean takes a finished runtime when the worktree is gone ─────────
# dxclean prunes a pushed lifecycle branch whose worktree is gone, through the
# branch name or, for a branch renamed away from worktree-*, the session record.
git -C "$TMP_DIR" init -q --bare origin.git
git -C "$TEST_REPO" remote add origin "$TMP_DIR/origin.git"
seed_gone_branch() { # <worktree-name> <branch> <runtime> — prints the session id
  local wt="$TEST_REPO/.dex/worktrees/$1" sid
  git -C "$TEST_REPO" worktree add -q "$wt" -b "$2" HEAD
  git -C "$TEST_REPO" push -q origin "$2"
  sid=$(seed_run "$1" 3 "$3")
  git -C "$TEST_REPO" worktree remove "$wt"
  printf '%s\n' "$sid"
}
dxclean_out() { # <file>
  dx_zsh 'dxclean' > "$1" 2>&1 || { cat "$1" >&2; fail "dxclean failed"; }
}

SID=$(seed_gone_branch ticket-26 worktree-ticket-26 finished)
dxclean_out "$TMP_DIR/clean-gone.out"
assert_contains "Deleting orphan branch: worktree-ticket-26" "$TMP_DIR/clean-gone.out"
assert_eq "" "$(state_of "$SID")" "dxclean without a worktree leaves no phase, run ID or runtime"
assert_eq "runtime-lock" "$(lock_of "$SID")" "dxclean without a worktree keeps the lock as dxrm does"

SID=$(seed_gone_branch ticket-27 worktree-ticket-27 live)
dxclean_out "$TMP_DIR/clean-gone-live.out"
assert_contains "Deleting orphan branch: worktree-ticket-27" "$TMP_DIR/clean-gone-live.out"
assert_eq "runtime" "$(state_of "$SID")" "dxclean keeps a live runtime's lease"

# A renamed branch reaches dxclean only through the session record. A finished
# lifecycle has no active phase, so dxclean does not skip it.
SID=$(seed_gone_branch ticket-28 b8-renamed-28 finished)
TEST_SID="$SID" dx_zsh 'dx_meta_write "$TEST_SID" current_branch=b8-renamed-28'
rm -f "$DX_STATE_DIR/$SID.phase"
dxclean_out "$TMP_DIR/clean-renamed.out"
assert_contains "Deleting orphan branch: b8-renamed-28" "$TMP_DIR/clean-renamed.out"
assert_eq "" "$(state_of "$SID")" "dxclean on a renamed branch leaves no run ID or runtime"
assert_eq "runtime-lock" "$(lock_of "$SID")" "dxclean on a renamed branch keeps the lock as dxrm does"

# ── #86: end-of-run teardown releases the run's own runtime lease ─────────
# A completed lifecycle tears its workspace down inside its own runtime
# wrapper, while the supervisor still holds the lease. Teardown finishes that
# lease first, so the session cleanup takes .runtime with it.
export DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS=100
export DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS=5000
export DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=5000
export TEST_OTHER_DIR="$TMP_DIR/other-checkout"
git init -q -b main "$TEST_OTHER_DIR"
git -C "$TEST_OTHER_DIR" config user.email dex@example.test
git -C "$TEST_OTHER_DIR" config user.name "Dex Test"
git -C "$TEST_OTHER_DIR" commit -q --allow-empty -m init

# teardown_in_run <name> <worktree|in-place> <own|other> <none|int|term|exit> <out>
# Complete <name> inside a runtime wrapper and print the wrapper's status. The
# wrapper owns <name>'s session (own) or an unrelated one (other). After the
# teardown the callback continues as <after> says.
teardown_in_run() {
  local rc=0
  TEST_WT_NAME="$1" TEST_MODE="$2" TEST_OWNER="$3" TEST_AFTER="$4" dx_zsh '
    __dx_resolved_provider_agent() { print -r -- claude; }
    sid=$(__dx_session_id_for_workspace "$TEST_MODE" "$TEST_WT_NAME")
    wt_dir="$TEST_REPO"
    [[ "$TEST_MODE" != worktree ]] || wt_dir="$TEST_REPO/.dex/worktrees/$TEST_WT_NAME"
    dx_meta_write "$sid" "wt_name=$TEST_WT_NAME" "wt_dir=$wt_dir" "workspace_mode=$TEST_MODE"
    dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7
    run_sid="$sid" run_dir="$wt_dir"
    [[ "$TEST_OWNER" != other ]] || { run_sid=other-86; run_dir="$TEST_OTHER_DIR"; }
    __test_teardown() {
      __dx_cleanup_completed_workspace "$TEST_WT_NAME" "$wt_dir" main "$TEST_MODE" "$sid" \
        || return $?
      case "$TEST_AFTER" in
        int) kill -INT $$ ;;
        term) kill -TERM $$ ;;
        exit) exit 0 ;;
      esac
      __dx_runtime_set_terminal completed
    }
    __dx_run_with_runtime "$run_sid" "$run_dir" __test_teardown
  ' > "$5" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# (a) A worktree lifecycle: no .runtime afterwards, the lock stays, no warning.
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-41" -b worktree-ticket-41 HEAD
SID=$(dx_zsh '__dx_session_id_for_workspace worktree ticket-41')
rc=$(teardown_in_run ticket-41 worktree own none "$TMP_DIR/own-worktree.out")
[[ "$rc" == 0 ]] || { cat "$TMP_DIR/own-worktree.out" >&2; fail "worktree teardown in its own run exited $rc"; }
[[ ! -d "$TEST_REPO/.dex/worktrees/ticket-41" ]] || fail "the completed worktree was kept"
assert_eq "" "$(state_of "$SID")" "a finished worktree lifecycle leaves no .runtime"
assert_eq "runtime-lock" "$(lock_of "$SID")" "the persistent runtime lock outlives the teardown"
assert_not_contains "still live or not finished" "$TMP_DIR/own-worktree.out"
assert_not_contains "could not close the runtime lease" "$TMP_DIR/own-worktree.out"

# (b) An in-place lifecycle: the checkout goes back to main, no .runtime.
git -C "$TEST_REPO" switch -q -c b9-inplace-42
SID=$(dx_zsh '__dx_session_id_for_workspace in-place inplace-42')
rc=$(teardown_in_run inplace-42 in-place own none "$TMP_DIR/own-inplace.out")
[[ "$rc" == 0 ]] || { cat "$TMP_DIR/own-inplace.out" >&2; fail "in-place teardown in its own run exited $rc"; }
assert_eq main "$(git -C "$TEST_REPO" branch --show-current)" "in-place teardown switched back to main"
assert_eq "" "$(state_of "$SID")" "a finished in-place lifecycle leaves no .runtime"
assert_not_contains "still live or not finished" "$TMP_DIR/own-inplace.out"

# (c) A run tearing down a workspace whose runtime is live in another process
# keeps that runtime, and says so.
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-43" -b worktree-ticket-43 HEAD
SID=$(seed_run ticket-43 7 live)
rc=$(teardown_in_run ticket-43 worktree other none "$TMP_DIR/other-live.out")
[[ "$rc" == 0 ]] || { cat "$TMP_DIR/other-live.out" >&2; fail "teardown from another run exited $rc"; }
assert_eq "runtime" "$(state_of "$SID")" "a runtime live elsewhere keeps its lease"
assert_contains "is still live or not finished" "$TMP_DIR/other-live.out"

# (e) Once teardown has released the lease, the wrapper's INT, TERM and EXIT
# traps do nothing: no runtime comes back and no lease error is reported.
n=44
for after in int:130 term:143 exit:0; do
  git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-$n" -b "worktree-ticket-$n" HEAD
  SID=$(dx_zsh "__dx_session_id_for_workspace worktree ticket-$n")
  rc=$(teardown_in_run "ticket-$n" worktree own "${after%%:*}" "$TMP_DIR/trap-$n.out")
  assert_eq "${after#*:}" "$rc" "${after%%:*} after the release keeps its own exit status"
  assert_eq "" "$(state_of "$SID")" "${after%%:*} after the release brings no .runtime back"
  assert_not_contains "could not close the runtime lease" "$TMP_DIR/trap-$n.out"
  assert_not_contains "still live or not finished" "$TMP_DIR/trap-$n.out"
  n=$((n + 1))
done

printf 'session stale run tests passed\n'
