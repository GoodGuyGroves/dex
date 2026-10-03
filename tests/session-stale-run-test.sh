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

# ── #29: dxrm takes the runtime lease with the session ─────────────────────
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-21" -b worktree-ticket-21 HEAD
SID=$(seed_run ticket-21 3 finished)
[[ "$(state_of "$SID")" == "phase run-id runtime" ]] || assert_at $LINENO
dx_zsh 'dxrm 21' > "$TMP_DIR/dxrm.out" 2>&1 || { cat "$TMP_DIR/dxrm.out" >&2; fail "dxrm 21 failed"; }
assert_eq "" "$(state_of "$SID")" "dxrm leaves no phase, run ID or runtime behind"

# A runtime whose owner is still running keeps its lease, and dxrm says so.
# Started outside this shell's job table, so stopping it at the end is quiet.
LIVE_PID=$(sleep 300 >/dev/null 2>&1 & printf '%s\n' "$!")
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-22" -b worktree-ticket-22 HEAD
SID=$(seed_run ticket-22 3 live)
dx_zsh 'dxrm 22' > "$TMP_DIR/dxrm-live.out" 2>&1 || true
assert_eq "runtime" "$(state_of "$SID")" "a live runtime keeps its lease; the rest goes"
assert_contains "is still live or not finished" "$TMP_DIR/dxrm-live.out"

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

printf 'session stale run tests passed\n'
