#!/usr/bin/env bash
# End-to-end teardown through Dex's public paths: Phase 6 completion
# (__dx_cleanup_completed_workspace), dxrm, dxclean and the sweep at dx start,
# against a bare origin and a stubbed gh that reports merged pull requests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-teardown-lifecycle-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEX_HOME="$TMP_DIR/dex-home"
unset DX_STATE_DIR DX_LOOP_DIR DX_ARTIFACT_DIR DX_TOOL_DIR DX_RUN_ROOT DX_RESCUE_DIR DX_PATHS_FROM
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
export GH_STUB_DIR="$TMP_DIR/gh"
export TEST_REPO="$TMP_DIR/repo"
mkdir -p "$HOME" "$GH_STUB_DIR/merged" "$TMP_DIR/bin"
git config --global user.email dex@example.test
git config --global user.name "Dex Test"
git config --global init.defaultBranch main

# gh pr list --state merged --head <branch> ... prints the head recorded in
# $GH_STUB_DIR/merged/<branch with / as _>, or nothing; $GH_STUB_DIR/fail
# makes every call fail. Every call is logged.
cat >"$TMP_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls"
[[ ! -e "$GH_STUB_DIR/fail" ]] || exit 1
head=""
while [[ $# -gt 0 ]]; do
  case "$1" in --head) head="$2"; shift ;; esac
  shift
done
file="$GH_STUB_DIR/merged/${head//\//_}"
if [[ -f "$file" ]]; then cat "$file"; else printf '\n'; fi
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

# dxz <script> — run zsh with dx.sh loaded, from the repository root.
dxz() {
  zsh -fc 'source "$DEX_DIR/dx.sh"; cd "$TEST_REPO"; '"$1"
}

# set_teardown <yaml-lines>
set_teardown() {
  mkdir -p "$TEST_REPO/.dex"
  printf '# Project\n\n## Worktree Teardown\n\n```yaml\n%s\n```\n' "$1" >"$TEST_REPO/.dex/dex.md"
}

# lifecycle <wt-name> <branch> — a worktree lifecycle at Phase 7 with one
# pushed commit on <branch>, recorded the way setup and Phase 0 record it.
lifecycle() {
  local name="$1" branch="$2" wt="$TEST_REPO/.dex/worktrees/$1"
  git -C "$TEST_REPO" worktree add -q "$wt" -b "$branch" main
  git -C "$wt" commit -q --allow-empty -m "work on $name"
  git -C "$wt" push -q -u origin "$branch"
  NAME="$name" WT="$wt" BRANCH="$branch" dxz '
    sid=$(dx_session_id "$NAME")
    dx_meta_write "$sid" "wt_name=$NAME" "wt_dir=$WT" workspace_mode=worktree "current_branch=$BRANCH"
    dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7'
}

# complete <wt-name> — Phase 6's local cleanup for that lifecycle.
complete() {
  NAME="$1" dxz '__dx_cleanup_completed_workspace "$NAME" "$TEST_REPO/.dex/worktrees/$NAME" main worktree "$(dx_session_id "$NAME")"'
}

merged() { git -C "$TEST_REPO" rev-parse "$1" >"$GH_STUB_DIR/merged/${1//\//_}"; }
has_branch() { git -C "$TEST_REPO" show-ref --verify --quiet "refs/heads/$1"; }
has_remote_branch() { git -C "$TMP_DIR/origin.git" show-ref --verify --quiet "refs/heads/$1"; }
rescue_count() { find "$DEX_HOME/rescue" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

# 1. Default (on_complete, rescue): completion rescues an untracked file and an
#    edit, removes the worktree and deletes the pushed, renamed branch.
lifecycle ticket-1 feat/one
printf 'notes\n' >"$TEST_REPO/.dex/worktrees/ticket-1/notes.txt"
printf 'edit\n' >>"$TEST_REPO/.dex/worktrees/ticket-1/README.md"
complete ticket-1 >"$TMP_DIR/out" 2>&1 || fail "completion failed: $(cat "$TMP_DIR/out")"
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-1" ]] || fail "worktree kept"
! has_branch feat/one || fail "pushed branch kept"
assert_eq 1 "$(rescue_count)" "one rescue directory, under DEX_HOME"
rescued=$(find "$DEX_HOME/rescue" -path '*ticket-1-*/untracked/notes.txt' | head -1)
[[ -n "$rescued" ]] || fail "untracked file was not rescued"
assert_contains "+edit" "$(dirname "$(dirname "$rescued")")/tracked.patch"

# 2. refuse + an unpushed commit: completion keeps the worktree and branch.
set_teardown 'teardown_untracked: refuse'
lifecycle ticket-2 feat/two
git -C "$TEST_REPO/.dex/worktrees/ticket-2" commit -q --allow-empty -m "not pushed"
complete ticket-2 >"$TMP_DIR/out" 2>&1 && fail "completion claimed a refused cleanup"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-2" ]] || fail "refuse removed the worktree"
has_branch feat/two || fail "refuse deleted the branch"
assert_contains "commit(s) on feat/two that exist nowhere else" "$TMP_DIR/out"

# 3. rescue + an unpushed commit: the worktree goes, the branch stays.
set_teardown 'teardown_untracked: rescue'
complete ticket-2 >"$TMP_DIR/out" 2>&1 || true
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-2" ]] || fail "rescue mode kept the worktree"
has_branch feat/two || fail "branch with an unpushed commit was deleted"
assert_contains "Kept local branch feat/two: 1 commit(s) exist only on it" "$TMP_DIR/out"

# 4. on_merge: completion keeps the worktree; dxclean keeps it while the pull
#    request is open and while gh fails; once merged (squash: the remote
#    branch is deleted and the tip is on no remote), dxclean removes the
#    worktree and the renamed branch.
set_teardown 'worktree_teardown: on_merge'
lifecycle ticket-3 feat/three
complete ticket-3 >"$TMP_DIR/out" 2>&1 || fail "on_merge completion failed"
assert_contains "Kept ticket-3 until its pull request merges" "$TMP_DIR/out"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-3" ]] || fail "on_merge removed at completion"
assert_eq "on_merge|feat/three" "$(dxz 'sid=$(dx_session_id ticket-3); print -r -- "$(dx_meta_read "$sid" teardown_deferred)|$(dx_meta_read "$sid" teardown_branch)"')" "deferral recorded"
dxz dxclean >"$TMP_DIR/out" 2>&1
[[ -d "$TEST_REPO/.dex/worktrees/ticket-3" ]] || fail "dxclean removed an unmerged on_merge worktree"
assert_contains "Skipping ticket-3 (waiting for its pull request to merge)" "$TMP_DIR/out"
assert_contains "Kept 1 rescued worktree copy(ies)" "$TMP_DIR/out"
touch "$GH_STUB_DIR/fail"
dxz dxclean >"$TMP_DIR/out" 2>&1
rm -f "$GH_STUB_DIR/fail"
[[ -d "$TEST_REPO/.dex/worktrees/ticket-3" ]] || fail "dxclean removed a worktree without a confirmed merge"
assert_contains "Could not confirm whether feat/three has merged" "$TMP_DIR/out"
merged feat/three
git -C "$TEST_REPO" push -q origin --delete feat/three
git -C "$TEST_REPO" fetch -q --prune
dxz dxclean >"$TMP_DIR/out" 2>&1
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-3" ]] || fail "dxclean kept a merged on_merge worktree: $(cat "$TMP_DIR/out")"
! has_branch feat/three || fail "merged renamed branch kept"
assert_eq "" "$(dxz 'dx_meta_read "$(dx_session_id ticket-3)" teardown_deferred')" "session state cleaned"

# 5. The sweep also runs when the next lifecycle starts, and deletes the
#    remote branch after the merge when asked to.
set_teardown $'worktree_teardown: on_merge\ndelete_remote_branch_on_merge: true'
lifecycle ticket-4 feat/four
complete ticket-4 >/dev/null 2>&1
has_remote_branch feat/four || fail "remote branch missing before merge"
merged feat/four
# Stop dx right after the sweep: setup is not under test here.
dxz '__dx_setup_worktree() { return 1; }; dx 99' >"$TMP_DIR/out" 2>&1 || true
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-4" ]] || fail "dx start did not sweep: $(cat "$TMP_DIR/out")"
! has_branch feat/four || fail "local branch kept after merge"
! has_remote_branch feat/four || fail "remote branch kept with delete_remote_branch_on_merge: true"

# 6. caller: completion and dxclean keep the worktree; dxrm removes it.
set_teardown 'worktree_teardown: caller'
lifecycle ticket-5 feat/five
merged feat/five
complete ticket-5 >"$TMP_DIR/out" 2>&1 || fail "caller completion failed"
assert_contains "Run dxrm ticket-5 after the pull request merges" "$TMP_DIR/out"
dxz dxclean >"$TMP_DIR/out" 2>&1
[[ -d "$TEST_REPO/.dex/worktrees/ticket-5" ]] || fail "dxclean removed a caller worktree"
assert_contains "Skipping ticket-5 (kept for the caller" "$TMP_DIR/out"
has_remote_branch feat/five || assert_at $LINENO
dxz 'dxrm ticket-5' >"$TMP_DIR/out" 2>&1 || fail "dxrm failed: $(cat "$TMP_DIR/out")"
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-5" ]] || fail "dxrm kept a caller worktree"
! has_branch feat/five || fail "dxrm kept the renamed branch"
has_remote_branch feat/five || fail "remote branch deleted with the setting off"

# 7. dxrm finds a renamed branch from session records when the worktree
#    directory is already gone.
set_teardown 'teardown_untracked: rescue'
lifecycle ticket-6 feat/six
git -C "$TEST_REPO" worktree remove --force "$TEST_REPO/.dex/worktrees/ticket-6"
dxz 'dxrm ticket-6' >"$TMP_DIR/out" 2>&1 || true
! has_branch feat/six || fail "dxrm left a renamed branch whose directory was gone: $(cat "$TMP_DIR/out")"

# 8. dxclean's gone-branch pass follows renamed branches it has a record of,
#    and leaves branches Dex knows nothing about.
lifecycle ticket-7 feat/seven
git -C "$TEST_REPO" worktree remove --force "$TEST_REPO/.dex/worktrees/ticket-7"
git -C "$TEST_REPO" branch stranger feat/seven
git -C "$TEST_REPO" push -q -u origin stranger
git -C "$TEST_REPO" push -q origin --delete feat/seven stranger
git -C "$TEST_REPO" fetch -q --prune
dxz dxclean >"$TMP_DIR/out" 2>&1
! has_branch feat/seven || fail "gone renamed branch kept: $(cat "$TMP_DIR/out")"
assert_contains "Deleting gone branch: feat/seven" "$TMP_DIR/out"
has_branch stranger || fail "dxclean deleted a branch Dex has no record of"

# 9. In place, on_merge keeps the branch; after the merge the sweep switches
#    a clean checkout back to main and deletes the branch.
set_teardown 'worktree_teardown: on_merge'
git -C "$TEST_REPO" add .dex/dex.md
git -C "$TEST_REPO" commit -q -m "teardown settings"
git -C "$TEST_REPO" push -q
git -C "$TEST_REPO" switch -q -c feat/inplace
git -C "$TEST_REPO" commit -q --allow-empty -m "in-place work"
git -C "$TEST_REPO" push -q -u origin feat/inplace
dxz '
  sid=$(__dx_session_id_for_workspace in-place inplace-9)
  dx_meta_write "$sid" wt_name=inplace-9 "wt_dir=$TEST_REPO" workspace_mode=in-place current_branch=feat/inplace
  dx_lifecycle_atomic_write "$(dx_state_file "$sid")" 7
  __dx_cleanup_completed_workspace inplace-9 "$TEST_REPO" main in-place "$sid"' >"$TMP_DIR/out" 2>&1 \
  || fail "in-place on_merge completion failed: $(cat "$TMP_DIR/out")"
assert_eq feat/inplace "$(git -C "$TEST_REPO" branch --show-current)" "in-place branch kept at completion"
merged feat/inplace
dxz dxclean >"$TMP_DIR/out" 2>&1
assert_eq main "$(git -C "$TEST_REPO" branch --show-current)" "sweep switched back to main"
! has_branch feat/inplace || fail "in-place branch kept after merge: $(cat "$TMP_DIR/out")"

# 10. gh matches a head branch by name only: a pull request merged earlier from
#     the same branch name does not tear down a lifecycle whose work it lacks.
set_teardown 'worktree_teardown: on_merge'
lifecycle ticket-8 feat/eight
complete ticket-8 >/dev/null 2>&1
git -C "$TEST_REPO" rev-parse main >"$GH_STUB_DIR/merged/feat_eight"
dxz dxclean >"$TMP_DIR/out" 2>&1
[[ -d "$TEST_REPO/.dex/worktrees/ticket-8" ]] || fail "an earlier merge of the same branch name removed the worktree"
has_branch feat/eight || assert_at $LINENO
assert_contains "Kept ticket-8: feat/eight has commits its merged pull request does not" "$TMP_DIR/out"

# 11. A worktree the teardown gate keeps is not a dxclean failure. Files under
#     a real .claude directory are hidden from git status by Dex's exclude, so
#     dxclean reaches the gate, which refuses under teardown_untracked: refuse.
set_teardown 'teardown_untracked: refuse'
lifecycle ticket-11 feat/eleven
WT="$TEST_REPO/.dex/worktrees/ticket-11" dxz 'dx_exclude_claude_artifacts "$WT"'
mkdir -p "$TEST_REPO/.dex/worktrees/ticket-11/.claude"
printf 'notes\n' >"$TEST_REPO/.dex/worktrees/ticket-11/.claude/notes.md"
dxz dxclean >"$TMP_DIR/out" 2>&1 || fail "dxclean failed on a worktree the gate kept: $(cat "$TMP_DIR/out")"
[[ -f "$TEST_REPO/.dex/worktrees/ticket-11/.claude/notes.md" ]] || fail "dxclean removed a refused worktree"
assert_contains "Kept ticket-11" "$TMP_DIR/out"
assert_not_contains "Failed to remove stale worktree ticket-11" "$TMP_DIR/out"

# 12. The sweep leaves a deferred lifecycle that was reopened (phase 0-6),
#     even after its pull request merged.
set_teardown 'worktree_teardown: on_merge'
lifecycle ticket-12 feat/twelve
complete ticket-12 >/dev/null 2>&1
merged feat/twelve
dxz 'dx_lifecycle_atomic_write "$(dx_state_file "$(dx_session_id ticket-12)")" 3'
dxz dxclean >"$TMP_DIR/out" 2>&1
[[ -d "$TEST_REPO/.dex/worktrees/ticket-12" ]] || fail "the sweep removed a reopened lifecycle: $(cat "$TMP_DIR/out")"
has_branch feat/twelve || assert_at $LINENO
dxz 'dxrm ticket-12' >/dev/null 2>&1 || assert_at $LINENO

# 13. dxrm --all goes through the same gate: refuse keeps a worktree with an
#     untracked file, rescue copies the file out and removes it.
set_teardown 'teardown_untracked: refuse'
git -C "$TEST_REPO" worktree add -q "$TEST_REPO/.dex/worktrees/ticket-13" -b worktree-ticket-13 main
printf 'draft\n' >"$TEST_REPO/.dex/worktrees/ticket-13/draft.txt"
dxz 'dxrm --all' >"$TMP_DIR/out" 2>&1 || true
[[ -f "$TEST_REPO/.dex/worktrees/ticket-13/draft.txt" ]] || fail "dxrm --all removed a refused worktree"
assert_contains "Some worktrees were kept" "$TMP_DIR/out"
set_teardown 'teardown_untracked: rescue'
before=$(rescue_count)
dxz 'dxrm --all' >"$TMP_DIR/out" 2>&1 || fail "dxrm --all failed: $(cat "$TMP_DIR/out")"
[[ ! -e "$TEST_REPO/.dex/worktrees/ticket-13" ]] || fail "dxrm --all kept a rescued worktree"
assert_eq "$((before + 1))" "$(rescue_count)" "dxrm --all rescued the untracked file"
[[ -n "$(find "$DEX_HOME/rescue" -path '*ticket-13-*/untracked/draft.txt' | head -1)" ]] || assert_at $LINENO

# Nothing above wrote outside the sandbox's DEX_HOME and repository.
[[ ! -e "$HOME/.dex" && ! -e "$HOME/.claude/.dex-phases" ]] || fail "state written outside DEX_HOME"

printf 'worktree-teardown-lifecycle-test: ok\n'
