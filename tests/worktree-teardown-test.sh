#!/usr/bin/env bash
# Library-level checks for safe worktree teardown (lib/teardown.sh): the
# `## Worktree Teardown` settings, the unpushed-commit count, safe branch
# deletion, the rescue copy, and the gate dx_wt_remove runs before removing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-teardown-test.XXXXXX")"
trap 'chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RESCUE_DIR="$TMP_DIR/rescue"
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"
git config --global user.email dex@example.test
git config --global user.name "Dex Test"
git config --global init.defaultBranch main
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# new_repo <dir> — a repository with one commit on main and a bare origin.
new_repo() {
  local repo="$1"
  git init -q --bare "${repo}.git"
  git init -q "$repo"
  printf '# repo\n' >"$repo/README.md"
  printf 'ignored/\n*.log\n' >"$repo/.gitignore"
  git -C "$repo" add README.md .gitignore
  git -C "$repo" commit -q -m init
  git -C "$repo" remote add origin "${repo}.git"
  git -C "$repo" push -q -u origin main
}

# set_teardown <repo> <yaml-lines> — write a `## Worktree Teardown` block.
set_teardown() {
  mkdir -p "$1/.dex"
  printf '# Project\n\n## Worktree Teardown\n\n```yaml\n%s\n```\n' "$2" >"$1/.dex/dex.md"
}

# --- settings ---------------------------------------------------------------
REPO="$TMP_DIR/settings"
new_repo "$REPO"
assert_eq on_complete "$(dx_teardown_setting "$REPO" worktree_teardown)" "no dex.md: worktree_teardown default"
assert_eq rescue "$(dx_teardown_setting "$REPO" teardown_untracked)" "no dex.md: teardown_untracked default"
assert_eq false "$(dx_teardown_setting "$REPO" delete_remote_branch_on_merge)" "no dex.md: remote delete default"
mkdir -p "$REPO/.dex"
printf '# Project\n\n## Workflow\nRun /dex.\n' >"$REPO/.dex/dex.md"
assert_eq on_complete "$(dx_teardown_setting "$REPO" worktree_teardown)" "dex.md without the section"
set_teardown "$REPO" $'worktree_teardown: on_merge\nteardown_untracked: Refuse\ndelete_remote_branch_on_merge: true'
assert_eq on_merge "$(dx_teardown_setting "$REPO" worktree_teardown)" "on_merge is read"
assert_eq refuse "$(dx_teardown_setting "$REPO" teardown_untracked)" "values are case-insensitive"
assert_eq true "$(dx_teardown_setting "$REPO" delete_remote_branch_on_merge)" "true is read"
set_teardown "$REPO" $'worktree_teardown: on_merg\nteardown_untracked: delete\ndelete_remote_branch_on_merge: yes'
assert_eq caller "$(dx_teardown_setting "$REPO" worktree_teardown 2>"$TMP_DIR/warn")" "a typo keeps the worktree"
assert_contains "Ignoring worktree_teardown: 'on_merg'" "$TMP_DIR/warn"
assert_eq refuse "$(dx_teardown_setting "$REPO" teardown_untracked 2>/dev/null)" "an unknown mode refuses"
assert_eq false "$(dx_teardown_setting "$REPO" delete_remote_branch_on_merge 2>/dev/null)" "only true enables remote delete"
mkdir -p "$REPO/.dex"
printf '## Worktree Teardown\n\n```yaml\n- not a mapping\n```\n' >"$REPO/.dex/dex.md"
assert_eq caller "$(dx_teardown_setting "$REPO" worktree_teardown 2>"$TMP_DIR/warn")" "a malformed block keeps the worktree"
assert_contains "not a flat mapping" "$TMP_DIR/warn"
assert_eq refuse "$(dx_teardown_setting "$REPO" teardown_untracked 2>/dev/null)" "a malformed block refuses"
assert_rejected "an unknown key is a Dex bug" dx_teardown_setting "$REPO" teardown_mode
assert_rejected "the front door has a closed key set" dx_project_teardown_value "$REPO" before_remove

