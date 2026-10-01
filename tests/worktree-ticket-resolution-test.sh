#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-ticket-resolution.XXXXXX")"

cleanup() {
  git -C "$TMP_DIR/repo" worktree remove --force "$TMP_DIR/repo/.dex/worktrees/task-linked" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export TEST_REPO="$TMP_DIR/repo"
export TEST_REVERT_CAPTURE="$TMP_DIR/revert-capture"
mkdir -p "$HOME" "$TEST_REPO/.dex/worktrees"

git -C "$TEST_REPO" init -q
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
printf 'base\n' > "$TEST_REPO/file.txt"
git -C "$TEST_REPO" add file.txt
git -C "$TEST_REPO" commit -q -m "test: initialize repo"
git -C "$TEST_REPO" branch -m main
git -C "$TEST_REPO" worktree add -q \
  "$TEST_REPO/.dex/worktrees/task-linked" \
  -b worktree-task-linked HEAD

zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$TEST_REPO"

  linked_session=$(dx_session_id task-linked)
  dx_meta_write "$linked_session" \
    "ticket_number=123" \
    "wt_name=task-linked" \
    "wt_dir=$TEST_REPO/.dex/worktrees/task-linked" \
    "workspace_mode=worktree"

  dx_latest_checkpoint_phase() { print -r -- 2; }
  dx_revert_to_checkpoint() {
    print -r -- "$1::$2" > "$TEST_REVERT_CAPTURE"
  }

  expected="$TEST_REPO/.dex/worktrees/task-linked"
  dxcd ENG-123
  [[ "${PWD:A}" == "${expected:A}" ]] || assert_at $LINENO
  cd "$TEST_REPO"

  __dx_cli revert 123 > /dev/null
  # dx_repo_root resolves symlinked path components (macOS /var -> /private/var),
  # so compare against the resolved expected path.
  [[ "$(cat "$TEST_REVERT_CAPTURE")" == "2::${expected:A}" ]] || assert_at $LINENO

  dxrm 123 > /dev/null
  [[ ! -d "$expected" ]] || assert_at $LINENO
  ! git show-ref --verify --quiet refs/heads/worktree-task-linked
  [[ ! -e "$(dx_meta_file "$linked_session")" ]] || assert_at $LINENO

  quoted_branch="feature/in-place-dollar\$-semi;colon"
  quoted_session=$(__dx_session_id_for_workspace in-place task-quoted)
  git branch "$quoted_branch" main
  git switch -q "$quoted_branch"
  dx_record_session_branch "$quoted_session" "$TEST_REPO"
  dx_lifecycle_atomic_write "$(dx_state_file "$quoted_session")" 2
  git switch -q main
  printf "dirty\n" >> "$TEST_REPO/file.txt"
  if __dx_restore_in_place_session_branch \
      "$quoted_session" task-quoted "$TEST_REPO" "dx --resume" \
      > "$TEST_REPO/dirty-resume.out" 2>&1; then
    print -u2 -- "in-place resume switched branches with a dirty checkout"
    exit 1
  fi
  [[ "$(git symbolic-ref --quiet --short HEAD)" == main ]] || assert_at $LINENO
  grep -Fq "current checkout is on main" "$TEST_REPO/dirty-resume.out"
  rm -f "$TEST_REPO/dirty-resume.out"
  git checkout -- file.txt
  __dx_restore_in_place_session_branch \
    "$quoted_session" task-quoted "$TEST_REPO" "dx --resume"
  [[ "$(git symbolic-ref --quiet --short HEAD)" == "$quoted_branch" ]] \
    || assert_at $LINENO
  git switch -q main
  dx_cleanup_session "$quoted_session"
  git branch -D "$quoted_branch" >/dev/null

  git branch worktree-task-inplace main
  inplace_session=$(__dx_session_id_for_workspace in-place task-inplace)
  dx_meta_write "$inplace_session" \
    "ticket_number=456" \
    "wt_name=task-inplace" \
    "wt_dir=$TEST_REPO" \
    "workspace_mode=in-place"
  dx_lifecycle_atomic_write "$(dx_state_file "$inplace_session")" 2
  git switch -q worktree-task-inplace
  dx_record_session_branch "$inplace_session" "$TEST_REPO"
  git switch -q main

  rmdir "$TEST_REPO/.dex/worktrees"
  dxcd 456 > /dev/null
  [[ "${PWD:A}" == "${TEST_REPO:A}" ]] || assert_at $LINENO

  if __dx_cli revert 456 > "$TEST_REPO/revert-inplace.out" 2>&1; then
    print -u2 -- "dx revert accepted an in-place lifecycle"
    exit 1
  fi
  grep -Fq "uses an in-place lifecycle" "$TEST_REPO/revert-inplace.out"

  if dxrm 456 > "$TEST_REPO/remove-inplace.out" 2>&1; then
    print -u2 -- "dxrm removed an active in-place lifecycle"
    exit 1
  fi
  grep -Fq "Refusing to remove active in-place lifecycle branch" "$TEST_REPO/remove-inplace.out"
  git show-ref --verify --quiet refs/heads/worktree-task-inplace

  assert_unsafe_branch_is_protected() {
    local unsafe_kind="$1" unsafe_branch="worktree-task-unsafe-${1}"
    local unsafe_name="${unsafe_branch#worktree-}" unsafe_session branch_file
    local unsafe_target helper_result=0
    unsafe_session=$(__dx_session_id_for_workspace in-place "$unsafe_name")
    branch_file=$(dx_branch_file "$unsafe_session")
    unsafe_target="${branch_file}.target"
    git branch "$unsafe_branch" main
    dx_lifecycle_atomic_write "$(dx_state_file "$unsafe_session")" 2
    case "$unsafe_kind" in
      missing)
        ;;
      symlink)
        dx_lifecycle_atomic_write "$unsafe_target" "$unsafe_branch"
        ln -s "$unsafe_target" "$branch_file"
        ;;
      hardlink)
        dx_lifecycle_atomic_write "$unsafe_target" "$unsafe_branch"
        ln "$unsafe_target" "$branch_file"
        ;;
      wrong-mode)
        printf "%s\n" "$unsafe_branch" > "$branch_file"
        chmod 644 "$branch_file"
        ;;
      malformed)
        dx_lifecycle_atomic_write "$branch_file" bad..branch
        ;;
    esac

    __dx_active_in_place_phase_for_branch "$unsafe_branch" >/dev/null 2>&1 \
      || helper_result=$?
    [[ "$helper_result" -eq 2 ]] || {
      print -u2 -- "unsafe branch helper result for ${unsafe_kind}: ${helper_result}"
      exit 1
    }
    if dxrm "$unsafe_name" \
        > "$TEST_REPO/remove-unsafe-${unsafe_kind}.out" 2>&1; then
      print -u2 -- "dxrm removed an in-place branch with ${unsafe_kind} state"
      exit 1
    fi
    grep -Fq "branch state is missing, unsafe, or malformed" \
      "$TEST_REPO/remove-unsafe-${unsafe_kind}.out"
    git show-ref --verify --quiet "refs/heads/${unsafe_branch}"
    chmod 600 "$branch_file" "$unsafe_target" 2>/dev/null || true
    rm -f "$branch_file" "$unsafe_target" \
      "$TEST_REPO/remove-unsafe-${unsafe_kind}.out"
    rm -f "$(dx_state_file "$unsafe_session")"
    git branch -D "$unsafe_branch" >/dev/null
  }

  for unsafe_kind in missing symlink hardlink wrong-mode malformed; do
    assert_unsafe_branch_is_protected "$unsafe_kind"
  done

  mkdir -p "$TEST_REPO/.dex/worktrees"
  git worktree add -q "$TEST_REPO/.dex/worktrees/task-first" -b worktree-task-first main
  git worktree add -q "$TEST_REPO/.dex/worktrees/task-second" -b worktree-task-second main
  first_session=$(dx_session_id task-first)
  second_session=$(dx_session_id task-second)
  dx_meta_write "$first_session" \
    "ticket_number=999" \
    "wt_name=task-first" \
    "wt_dir=$TEST_REPO/.dex/worktrees/task-first" \
    "workspace_mode=worktree"
  dx_meta_write "$second_session" \
    "ticket_number=999" \
    "wt_name=task-second" \
    "wt_dir=$TEST_REPO/.dex/worktrees/task-second" \
    "workspace_mode=worktree"

  for command_name in navigate revert remove setup setup-in-place; do
    case "$command_name" in
      navigate) command=(dxcd 999) ;;
      revert) command=(__dx_cli revert 999) ;;
      remove) command=(dxrm 999) ;;
      setup) command=(__dx_setup_worktree 999) ;;
      setup-in-place) command=(__dx_setup_in_place 999) ;;
    esac
    if "${command[@]}" > "$TEST_REPO/ambiguous-$command_name.out" 2>&1; then
      print -u2 -- "$command_name accepted an ambiguous ticket workspace"
      exit 1
    fi
    grep -Fq "Multiple Dex workspaces are linked to ticket 999" \
      "$TEST_REPO/ambiguous-$command_name.out"
  done
  [[ -d "$TEST_REPO/.dex/worktrees/task-first" ]] || assert_at $LINENO
  [[ -d "$TEST_REPO/.dex/worktrees/task-second" ]] || assert_at $LINENO
  [[ ! -e "$TEST_REPO/.dex/worktrees/ticket-999" ]] || assert_at $LINENO
