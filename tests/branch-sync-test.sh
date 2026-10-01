#!/usr/bin/env bash
set -euo pipefail

# Base sync before final verification and before a PR is marked ready:
# ownership, the lease push, conflicts, the before-ready bound, the opt-out
# setting, and the failure codes, all against a local bare remote.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-branch-sync.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
  email = dex@example.test
  name = Dex Test
[init]
  defaultBranch = main
EOF
unset DEX_SESSION_ID DEX_LOOP_PHASE

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

HOME_MARKER="$TMP_DIR/home-marker"
touch "$HOME_MARKER"

FIXTURE_COUNT=0

# new_fixture <branch> — a bare origin with main, a clone on <branch> with
# one branch commit, and a seed clone that can advance main or the branch.
new_fixture() {
  local branch_name="$1"
  FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
  FIXTURE_REMOTE="$TMP_DIR/f${FIXTURE_COUNT}.git"
  FIXTURE_SEED="$TMP_DIR/f${FIXTURE_COUNT}-seed"
  FIXTURE_REPO="$TMP_DIR/f${FIXTURE_COUNT}-repo"
  FIXTURE_BRANCH="$branch_name"

  git init -q --bare "$FIXTURE_REMOTE"
  git clone -q "$FIXTURE_REMOTE" "$FIXTURE_SEED" 2>/dev/null
  printf 'base\n' > "$FIXTURE_SEED/base.txt"
  git -C "$FIXTURE_SEED" add base.txt
  git -C "$FIXTURE_SEED" commit -q -m "test: add base"
  git -C "$FIXTURE_SEED" branch -M main
  git -C "$FIXTURE_SEED" push -q -u origin main
  git -C "$FIXTURE_REMOTE" symbolic-ref HEAD refs/heads/main

  git clone -q "$FIXTURE_REMOTE" "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" switch -q --no-track -c "$branch_name" origin/main
  printf 'feature\n' > "$FIXTURE_REPO/feature.txt"
  git -C "$FIXTURE_REPO" add feature.txt
  git -C "$FIXTURE_REPO" commit -q -m "feat: add feature"
}

publish_branch() {
  git -C "$FIXTURE_REPO" push -q -u origin "$FIXTURE_BRANCH"
}

# advance_main [file] [content] — someone else lands work on the base.
advance_main() {
  local file="${1:-later-$RANDOM.txt}" content="${2:-later}"
  git -C "$FIXTURE_SEED" switch -q main
  git -C "$FIXTURE_SEED" pull -q --ff-only origin main
  printf '%s\n' "$content" > "$FIXTURE_SEED/$file"
  git -C "$FIXTURE_SEED" add "$file"
  git -C "$FIXTURE_SEED" commit -q -m "test: advance main ($file)"
  git -C "$FIXTURE_SEED" push -q origin main
}

# new_session <label> key=value... — a Dex session whose meta records how the
# lifecycle branch came to exist.
new_session() {
  local label="$1"
  shift
  SESSION="branch-sync-${label}"
  rm -f "$(dx_meta_file "$SESSION")"
  dx_meta_write "$SESSION" "$@"
  export DEX_SESSION_ID="$SESSION"
}

owned_session() {
  new_session "$1" "workspace_mode=worktree" "original_branch=worktree-ticket-1" \
    "current_branch=${FIXTURE_BRANCH}" "ticket_branch_source=new"
}

remote_oid() {
  git -C "$FIXTURE_REMOTE" rev-parse --verify --quiet "refs/heads/$1" || true
}

run_sync() {
  SYNC_RC=0
  SYNC_OUT=$(cd "$FIXTURE_REPO" && dx_branch_sync_with_base "$FIXTURE_REPO" "$@" 2>&1) || SYNC_RC=$?
}

# --- An owned branch behind its base is rebased and pushed with a lease. ---
new_fixture 11-owned-feature
publish_branch
owned_session owned
advance_main
run_sync
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO
[[ "$SYNC_OUT" == rebased* ]] || assert_at $LINENO
git -C "$FIXTURE_REPO" merge-base --is-ancestor origin/main HEAD || assert_at $LINENO
[[ "$(remote_oid "$FIXTURE_BRANCH")" == "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" ]] || assert_at $LINENO
[[ "$(git -C "$FIXTURE_REPO" rev-parse --abbrev-ref '@{u}')" == "origin/${FIXTURE_BRANCH}" ]] || assert_at $LINENO