# --- unpushed count and safe branch delete ----------------------------------
REPO="$TMP_DIR/branches"
new_repo "$REPO"
git -C "$REPO" branch feature
assert_eq 0 "$(dx_branch_unpushed_count "$REPO" feature)" "a branch with no commits of its own"
assert_eq 0 "$(dx_branch_unpushed_count "$REPO" no-such-branch)" "a missing branch"
git -C "$REPO" checkout -q feature
git -C "$REPO" commit -q --allow-empty -m "local only"
git -C "$REPO" checkout -q main
assert_eq 1 "$(dx_branch_unpushed_count "$REPO" feature)" "one commit only this branch has"
git -C "$REPO" branch copy feature
assert_eq 0 "$(dx_branch_unpushed_count "$REPO" feature)" "a commit another branch holds is not lost"
git -C "$REPO" branch -D copy >/dev/null
dx_branch_delete_safe "$REPO" feature 2>"$TMP_DIR/warn" && fail "deleted a branch with unique commits"
assert_contains "1 commit(s) exist only on it" "$TMP_DIR/warn"
git -C "$REPO" show-ref --verify --quiet refs/heads/feature || assert_at $LINENO
# A squash merge: the branch tip is the merged pull request's head.
feature_oid=$(git -C "$REPO" rev-parse feature)
assert_eq 0 "$(dx_branch_unpushed_count "$REPO" feature "$feature_oid")" "a merged head counts as held"
dx_branch_delete_safe "$REPO" feature "$feature_oid" || assert_at $LINENO
! git -C "$REPO" show-ref --verify --quiet refs/heads/feature || assert_at $LINENO
# Pushed commits are held by the remote-tracking ref.
git -C "$REPO" checkout -q -b pushed
git -C "$REPO" commit -q --allow-empty -m pushed
git -C "$REPO" push -q -u origin pushed
git -C "$REPO" checkout -q main
assert_eq 0 "$(dx_branch_unpushed_count "$REPO" pushed)" "pushed commits are held by origin"
dx_branch_delete_safe "$REPO" pushed || assert_at $LINENO
dx_branch_delete_safe "$REPO" main 2>"$TMP_DIR/warn" && fail "deleted the default branch"
assert_contains "it is the default branch" "$TMP_DIR/warn"
git -C "$REPO" worktree add -q "$TMP_DIR/branches-wt" -b checked-out
dx_branch_delete_safe "$REPO" checked-out 2>"$TMP_DIR/warn" && fail "deleted a checked-out branch"
assert_contains "it is checked out in" "$TMP_DIR/warn"
dx_branch_delete_safe "$REPO" never-existed || assert_at $LINENO
# A repository with no remote at all: a branch at main's tip loses nothing.
REPO="$TMP_DIR/no-remote"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch empty-branch
assert_eq 0 "$(dx_branch_unpushed_count "$REPO" empty-branch)" "no remote, no commits of its own"

# --- rescue and the gate ----------------------------------------------------
REPO="$TMP_DIR/repo"
new_repo "$REPO"
WT="$REPO/.dex/worktrees/ticket-7"
git -C "$REPO" worktree add -q "$WT" -b worktree-ticket-7
# Dex's own links are excluded, as dx_link_claude_to_worktree leaves them.
mkdir -p "$REPO/.claude"
ln -s "$REPO/.claude" "$WT/.claude"
dx_exclude_claude_artifacts "$WT"
mkdir -p "$WT/notes/deep dir" "$WT/ignored"
printf 'keep me\n' >"$WT/notes/deep dir/todo file.txt"
printf 'build output\n' >"$WT/ignored/out.bin"
printf 'noise\n' >"$WT/debug.log"
ln -s README.md "$WT/link-to-readme"
printf 'edited\n' >>"$WT/README.md"
git -C "$WT" add README.md
printf 'unstaged\n' >>"$WT/README.md"