'

# ─── A project that lists ticket_prefixes ───────────────────────────────────
# ENG-1234 and OPS-1234 are different tickets there, a workspace made before
# the list existed is still found, and a bare number never borrows a prefixed
# ticket's workspace.

export PREFIX_REPO="$TMP_DIR/prefix-repo"
export PREFIX_OUT="$TMP_DIR/prefix-out"
mkdir -p "$PREFIX_REPO/.dex" "$PREFIX_OUT"
# Real projects ignore .dex/worktrees; in-place setup refuses a dirty checkout.
printf '.dex/worktrees/\n' > "$PREFIX_REPO/.gitignore"
git -C "$PREFIX_REPO" init -q
git -C "$PREFIX_REPO" config user.email dex@example.test
git -C "$PREFIX_REPO" config user.name "Dex Test"
cat > "$PREFIX_REPO/.dex/dex.md" <<'DEXMD'
# Dex

## Tickets

```yaml
ticket_prefixes: [ENG, OPS]
```
DEXMD
printf 'base\n' > "$PREFIX_REPO/file.txt"
git -C "$PREFIX_REPO" add file.txt .dex/dex.md .gitignore
git -C "$PREFIX_REPO" commit -q -m "test: initialize prefixed repo"
git -C "$PREFIX_REPO" branch -m main

zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$PREFIX_REPO"
  dx_link_claude_to_worktree() { : }
  dx_link_build_caches_to_worktree() { : }
  wt="$PREFIX_REPO/.dex/worktrees"

  # Two tickets with one number get two workspaces, branches and records.
  __dx_setup_worktree ENG-1234 > /dev/null
  [[ "$_dx_wt_name" == ticket-eng-1234 ]] || assert_at $LINENO
  eng_session="$_dx_session_id"
  __dx_startup_claim_release
  __dx_setup_worktree ops-1234 > /dev/null
  [[ "$_dx_wt_name" == ticket-ops-1234 ]] || assert_at $LINENO
  ops_session="$_dx_session_id"
  __dx_startup_claim_release
  [[ -d "$wt/ticket-eng-1234" && -d "$wt/ticket-ops-1234" ]] || assert_at $LINENO
  [[ ! -e "$wt/ticket-1234" ]] || assert_at $LINENO
  git show-ref --verify --quiet refs/heads/worktree-ticket-eng-1234
  git show-ref --verify --quiet refs/heads/worktree-ticket-ops-1234
  [[ "$eng_session" != "$ops_session" ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$eng_session" ticket_id)" == ENG-1234 ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$eng_session" ticket_number)" == 1234 ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$ops_session" ticket_id)" == OPS-1234 ]] || assert_at $LINENO

  # Running it again resumes the same workspace.
  __dx_setup_worktree eng-1234 > /dev/null
  [[ "$_dx_session_id" == "$eng_session" ]] || assert_at $LINENO
  __dx_startup_claim_release

  # Navigation, revert and removal find each ticket and only that ticket.
  dxcd ENG-1234
  [[ "${PWD:A}" == "${wt:A}/ticket-eng-1234" ]] || assert_at $LINENO
  cd "$PREFIX_REPO"
  dx_latest_checkpoint_phase() { print -r -- 2; }
  dx_revert_to_checkpoint() { print -r -- "$1::$2" > "$TEST_REVERT_CAPTURE"; }
  __dx_cli revert OPS-1234 > /dev/null
  [[ "$(cat "$TEST_REVERT_CAPTURE")" == "2::${wt:A}/ticket-ops-1234" ]] || assert_at $LINENO
  dxrm OPS-1234 > /dev/null
  [[ ! -d "$wt/ticket-ops-1234" && -d "$wt/ticket-eng-1234" ]] || assert_at $LINENO

  # A bare number is its own ticket. Its records and workspaces are separate
  # from ENG-1234, and Dex names the prefixed ones instead of picking one.
  [[ "$(dx_meta_find_workspace_by_ticket 1234 2>/dev/null)" == "" ]] || assert_at $LINENO
  __dx_setup_worktree 1234 > "$PREFIX_OUT/bare-setup.out" 2>&1
  [[ "$_dx_wt_name" == ticket-1234 ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$_dx_session_id" ticket_id)" == 1234 ]] || assert_at $LINENO
  grep -Fq "different ticket from ENG-1234" "$PREFIX_OUT/bare-setup.out"
  __dx_startup_claim_release
  dxrm 1234 > /dev/null
  [[ -d "$wt/ticket-eng-1234" ]] || assert_at $LINENO

  # The other way round: ENG-4321 does not take the workspace of the bare
  # ticket 4321, and neither ticket rewrites the ticket_id of the other.
  __dx_setup_worktree 4321 > /dev/null 2>&1
  bare_session="$_dx_session_id"
  __dx_startup_claim_release
  [[ "$(dx_meta_find_workspace_by_ticket ENG-4321 2>/dev/null)" == "" ]] || assert_at $LINENO
  __dx_setup_worktree ENG-4321 > "$PREFIX_OUT/bare-owned.out" 2>&1
  [[ "$_dx_wt_name" == ticket-eng-4321 && "$_dx_session_id" != "$bare_session" ]] || assert_at $LINENO
  grep -Fq "ticket-4321 belongs to ticket 4321" "$PREFIX_OUT/bare-owned.out"
  __dx_startup_claim_release
  [[ "$(dx_meta_read "$bare_session" ticket_id)" == 4321 ]] || assert_at $LINENO
  [[ -d "$wt/ticket-4321" && -d "$wt/ticket-eng-4321" ]] || assert_at $LINENO
  dxrm ENG-4321 > /dev/null
  dxrm 4321 > /dev/null

  # A ticket-N workspace from before the list existed: ENG-77 resumes it with
  # a notice and claims it, after which OPS-77 gets its own workspace.
  git worktree add -q "$wt/ticket-77" -b worktree-ticket-77 main
  legacy_session=$(dx_session_id ticket-77)
  dx_meta_write "$legacy_session" "ticket_number=77" "wt_name=ticket-77" \
    "wt_dir=$wt/ticket-77" "workspace_mode=worktree"
  __dx_setup_worktree ENG-77 > "$PREFIX_OUT/legacy.out" 2>&1
  [[ "$_dx_wt_name" == ticket-77 && "$_dx_session_id" == "$legacy_session" ]] || assert_at $LINENO
  grep -Fq "Using ticket-77 for ENG-77" "$PREFIX_OUT/legacy.out"
  [[ ! -e "$wt/ticket-eng-77" ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$legacy_session" ticket_id)" == ENG-77 ]] || assert_at $LINENO
  __dx_startup_claim_release
  dxcd eng-77
  [[ "${PWD:A}" == "${wt:A}/ticket-77" ]] || assert_at $LINENO
  cd "$PREFIX_REPO"
  __dx_setup_worktree OPS-77 > /dev/null
  [[ "$_dx_wt_name" == ticket-ops-77 ]] || assert_at $LINENO
  __dx_startup_claim_release
  [[ -d "$wt/ticket-ops-77" ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$legacy_session" ticket_id)" == ENG-77 ]] || assert_at $LINENO

  # A legacy record linked to a task-named workspace: the prefixed ID still
  # finds it through the metadata scan.
  git worktree add -q "$wt/task-early" -b worktree-task-early main
  early_session=$(dx_session_id task-early)
  dx_meta_write "$early_session" "ticket_number=88" "wt_name=task-early" \
    "wt_dir=$wt/task-early" "workspace_mode=worktree"
  dxcd ENG-88 > /dev/null
  [[ "${PWD:A}" == "${wt:A}/task-early" ]] || assert_at $LINENO
  cd "$PREFIX_REPO"

  # In-place mode and dx run resolve through the same names: a prefixed
  # in-place session, and a legacy in-place session that a prefixed ID resumes.
  __dx_setup_in_place ENG-55 > /dev/null
  [[ "$_dx_wt_name" == ticket-eng-55 ]] || assert_at $LINENO
  [[ "$(git symbolic-ref --quiet --short HEAD)" == worktree-ticket-eng-55 ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$_dx_session_id" ticket_id)" == ENG-55 ]] || assert_at $LINENO
  [[ "$(dx_meta_read "$_dx_session_id" ticket_number)" == 55 ]] || assert_at $LINENO
  __dx_startup_claim_release
  git switch -q main
  # A bare number names the in-place prefixed session too, without taking it.
  __dx_parse_ticket_input 55 "$PREFIX_REPO"
  __dx_hint_prefixed_ticket_workspaces "$PREFIX_REPO" > "$PREFIX_OUT/inplace-hint.out"
  grep -Fq "different ticket from ENG-55." "$PREFIX_OUT/inplace-hint.out" || assert_at $LINENO
  [[ "$_dx_ticket_wt_name" == ticket-55 ]] || assert_at $LINENO
  legacy_inplace=$(__dx_session_id_for_workspace in-place ticket-56)
  dx_lifecycle_atomic_write "$(dx_state_file "$legacy_inplace")" 2
  __dx_resolve_workspace_name OPS-56 in-place "$PREFIX_REPO" > "$PREFIX_OUT/inplace.out"
  [[ "$_dx_wt_name" == ticket-56 ]] || assert_at $LINENO
  grep -Fq "Using ticket-56 for OPS-56" "$PREFIX_OUT/inplace.out"
  dx_meta_write "$legacy_inplace" "ticket_id=ENG-56"
  __dx_resolve_workspace_name OPS-56 in-place "$PREFIX_REPO" > /dev/null
  [[ "$_dx_wt_name" == ticket-ops-56 ]] || assert_at $LINENO
  rm -f "$(dx_state_file "$legacy_inplace")"
'

printf 'worktree ticket resolution tests passed\n'