# A second sync finds nothing to do and pushes nothing.
BEFORE_REMOTE=$(remote_oid "$FIXTURE_BRANCH")
run_sync
[[ "$SYNC_RC" -eq 0 ]] || assert_at $LINENO
[[ "$SYNC_OUT" == current* ]] || assert_at $LINENO
[[ "$(remote_oid "$FIXTURE_BRANCH")" == "$BEFORE_REMOTE" ]] || assert_at $LINENO

# The same answers come through the CLI's exit status.
advance_main
CLI_RC=0
(cd "$FIXTURE_REPO" && bash "$ROOT/bin/branch-sync.sh" sync >/dev/null 2>&1) || CLI_RC=$?
[[ "$CLI_RC" -eq 1 ]] || assert_at $LINENO
CLI_RC=0
(cd "$FIXTURE_REPO" && bash "$ROOT/bin/branch-sync.sh" bogus >/dev/null 2>&1) || CLI_RC=$?
[[ "$CLI_RC" -eq 2 ]] || assert_at $LINENO

# --- A tracker-less worktree branch is Dex's own; an unpublished one is created. ---
new_fixture worktree-ticket-9
new_session trackerless "workspace_mode=worktree" "original_branch=worktree-ticket-9"
advance_main
run_sync
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO
[[ "$(remote_oid worktree-ticket-9)" == "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" ]] || assert_at $LINENO