out=$(dx_wt_rescue "$WT" ticket-7)
[[ -d "$out" && "$out" == "$DX_RESCUE_DIR"/ticket-7-* ]] || fail "rescue path: $out"
assert_eq "keep me" "$(cat "$out/untracked/notes/deep dir/todo file.txt")" "nested untracked file copied"
[[ -L "$out/untracked/link-to-readme" ]] || fail "a symlink is kept as a link"
assert_eq README.md "$(readlink "$out/untracked/link-to-readme")" "symlink target kept"
[[ ! -e "$out/untracked/ignored" && ! -e "$out/untracked/debug.log" ]] || fail "gitignored files were rescued"
[[ ! -e "$out/untracked/.claude" ]] || fail "Dex's .claude link was rescued"
assert_contains "+edited" "$out/tracked.patch"
assert_contains "+unstaged" "$out/tracked.patch"
assert_contains "branch: worktree-ticket-7" "$out/info.txt"
[[ -n "$(find "$out" -maxdepth 0 -perm 700)" ]] || fail "rescue dir is not private"
# Patch round-trip: applying it to a clean checkout reproduces the edits.
git -C "$REPO" worktree add -q "$TMP_DIR/restore" --detach main
git -C "$TMP_DIR/restore" apply --binary "$out/tracked.patch"
assert_eq "$(cat "$WT/README.md")" "$(cat "$TMP_DIR/restore/README.md")" "patch restores tracked edits"
git -C "$REPO" worktree remove --force "$TMP_DIR/restore"
# Two rescues in the same second get separate directories.
second=$(dx_wt_rescue "$WT" ticket-7)
third=$(dx_wt_rescue "$WT" ticket-7)
[[ "$second" != "$third" && -d "$second" && -d "$third" ]] || fail "rescue directories collided: $second $third"

# A rescue that cannot copy keeps the worktree.
chmod u-w "$DX_RESCUE_DIR"
(DX_RESCUE_DIR="$DX_RESCUE_DIR/sub" dx_wt_remove "$WT" "$REPO") 2>"$TMP_DIR/err" && fail "removed after a failed rescue"
chmod u+w "$DX_RESCUE_DIR"
[[ -d "$WT" ]] || fail "worktree removed after a failed rescue"

