#!/usr/bin/env bash
# ticket_close end to end through Dex's public paths: Phase 6 completion
# (__dx_cleanup_completed_workspace), the deferred-teardown sweep at dx start
# and in dxclean, against a bare origin and a stubbed gh that records every
# call. Each mode must make exactly the tracker calls it promises.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ticket-close-sweep-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEX_HOME="$TMP_DIR/dex-home"
unset DX_STATE_DIR DX_LOOP_DIR DX_ARTIFACT_DIR DX_TOOL_DIR DX_RUN_ROOT DX_RESCUE_DIR DX_PATHS_FROM
unset DEX_TICKET_CLOSE
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
export GH_STUB_DIR="$TMP_DIR/gh"
export TEST_REPO="$TMP_DIR/repo"
mkdir -p "$HOME" "$GH_STUB_DIR/issues" "$TMP_DIR/bin"
git config --global user.email dex@example.test
git config --global user.name "Dex Test"
git config --global init.defaultBranch main

# A stub gh. Every call is appended to $GH_STUB_DIR/calls.
#   pr view <branch> --json number,headRefOid   prints "<number> <head>" from
#                                               $GH_STUB_DIR/pr-number, pr-head
#   pr view <n> --json state,headRefOid         prints "<state> <head>" from
#                                               $GH_STUB_DIR/pr-state, pr-head
#   pr list --state merged --head <branch>      prints pr-head when pr-state
#                                               is MERGED
#   issue view <n> --json state                 prints issues/<n>, else OPEN
#   issue close <n>                             records CLOSED in issues/<n>
# $GH_STUB_DIR/fail fails every call; close-fail fails issue close.
cat >"$TMP_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls"
[[ ! -e "$GH_STUB_DIR/fail" ]] || exit 1
read_stub() { cat "$GH_STUB_DIR/$1" 2>/dev/null || true; }
case "$1 $2" in
  "pr view")
    case "$*" in
      *number,headRefOid*)
        [[ -s "$GH_STUB_DIR/pr-number" ]] || exit 1
        printf '%s %s\n' "$(read_stub pr-number)" "$(read_stub pr-head)" ;;
      *) printf '%s %s\n' "$(read_stub pr-state)" "$(read_stub pr-head)" ;;
    esac ;;
  "pr list")
    if [[ "$(read_stub pr-state)" == MERGED ]]; then read_stub pr-head; else printf '\n'; fi ;;
  "issue view")
    if [[ -s "$GH_STUB_DIR/issues/$3" ]]; then cat "$GH_STUB_DIR/issues/$3"; else printf 'OPEN\n'; fi ;;
  "issue close")
    [[ ! -e "$GH_STUB_DIR/close-fail" ]] || exit 1
    printf 'CLOSED\n' >"$GH_STUB_DIR/issues/$3" ;;
  *) exit 64 ;;
esac
GH
chmod +x "$TMP_DIR/bin/gh"
export PATH="$TMP_DIR/bin:$PATH"

git init -q --bare "$TMP_DIR/origin.git"
git init -q "$TEST_REPO"
printf '# repo\n' >"$TEST_REPO/README.md"
git -C "$TEST_REPO" add README.md
git -C "$TEST_REPO" commit -q -m init
git -C "$TEST_REPO" remote add origin "$TMP_DIR/origin.git"
git -C "$TEST_REPO" push -q -u origin main
git -C "$TEST_REPO" remote set-head origin main
# .dex/ (config and worktrees) is not part of the work under test: keep it out
# of `git status`, as a real project's committed config and ignored worktrees
# are.
printf '.dex/\n' >>"$TEST_REPO/.git/info/exclude"

# dxz <script> — run zsh with dx.sh loaded, from the repository root.
dxz() {
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; '"$1"
}

# set_dex <tracker> <tickets-yaml> [teardown-yaml]
set_dex() {
  mkdir -p "$TEST_REPO/.dex"
  {
    printf '# Project\n\n## Integrations\n\n| Integration | Tool | Status |\n|---|---|---|\n'
    printf '| Ticket tracker | %s | enabled |\n\n' "$1"
    printf '## Tickets\n\n```yaml\n%s\n```\n' "$2"
    if [[ -n "${3:-}" ]]; then
      printf '\n## Worktree Teardown\n\n```yaml\n%s\n```\n' "$3"
    fi
  } >"$TEST_REPO/.dex/dex.md"
}