# --- Branches Dex did not create are reported, never rewritten. ---
assert_not_owned() {
  local line="$1" head_before remote_before
  head_before=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
  remote_before=$(remote_oid "$FIXTURE_BRANCH")
  run_sync
  [[ "$SYNC_RC" -eq 4 ]] || assert_at "$line"
  [[ "$SYNC_OUT" == not-owned* && "$SYNC_OUT" == *"behind=1"* ]] || assert_at "$line"
  [[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$head_before" ]] || assert_at "$line"
  [[ "$(remote_oid "$FIXTURE_BRANCH")" == "$remote_before" ]] || assert_at "$line"
}

new_fixture feature/adopted
publish_branch
advance_main
new_session adopted "workspace_mode=worktree" "original_branch=worktree-ticket-2" \
  "current_branch=feature/adopted" "ticket_branch_source=remote"
assert_not_owned $LINENO
new_session preexisting "workspace_mode=worktree" "original_branch=worktree-ticket-2" \
  "current_branch=feature/adopted" "ticket_branch_source=local"
assert_not_owned $LINENO
new_session in-place "workspace_mode=in-place" "original_branch=feature/adopted" \
  "current_branch=feature/adopted" "ticket_branch_source=new"
assert_not_owned $LINENO
new_session other-branch "workspace_mode=worktree" "original_branch=worktree-ticket-2" \
  "current_branch=some-other-branch" "ticket_branch_source=new"
assert_not_owned $LINENO
unset DEX_SESSION_ID
assert_not_owned $LINENO
new_session wrong-placeholder "workspace_mode=worktree" "original_branch=feature/adopted"
assert_not_owned $LINENO

# --- The project can turn the sync off; an absent key leaves it on. ---
new_fixture 12-settings
publish_branch
owned_session settings
advance_main
mkdir -p "$FIXTURE_REPO/.dex"
printf '# Project\n\n## Resources\n\n```yaml\nrebase_before_ready: false\n```\n' \
  > "$FIXTURE_REPO/.dex/dex.md"
HEAD_BEFORE=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
run_sync
[[ "$SYNC_RC" -eq 0 && "$SYNC_OUT" == disabled* ]] || assert_at $LINENO
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$HEAD_BEFORE" ]] || assert_at $LINENO
dx_rebase_before_ready_enabled "$FIXTURE_REPO" && assert_at $LINENO
printf '# Project\n\n## Resources\n\n```yaml\nrebase_before_ready: Off\n```\n' \
  > "$FIXTURE_REPO/.dex/dex.md"
dx_rebase_before_ready_enabled "$FIXTURE_REPO" && assert_at $LINENO
printf '# Project\n\n## Resources\n\n```yaml\nfull_gate: ci\n```\n' \
  > "$FIXTURE_REPO/.dex/dex.md"
dx_rebase_before_ready_enabled "$FIXTURE_REPO" || assert_at $LINENO
printf '# Project\n\n## Resources\n\n```yaml\nrebase_before_ready:\n  nested: true\n```\n' \
  > "$FIXTURE_REPO/.dex/dex.md"
dx_rebase_before_ready_enabled "$FIXTURE_REPO" 2>/dev/null || assert_at $LINENO
rm -rf "$FIXTURE_REPO/.dex"
dx_rebase_before_ready_enabled "$FIXTURE_REPO" || assert_at $LINENO
run_sync
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO

# --- A conflict stops the rebase and names the files; continue records a note. ---
new_fixture 13-conflict
printf 'feature line\n' > "$FIXTURE_REPO/base.txt"
git -C "$FIXTURE_REPO" commit -q -am "feat: change base"
publish_branch
owned_session conflict
advance_main base.txt "main line"
CONTINUE_RC=0
(cd "$FIXTURE_REPO" && dx_branch_sync_continue "$FIXTURE_REPO" "nothing to continue" >/dev/null 2>&1) \
  || CONTINUE_RC=$?
[[ "$CONTINUE_RC" -eq 2 ]] || assert_at $LINENO
run_sync
[[ "$SYNC_RC" -eq 3 ]] || assert_at $LINENO
[[ "$SYNC_OUT" == conflict* && "$SYNC_OUT" == *"base.txt"* ]] || assert_at $LINENO
CONTINUE_RC=0
CONTINUE_OUT=$(cd "$FIXTURE_REPO" && dx_branch_sync_continue "$FIXTURE_REPO" "kept both" 2>&1) || CONTINUE_RC=$?
[[ "$CONTINUE_RC" -eq 3 && "$CONTINUE_OUT" == *"base.txt"* ]] || assert_at $LINENO
CONTINUE_RC=0
(cd "$FIXTURE_REPO" && dx_branch_sync_continue "$FIXTURE_REPO" "" >/dev/null 2>&1) || CONTINUE_RC=$?
[[ "$CONTINUE_RC" -eq 2 ]] || assert_at $LINENO
printf 'main line\nfeature line\n' > "$FIXTURE_REPO/base.txt"
git -C "$FIXTURE_REPO" add base.txt
CONTINUE_RC=0
CONTINUE_OUT=$(cd "$FIXTURE_REPO" && dx_branch_sync_continue "$FIXTURE_REPO" "base.txt: kept both sides" 2>&1) \
  || CONTINUE_RC=$?
[[ "$CONTINUE_RC" -eq 1 && "$CONTINUE_OUT" == rebased* ]] || assert_at $LINENO
LAST_MESSAGE=$(git -C "$FIXTURE_REPO" log -1 --format=%B)
[[ "$LAST_MESSAGE" == *"feat: change base"* ]] || assert_at $LINENO
[[ "$LAST_MESSAGE" == *"Rebase-note: base.txt: kept both sides"* ]] || assert_at $LINENO
[[ ! -d "$(git -C "$FIXTURE_REPO" rev-parse --git-path rebase-merge)" ]] || assert_at $LINENO
[[ "$(remote_oid "$FIXTURE_BRANCH")" == "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" ]] || assert_at $LINENO

# --- Someone else's push to the branch is never overwritten. ---
new_fixture 14-diverged
publish_branch
owned_session diverged
git -C "$FIXTURE_SEED" fetch -q origin "$FIXTURE_BRANCH"
git -C "$FIXTURE_SEED" switch -q -c "$FIXTURE_BRANCH" FETCH_HEAD
printf 'theirs\n' > "$FIXTURE_SEED/theirs.txt"
git -C "$FIXTURE_SEED" add theirs.txt
git -C "$FIXTURE_SEED" commit -q -m "feat: someone else's work"
git -C "$FIXTURE_SEED" push -q origin "$FIXTURE_BRANCH"
THEIRS=$(remote_oid "$FIXTURE_BRANCH")
HEAD_BEFORE=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
advance_main
run_sync
[[ "$SYNC_RC" -eq 7 && "$SYNC_OUT" == remote-diverged* ]] || assert_at $LINENO
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$HEAD_BEFORE" ]] || assert_at $LINENO
[[ "$(remote_oid "$FIXTURE_BRANCH")" == "$THEIRS" ]] || assert_at $LINENO

# The lease holds when the remote moves after Dex recorded it.
new_fixture 15-lease
publish_branch
owned_session lease
advance_main
run_sync
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO
git -C "$FIXTURE_SEED" fetch -q origin "$FIXTURE_BRANCH"
git -C "$FIXTURE_SEED" switch -q -c "$FIXTURE_BRANCH" FETCH_HEAD
printf 'racing\n' > "$FIXTURE_SEED/racing.txt"
git -C "$FIXTURE_SEED" add racing.txt
git -C "$FIXTURE_SEED" commit -q -m "feat: racing push"
git -C "$FIXTURE_SEED" push -q origin "$FIXTURE_BRANCH"
RACING=$(remote_oid "$FIXTURE_BRANCH")
git -C "$FIXTURE_REPO" commit -q --amend -m "feat: add feature (amended)"
PUSH_RC=0
PUSH_OUT=$(cd "$FIXTURE_REPO" && dx_branch_lease_push "$FIXTURE_REPO" 2>&1) || PUSH_RC=$?
[[ "$PUSH_RC" -eq 7 && "$PUSH_OUT" == remote-diverged* ]] || assert_at $LINENO
[[ "$(remote_oid "$FIXTURE_BRANCH")" == "$RACING" ]] || assert_at $LINENO

# The push helper refuses a branch Dex does not own, and a branch with no lease.
new_session lease-foreign "workspace_mode=worktree" "original_branch=worktree-ticket-3" \
  "current_branch=${FIXTURE_BRANCH}" "ticket_branch_source=remote"
PUSH_RC=0
(cd "$FIXTURE_REPO" && dx_branch_lease_push "$FIXTURE_REPO" >/dev/null 2>&1) || PUSH_RC=$?
[[ "$PUSH_RC" -eq 4 ]] || assert_at $LINENO
owned_session lease-missing
PUSH_RC=0
(cd "$FIXTURE_REPO" && dx_branch_lease_push "$FIXTURE_REPO" >/dev/null 2>&1) || PUSH_RC=$?
[[ "$PUSH_RC" -eq 2 ]] || assert_at $LINENO
[[ "$(remote_oid "$FIXTURE_BRANCH")" == "$RACING" ]] || assert_at $LINENO

# --- Before ready, the base may move only so many times. ---
new_fixture 16-bound
publish_branch
owned_session bound
[[ "$(dx_base_sync_max_rebases "$SESSION")" == "2" ]] || assert_at $LINENO
advance_main
run_sync --before-ready
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO
advance_main
run_sync --before-ready
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO
advance_main
HEAD_BEFORE=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
run_sync --before-ready
[[ "$SYNC_RC" -eq 6 && "$SYNC_OUT" == limit* ]] || assert_at $LINENO
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$HEAD_BEFORE" ]] || assert_at $LINENO
# An up-to-date branch is not limited, and Phase 4's sync never counts.
run_sync
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO
run_sync --before-ready
[[ "$SYNC_RC" -eq 0 ]] || assert_at $LINENO
[[ "$(dx_meta_read "$SESSION" base_sync_ready_rebases)" == "2" ]] || assert_at $LINENO
# A recorded override raises the bound.
dx_override_set "$SESSION" pr.rebase-attempts 3 session - human \
  "The base branch is busy today" >/dev/null
[[ "$(dx_base_sync_max_rebases "$SESSION")" == "3" ]] || assert_at $LINENO
advance_main
run_sync --before-ready
[[ "$SYNC_RC" -eq 1 ]] || assert_at $LINENO

# --- Failures that leave the branch untouched. ---
new_fixture 17-failures
publish_branch
owned_session failures
advance_main
printf 'dirty\n' >> "$FIXTURE_REPO/feature.txt"
run_sync
[[ "$SYNC_RC" -eq 2 && "$SYNC_OUT" == cannot-run* ]] || assert_at $LINENO
git -C "$FIXTURE_REPO" checkout -q -- feature.txt
git -C "$FIXTURE_REPO" switch -q --detach HEAD
run_sync
[[ "$SYNC_RC" -eq 2 && "$SYNC_OUT" == cannot-run* ]] || assert_at $LINENO
git -C "$FIXTURE_REPO" switch -q "$FIXTURE_BRANCH"
git -C "$FIXTURE_REPO" remote set-url origin "$TMP_DIR/missing.git"
HEAD_BEFORE=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
run_sync
[[ "$SYNC_RC" -eq 5 && "$SYNC_OUT" == fetch-failed* ]] || assert_at $LINENO
[[ "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" == "$HEAD_BEFORE" ]] || assert_at $LINENO

# --- State stays in Dex's state directory; nothing lands in HOME. ---
[[ -z "$(find "$HOME" -newer "$HOME_MARKER" -type f -print)" ]] || assert_at $LINENO
[[ -f "$(dx_meta_file branch-sync-bound)" ]] || assert_at $LINENO

echo "branch-sync tests passed"