# Default mode: the gate rescues, then dx_wt_remove removes.
before=$(find "$DX_RESCUE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
dx_wt_remove "$WT" "$REPO" >"$TMP_DIR/out" 2>&1 || fail "rescue-mode removal failed: $(cat "$TMP_DIR/out")"
[[ ! -e "$WT" ]] || fail "worktree still exists"
after=$(find "$DX_RESCUE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
assert_eq $((before + 1)) "$after" "one new rescue directory"
assert_contains "Saved untracked files and uncommitted changes from ticket-7" "$TMP_DIR/out"
git -C "$REPO" show-ref --verify --quiet refs/heads/worktree-ticket-7 || fail "gate must not touch the branch"

# A clean worktree is removed without a rescue directory.
git -C "$REPO" worktree add -q "$WT" -b worktree-ticket-8
dx_exclude_claude_artifacts "$WT"
ln -s "$REPO/.claude" "$WT/.claude"
before=$(find "$DX_RESCUE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
dx_wt_remove "$WT" "$REPO" >/dev/null 2>&1 || assert_at $LINENO
[[ ! -e "$WT" ]] || assert_at $LINENO
assert_eq "$before" "$(find "$DX_RESCUE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "clean worktree: no rescue"

# Refuse mode: untracked content, then unpushed commits, each keep everything.
set_teardown "$REPO" 'teardown_untracked: refuse'
git -C "$REPO" worktree add -q "$WT" -b worktree-ticket-9
printf 'x\n' >"$WT/scratch.txt"
result=0
dx_wt_remove "$WT" "$REPO" >"$TMP_DIR/out" 2>&1 || result=$?
assert_eq 3 "$result" "refuse returns 3"
[[ -f "$WT/scratch.txt" ]] || fail "refuse removed the worktree"
assert_contains "1 untracked file(s)" "$TMP_DIR/out"
assert_contains "scratch.txt" "$TMP_DIR/out"
rm "$WT/scratch.txt"
git -C "$WT" commit -q --allow-empty -m "unpushed"
result=0
dx_wt_remove "$WT" "$REPO" >"$TMP_DIR/out" 2>&1 || result=$?
assert_eq 3 "$result" "refuse with unpushed commits returns 3"
assert_contains "1 commit(s) on worktree-ticket-9 that exist nowhere else" "$TMP_DIR/out"
[[ -d "$WT" ]] || assert_at $LINENO
# The before_remove hook does not run for a worktree that stays.
printf '# Project\n\n## Worktree Hooks\n\n```yaml\nbefore_remove: touch "$DX_REPO_ROOT/hook-ran"\n```\n\n## Worktree Teardown\n\n```yaml\nteardown_untracked: refuse\n```\n' \
  >"$REPO/.dex/dex.md"
dx_wt_remove "$WT" "$REPO" >/dev/null 2>&1 && fail "refuse removed the worktree"
[[ ! -e "$REPO/hook-ran" ]] || fail "before_remove ran for a refused teardown"
git -C "$WT" push -q -u origin worktree-ticket-9
dx_wt_remove "$WT" "$REPO" >/dev/null 2>&1 || fail "refuse blocked a clean, pushed worktree"
[[ -e "$REPO/hook-ran" ]] || fail "before_remove did not run on removal"
rm -f "$REPO/hook-ran"

# Rescue mode with an unpushed commit removes the worktree; the branch stays.
set_teardown "$REPO" 'teardown_untracked: rescue'
git -C "$REPO" worktree add -q "$WT" -b worktree-ticket-10
git -C "$WT" commit -q --allow-empty -m "unpushed on ticket-10"
dx_wt_remove "$WT" "$REPO" >/dev/null 2>&1 || assert_at $LINENO
[[ ! -e "$WT" ]] || assert_at $LINENO
dx_branch_delete_safe "$REPO" worktree-ticket-10 2>/dev/null && fail "deleted a branch with an unpushed commit"
git -C "$REPO" show-ref --verify --quiet refs/heads/worktree-ticket-10 || assert_at $LINENO

# A detached HEAD with commits no branch holds gets a dex-rescue branch.
git -C "$REPO" worktree add -q --detach "$WT" main
git -C "$WT" commit -q --allow-empty -m "detached work"
detached_oid=$(git -C "$WT" rev-parse HEAD)
dx_wt_remove "$WT" "$REPO" >"$TMP_DIR/out" 2>&1 || assert_at $LINENO
rescue_branch=$(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/dex-rescue/')
[[ -n "$rescue_branch" ]] || fail "no dex-rescue branch for detached commits"
assert_eq "$detached_oid" "$(git -C "$REPO" rev-parse "$rescue_branch")" "rescue branch keeps the detached commit"

# An unregistered directory is moved whole in rescue mode, kept in refuse mode.
mkdir -p "$REPO/.dex/worktrees/stray/sub"
printf 'stray\n' >"$REPO/.dex/worktrees/stray/sub/file"
dx_wt_remove "$REPO/.dex/worktrees/stray" "$REPO" >"$TMP_DIR/out" 2>&1 || assert_at $LINENO
[[ ! -e "$REPO/.dex/worktrees/stray" ]] || assert_at $LINENO
moved=$(find "$DX_RESCUE_DIR" -path '*stray-*/untracked/sub/file' | head -1)
[[ -n "$moved" ]] || fail "unregistered directory was not rescued"
mkdir -p "$REPO/.dex/worktrees/stray2"
printf 'x\n' >"$REPO/.dex/worktrees/stray2/f"
set_teardown "$REPO" 'teardown_untracked: refuse'
dx_wt_remove "$REPO/.dex/worktrees/stray2" "$REPO" >/dev/null 2>&1 && fail "refuse removed an unregistered directory"
[[ -f "$REPO/.dex/worktrees/stray2/f" ]] || assert_at $LINENO
# An empty unregistered directory has nothing to lose.
rm -f "$REPO/.dex/worktrees/stray2/f"
dx_wt_remove "$REPO/.dex/worktrees/stray2" "$REPO" >/dev/null 2>&1 || assert_at $LINENO
[[ ! -e "$REPO/.dex/worktrees/stray2" ]] || assert_at $LINENO

# The same gate under zsh, which is how dxrm and dxclean call it.
set_teardown "$REPO" 'teardown_untracked: rescue'
git -C "$REPO" worktree add -q "$WT" -b worktree-ticket-11
printf 'zsh\n' >"$WT/z file.txt"
REPO="$REPO" WT="$WT" zsh -fc 'source "$DEX_DIR/lib/common.sh"; dx_wt_remove "$WT" "$REPO"' >/dev/null 2>&1 \
  || fail "zsh removal failed"
[[ ! -e "$WT" ]] || assert_at $LINENO
[[ -n "$(find "$DX_RESCUE_DIR" -name 'z file.txt' | head -1)" ]] || fail "zsh rescue missed a file"

# --- merged pull requests and remote deletion -------------------------------
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${DX_TEST_GH_MODE:-}" in
  merged) printf '%s\n' "$DX_TEST_GH_OID" ;;
  none) printf '\n' ;;
  fail) exit 1 ;;
  junk) printf 'not-an-oid\n' ;;