# lifecycle <wt-name> <branch> <ticket> — a worktree lifecycle at Phase 7 with
# one pushed commit on <branch>, recorded the way setup records it.
lifecycle() {
  local name="$1" branch="$2" ticket="$3" wt="$TEST_REPO/.dex/worktrees/$1"
  git -C "$TEST_REPO" worktree add -q "$wt" -b "$branch" main
  git -C "$wt" commit -q --allow-empty -m "work on $name"
  git -C "$wt" push -q -u origin "$branch"
  NAME="$name" WT="$wt" BRANCH="$branch" TICKET="$ticket" dxz '
    sid=$(dx_session_id "$NAME")
    dx_meta_write "$sid" "wt_name=$NAME" "wt_dir=$WT" workspace_mode=worktree \
      "current_branch=$BRANCH" "ticket_id=$TICKET" "ticket_number=${TICKET##*-}"
    dx_ticket_close_snapshot "$sid" "$TEST_REPO"
    dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7'
}

# complete <wt-name> — Phase 6's local cleanup for that lifecycle.
complete() {
  NAME="$1" dxz '__dx_cleanup_completed_workspace "$NAME" "$TEST_REPO/.dex/worktrees/$NAME" main worktree "$(dx_session_id "$NAME")"'
}

meta() { NAME="$1" KEY="$2" dxz 'dx_meta_read "$(dx_session_id "$NAME")" "$KEY"'; }
meta_file() { NAME="$1" dxz 'dx_meta_file "$(dx_session_id "$NAME")"'; }
sweep() { dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"'; }
issue_calls() {
  if [[ -f "$GH_STUB_DIR/calls" ]]; then grep -c '^issue ' "$GH_STUB_DIR/calls" || true; else echo 0; fi
}
reset_gh() {
  rm -f "$GH_STUB_DIR/calls" "$GH_STUB_DIR/fail" "$GH_STUB_DIR/close-fail" \
    "$GH_STUB_DIR/pr-number" "$GH_STUB_DIR/pr-state" "$GH_STUB_DIR/pr-head" "$GH_STUB_DIR/issues/"*
}
# open_pr <number> <branch> — GitHub has an open pull request for <branch>.
open_pr() {
  printf '%s\n' "$1" >"$GH_STUB_DIR/pr-number"
  git -C "$TEST_REPO" rev-parse "$2" >"$GH_STUB_DIR/pr-head"
  printf 'OPEN\n' >"$GH_STUB_DIR/pr-state"
}
pr_state() { printf '%s\n' "$1" >"$GH_STUB_DIR/pr-state"; }

# 1. on_complete (the default): completion records nothing and makes no
#    tracker call; Phase 6 itself marks the ticket Done.
set_dex 'GitHub Issues (`gh`)' 'ticket_prefixes: [ENG]'
reset_gh
lifecycle ticket-1 feat/one 1
open_pr 101 feat/one
complete ticket-1 >"$TMP_DIR/out" 2>&1 || fail "completion failed: $(cat "$TMP_DIR/out")"
[[ ! -e "$(meta_file ticket-1)" ]] || fail "on_complete kept a session record"
assert_eq 0 "$(issue_calls)" "on_complete makes no issue call"
if grep -q '^pr view' "$GH_STUB_DIR/calls" 2>/dev/null; then fail "on_complete looked up the pull request"; fi

# 2. never: no record, no tracker call, at completion or in the sweep.
set_dex 'GitHub Issues (`gh`)' 'ticket_close: never'
reset_gh
lifecycle ticket-2 feat/two 2
open_pr 102 feat/two
complete ticket-2 >"$TMP_DIR/out" 2>&1 || fail "completion failed: $(cat "$TMP_DIR/out")"
[[ ! -e "$(meta_file ticket-2)" ]] || fail "never kept a session record"
pr_state MERGED
sweep >/dev/null 2>&1
assert_eq 0 "$(issue_calls)" "never makes no issue call"

# 3. on_merge with worktree_teardown: on_complete: the worktree goes at
#    completion, and a .meta holding only the ticket close stays.
set_dex 'GitHub Issues (`gh`)' 'ticket_close: on_merge'
reset_gh
lifecycle ticket-3 feat/three 3
open_pr 103 feat/three
NAME=ticket-3 dxz 'dx_ticket_close_items_add "$(dx_session_id "$NAME")" 31 32 31'
complete ticket-3 >"$TMP_DIR/out" 2>&1 || fail "completion failed: $(cat "$TMP_DIR/out")"
assert_contains "Recorded 3,31,32 to close when pull request #103 merges" "$TMP_DIR/out"
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-3" ]] || fail "on_merge ticket close kept the worktree"
[[ -f "$(meta_file ticket-3)" ]] || fail "the ticket-close record did not survive teardown"
assert_eq on_merge "$(meta ticket-3 ticket_close_pending)" "pending ticket close"
assert_eq 3,31,32 "$(meta ticket-3 ticket_close_items)" "parent then sub-issues, once each"
assert_eq github "$(meta ticket-3 ticket_close_tracker)" "tracker kind"
assert_eq 103 "$(meta ticket-3 ticket_close_pr)" "pull request number"
# Only the record survives: no wt_dir, branch, phase or other session state.
if grep -Eqv '^(ticket_close_[a-z_]+|wt_name|ticket_id|created_at|updated_at)=' "$(meta_file ticket-3)"; then
  fail "the kept .meta holds more than the ticket close: $(cat "$(meta_file ticket-3)")"
fi
assert_eq 0 "$(issue_calls)" "completion closes nothing"
# The kept record is not a session: dx sessions does not list it.
dxz 'dx sessions list' >"$TMP_DIR/sessions" 2>&1 || true
assert_not_contains "ticket-3" "$TMP_DIR/sessions"

# 3a. Pull request still open: the sweep keeps the record and closes nothing.
sweep >/dev/null 2>&1
assert_eq 0 "$(issue_calls)" "open pull request: no issue call"
assert_eq on_merge "$(meta ticket-3 ticket_close_pending)" "record kept while open"

# 3b. gh fails: kept, with a message saying so.
touch "$GH_STUB_DIR/fail"
dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"' >/dev/null 2>"$TMP_DIR/err"
rm -f "$GH_STUB_DIR/fail"
assert_contains "Could not confirm whether pull request #103 merged" "$TMP_DIR/err"
assert_eq on_merge "$(meta ticket-3 ticket_close_pending)" "record kept when gh fails"

# 3c. Merged, one sub-issue already closed by the PR's closing keyword, and the
#     close of another fails: the open ones are tried, the record is kept.
pr_state MERGED
printf 'CLOSED\n' >"$GH_STUB_DIR/issues/31"
touch "$GH_STUB_DIR/close-fail"
dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"' >/dev/null 2>"$TMP_DIR/err"
rm -f "$GH_STUB_DIR/close-fail"
assert_contains "Could not close every ticket in 3,31,32" "$TMP_DIR/err"
assert_eq on_merge "$(meta ticket-3 ticket_close_pending)" "record kept after a failed close"

# 3d. The next sweep closes what is still open, exactly once each, and drops
#     the record.
: >"$GH_STUB_DIR/calls"
dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"' >/dev/null 2>"$TMP_DIR/err"
assert_contains "pr view 103 --json state,headRefOid" "$GH_STUB_DIR/calls"
assert_contains "issue close 3 --reason completed --comment Closed by Dex: pull request #103 merged (ticket_close: on_merge)." "$GH_STUB_DIR/calls"
assert_contains "issue close 32 --reason completed" "$GH_STUB_DIR/calls"
if grep -q '^issue close 31' "$GH_STUB_DIR/calls"; then fail "closed an issue that was already closed"; fi
assert_eq 2 "$(grep -c '^issue close' "$GH_STUB_DIR/calls")" "two closes"
assert_contains "Closed #3: pull request #103 merged" "$TMP_DIR/err"
[[ ! -e "$(meta_file ticket-3)" ]] || fail "the settled record was not dropped"
: >"$GH_STUB_DIR/calls"
sweep >/dev/null 2>&1
assert_eq 0 "$(issue_calls)" "a settled record is not swept again"

# 4. on_merge, pull request closed without merging: nothing closed, record
#    dropped, and the sweep says the ticket was left open.
reset_gh
lifecycle ticket-4 feat/four 4
open_pr 104 feat/four
complete ticket-4 >/dev/null 2>&1
pr_state CLOSED
dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"' >/dev/null 2>"$TMP_DIR/err"
assert_contains "pull request #104 was closed without merging; left 4 open" "$TMP_DIR/err"
assert_eq 0 "$(issue_calls)" "unmerged close: no issue call"
[[ ! -e "$(meta_file ticket-4)" ]] || fail "record kept after the pull request closed unmerged"

# 5. on_merge with no pull request found at completion: the sweep falls back
#    to the branch name and counts the merge only when it holds the recorded
#    head.
reset_gh
lifecycle ticket-5 feat/five 5
complete ticket-5 >"$TMP_DIR/out" 2>&1
assert_contains "Recorded 5 to close when the pull request for feat/five merges" "$TMP_DIR/out"
assert_eq "" "$(meta ticket-5 ticket_close_pr)" "no pull request number"
# A merged pull request from the same branch name that lacks this work.
pr_state MERGED
git -C "$TEST_REPO" rev-parse main >"$GH_STUB_DIR/pr-head"
dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"' >/dev/null 2>"$TMP_DIR/err"
assert_contains "does not contain this lifecycle's work" "$TMP_DIR/err"
assert_eq 0 "$(issue_calls)" "older merge: no issue call"
# The real merge.
meta ticket-5 ticket_close_head >"$GH_STUB_DIR/pr-head"
assert_contains "pr list --state merged --head feat/five" "$GH_STUB_DIR/calls"
sweep >/dev/null 2>&1
assert_contains "issue close 5 --reason completed" "$GH_STUB_DIR/calls"
[[ ! -e "$(meta_file ticket-5)" ]] || fail "record kept after the merge"

# 6. on_merge on another tracker: no gh issue call, a reminder, record dropped.
set_dex 'Linear MCP' 'ticket_prefixes: [ENG]
ticket_close: on_merge'
reset_gh
lifecycle ticket-eng-6 feat/six ENG-6
open_pr 106 feat/six
complete ticket-eng-6 >/dev/null 2>&1
assert_eq other "$(meta ticket-eng-6 ticket_close_tracker)" "tracker kind"
pr_state MERGED
dxz '__dx_sweep_deferred_teardowns "$TEST_REPO"' >/dev/null 2>"$TMP_DIR/err"
assert_contains "pull request #106 merged: move ENG-6 to Done in your tracker" "$TMP_DIR/err"
assert_eq 0 "$(issue_calls)" "other tracker: no gh issue call"
[[ ! -e "$(meta_file ticket-eng-6)" ]] || fail "reminder record kept"

# 7. A lifecycle reopened for the same ticket (phase 0-6) is left alone even
#    with a pending close; a run override changes nothing already recorded.
set_dex 'GitHub Issues (`gh`)' 'ticket_close: on_merge'
reset_gh
lifecycle ticket-7 feat/seven 7
open_pr 107 feat/seven
complete ticket-7 >/dev/null 2>&1
NAME=ticket-7 dxz 'dx_lifecycle_atomic_write "$(dx_state_file "$(dx_session_id "$NAME")")" 2'
pr_state MERGED
sweep >/dev/null 2>&1
assert_eq 0 "$(issue_calls)" "reopened lifecycle: no issue call"
assert_eq on_merge "$(meta ticket-7 ticket_close_pending)" "reopened lifecycle keeps its record"

# 8. ticket_close: on_merge with worktree_teardown: on_merge: one sweep pass
#    closes the ticket and then tears the worktree down.
set_dex 'GitHub Issues (`gh`)' 'ticket_close: on_merge' 'worktree_teardown: on_merge'
reset_gh
lifecycle ticket-8 feat/eight 8
open_pr 108 feat/eight
complete ticket-8 >/dev/null 2>&1
[[ -d "$TEST_REPO/.dex/worktrees/ticket-8" ]] || fail "worktree_teardown: on_merge removed the worktree early"
assert_eq on_merge "$(meta ticket-8 teardown_deferred)" "teardown deferred"
assert_eq on_merge "$(meta ticket-8 ticket_close_pending)" "ticket close deferred"
pr_state MERGED
dxz 'dxclean' >"$TMP_DIR/out" 2>&1 || fail "dxclean failed: $(cat "$TMP_DIR/out")"
assert_contains "issue close 8 --reason completed" "$GH_STUB_DIR/calls"
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-8" ]] || fail "the merged worktree was kept"
[[ ! -e "$(meta_file ticket-8)" ]] || fail "the session record was kept"

# 9. Run override at completion time: DEX_TICKET_CLOSE=never recorded at launch
#    beats the project's on_merge.
reset_gh
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-9" -b feat/nine main
git -C "$TEST_REPO/.dex/worktrees/ticket-9" commit -q --allow-empty -m "work on ticket-9"
git -C "$TEST_REPO/.dex/worktrees/ticket-9" push -q -u origin feat/nine
DEX_TICKET_CLOSE=never NAME=ticket-9 WT="$TEST_REPO/.dex/worktrees/ticket-9" dxz '
  sid=$(dx_session_id "$NAME")
  dx_meta_write "$sid" "wt_name=$NAME" "wt_dir=$WT" workspace_mode=worktree ticket_id=9 ticket_number=9
  dx_ticket_close_snapshot "$sid" "$TEST_REPO"
  dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7'
open_pr 109 feat/nine
complete ticket-9 >/dev/null 2>&1
assert_eq never "$(meta ticket-9 ticket_close)" "the launch snapshot holds the override"
assert_eq "" "$(meta ticket-9 ticket_close_pending)" "run override never: no ticket close recorded"
if grep -q 'number,headRefOid' "$GH_STUB_DIR/calls" 2>/dev/null; then fail "never looked up the pull request"; fi

# 10. An in-place lifecycle (dx --no-worktree): completion releases the branch
#     and drops the session, and the ticket close survives it the same way.
set_dex 'GitHub Issues (`gh`)' 'ticket_close: on_merge'
reset_gh
git -C "$TEST_REPO" switch -q -c feat/ten main
git -C "$TEST_REPO" commit -q --allow-empty -m "work on ticket-10"
git -C "$TEST_REPO" push -q -u origin feat/ten
NAME=ticket-10 dxz '
  sid=$(dx_session_id "$NAME")
  dx_meta_write "$sid" "wt_name=$NAME" "wt_dir=$TEST_REPO" workspace_mode=in-place \
    current_branch=feat/ten ticket_id=10 ticket_number=10
  dx_ticket_close_snapshot "$sid" "$TEST_REPO"
  dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7'
open_pr 110 feat/ten
NAME=ticket-10 dxz '__dx_cleanup_completed_workspace "$NAME" "$TEST_REPO" main in-place "$(dx_session_id "$NAME")"' \
  >"$TMP_DIR/out" 2>&1 || fail "in-place completion failed: $(cat "$TMP_DIR/out")"
assert_contains "Recorded 10 to close when pull request #110 merges" "$TMP_DIR/out"
assert_eq main "$(git -C "$TEST_REPO" branch --show-current)" "in-place completion returned to main"
assert_eq on_merge "$(meta ticket-10 ticket_close_pending)" "in-place record survives completion"
assert_eq "" "$(meta ticket-10 wt_dir)" "only the ticket close is kept"
pr_state MERGED
sweep >/dev/null 2>&1
assert_contains "issue close 10 --reason completed" "$GH_STUB_DIR/calls"
[[ ! -e "$(meta_file ticket-10)" ]] || fail "in-place record kept after the merge"

# 11. dx sessions does not list a ticket-only record, but dx sessions forget
#     drops it by name, closing nothing. A selector that matches nothing still
#     fails.
reset_gh
lifecycle ticket-11 feat/eleven 11
open_pr 111 feat/eleven
complete ticket-11 >/dev/null 2>&1 || fail "ticket-11 completion failed"
assert_eq on_merge "$(meta ticket-11 ticket_close_pending)" "ticket-11 record kept"
dxz 'dx sessions forget ticket-11' >"$TMP_DIR/forget" 2>&1 \
  || fail "forget of a ticket-only record failed: $(cat "$TMP_DIR/forget")"
assert_contains "Dropped the pending ticket close" "$TMP_DIR/forget"
[[ ! -e "$(meta_file ticket-11)" ]] || fail "forget kept the ticket-only record"
assert_eq 0 "$(issue_calls)" "forget closes nothing"
if dxz 'dx sessions forget ticket-99' >"$TMP_DIR/forget" 2>&1; then
  fail "forget of an unknown selector succeeded"
fi
assert_contains "No session matches 'ticket-99'" "$TMP_DIR/forget"

# Nothing landed outside the sandbox: Dex state stays under DEX_HOME and the
# work in the repository; HOME is untouched.
if find "$HOME" -mindepth 1 | grep -q .; then
  fail "files written under HOME: $(find "$HOME" -mindepth 1)"
fi
[[ -n "$(find "$DEX_HOME" -name '*.meta')" ]] || fail "no session state under DEX_HOME"

printf 'ticket close sweep tests passed\n'