esac
GH
chmod +x "$TMP_DIR/bin/gh"
PATH="$TMP_DIR/bin:$PATH"
git -C "$REPO" checkout -q -b merged-branch
git -C "$REPO" commit -q --allow-empty -m merged
git -C "$REPO" push -q -u origin merged-branch
git -C "$REPO" checkout -q main
merged_oid=$(git -C "$REPO" rev-parse merged-branch)
assert_eq "$merged_oid" "$(DX_TEST_GH_MODE=merged DX_TEST_GH_OID="$merged_oid" dx_pr_merged_head "$REPO" merged-branch)" "merged head"
result=0; DX_TEST_GH_MODE=none dx_pr_merged_head "$REPO" merged-branch >/dev/null || result=$?
assert_eq 1 "$result" "no merged pull request"
result=0; DX_TEST_GH_MODE=fail dx_pr_merged_head "$REPO" merged-branch >/dev/null || result=$?
assert_eq 2 "$result" "gh failure is unknown"
result=0; DX_TEST_GH_MODE=junk dx_pr_merged_head "$REPO" merged-branch >/dev/null || result=$?
assert_eq 2 "$result" "an unexpected answer is unknown"

# Off by default: the remote branch stays.
set_teardown "$REPO" 'teardown_untracked: rescue'
dx_remote_branch_delete_if_merged "$REPO" merged-branch "$merged_oid"
git -C "$REPO.git" show-ref --verify --quiet refs/heads/merged-branch || fail "deleted with the setting off"
set_teardown "$REPO" 'delete_remote_branch_on_merge: true'
# A remote branch that moved after the merge is kept.
git -C "$REPO" commit -q --allow-empty -m "on main"
dx_remote_branch_delete_if_merged "$REPO" merged-branch "$(git -C "$REPO" rev-parse main)" 2>"$TMP_DIR/warn"
git -C "$REPO.git" show-ref --verify --quiet refs/heads/merged-branch || fail "deleted a moved remote branch"
assert_contains "it has moved since its pull request was merged" "$TMP_DIR/warn"
dx_remote_branch_delete_if_merged "$REPO" main "$(git -C "$REPO.git" rev-parse main)"
git -C "$REPO.git" show-ref --verify --quiet refs/heads/main || fail "deleted the default branch"
dx_remote_branch_delete_if_merged "$REPO" merged-branch "$merged_oid" >/dev/null
! git -C "$REPO.git" show-ref --verify --quiet refs/heads/merged-branch || fail "merged remote branch kept"

# refuse still lets a squash-merged worktree go: its merged pull request holds
# the commits no ref has once GitHub deleted the branch.
set_teardown "$REPO" 'teardown_untracked: refuse'
git -C "$REPO" worktree add -q "$WT" -b worktree-ticket-12 main
git -C "$WT" commit -q --allow-empty -m "squashed away"
squashed_oid=$(git -C "$WT" rev-parse HEAD)
result=0
DX_TEST_GH_MODE=none dx_wt_remove "$WT" "$REPO" >/dev/null 2>&1 || result=$?
assert_eq 3 "$result" "refuse keeps an unmerged branch's worktree"
DX_TEST_GH_MODE=merged DX_TEST_GH_OID="$squashed_oid" dx_wt_remove "$WT" "$REPO" >/dev/null 2>&1 \
  || fail "refuse kept a worktree whose pull request merged"
[[ ! -e "$WT" ]] || assert_at $LINENO

# dx worktree audit --apply goes through the same gate.
mkdir -p "$REPO/.dex/worktrees/stray3"
printf 'x\n' >"$REPO/.dex/worktrees/stray3/f"
(cd "$REPO" && bash "$ROOT/bin/worktree.sh" audit --apply) >"$TMP_DIR/out" 2>&1 || true
[[ -f "$REPO/.dex/worktrees/stray3/f" ]] || fail "audit --apply removed a directory refuse protects"
assert_contains "stray3: it is not a registered git worktree and is not empty (teardown_untracked: refuse)" "$TMP_DIR/out"
assert_not_contains "Could not remove" "$TMP_DIR/out"

printf 'worktree-teardown-test: ok\n'
