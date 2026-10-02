# shellcheck shell=bash
# Dex shared library - safe worktree teardown.
#
# A worktree is removed only after anything git would lose with it has been
# copied out (teardown_untracked: rescue) or the removal has been refused
# (teardown_untracked: refuse). A lifecycle branch is deleted only when no
# commit on it would become unreachable. See $DEX_DIR/docs/worktree-teardown.md.

# dx_teardown_setting <repo-dir> <key>
# Print the validated value of one `## Worktree Teardown` setting.
#
# An absent file, section or key gives the default. A malformed block or a
# value outside the allowed set gives the value that removes nothing, with a
# warning: a typo must never make Dex delete more than it would by default.
dx_teardown_setting() {
  local repo_dir="$1" key="$2" value="" read_result=0 default_value safe_value allowed
  case "$key" in
    worktree_teardown) default_value=on_complete safe_value=caller allowed=" on_complete on_merge caller " ;;
    teardown_untracked) default_value=rescue safe_value=refuse allowed=" rescue refuse " ;;
    delete_remote_branch_on_merge) default_value=false safe_value=false allowed=" true false " ;;
    *) return 2 ;;
  esac
  value=$(dx_project_teardown_value "$repo_dir" "$key" 2>/dev/null) || read_result=$?
  if [[ "$read_result" -eq 1 ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi
  if [[ "$read_result" -ne 0 ]]; then
    dx_warn "Ignoring '## Worktree Teardown' in ${repo_dir}/.dex/dex.md: it is not a flat mapping. Using ${key}: ${safe_value}."
    printf '%s\n' "$safe_value"
    return 0
  fi
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case "$allowed" in
    *" $value "*) printf '%s\n' "$value" ;;
    *)
      dx_warn "Ignoring ${key}: '${value}' in ${repo_dir}/.dex/dex.md (expected one of:${allowed% }). Using ${safe_value}."
      printf '%s\n' "$safe_value"
      ;;
  esac
}

# dx_branch_unpushed_count <repo-dir> <branch> [pushed-oid]
# Print how many commits on <branch> no other local branch or remote-tracking
# ref holds: the commits deleting the branch would lose. <pushed-oid> (a merged
# pull request's head) counts as held too, which covers a squash merge whose
# remote branch was deleted. Prints 0 for a branch that does not exist; fails
# when git cannot answer.
dx_branch_unpushed_count() {
  local repo_dir="$1" branch="$2" pushed_oid="${3:-}"
  git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null || {
    printf '0\n'
    return 0
  }
  # Branch names cannot contain *, ? or [ (git check-ref-format), so the
  # --exclude pattern matches this branch and nothing else.
  if [[ -n "$pushed_oid" ]]; then
    git -C "$repo_dir" rev-list --count "refs/heads/${branch}" --not \
      --exclude="$branch" --branches --remotes "$pushed_oid" 2>/dev/null
  else
    git -C "$repo_dir" rev-list --count "refs/heads/${branch}" --not \
      --exclude="$branch" --branches --remotes 2>/dev/null
  fi
}

# dx_branch_delete_safe <repo-dir> <branch> [pushed-oid]
# Delete a local lifecycle branch unless that would lose commits.
# Returns 0 when the branch is gone (or never existed), 3 when it was kept on
# purpose (unique commits, the default branch, checked out somewhere, or git
# could not tell), and 1 when `git branch -D` failed.
dx_branch_delete_safe() {
  local repo_dir="$1" branch="$2" pushed_oid="${3:-}" unique_count owner
  [[ -n "$branch" ]] || return 0
  git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null || return 0
  if [[ "$branch" == "$(dx_default_branch "$repo_dir")" ]]; then
    dx_warn "Kept local branch ${branch}: it is the default branch."
    return 3
  fi
  if owner=$(__dx_ticket_branch_worktree "$repo_dir" "$branch"); then
    dx_warn "Kept local branch ${branch}: it is checked out in ${owner}."
    return 3
  fi
  if ! unique_count=$(dx_branch_unpushed_count "$repo_dir" "$branch" "$pushed_oid") \
    || [[ ! "$unique_count" =~ ^[0-9]+$ ]]; then
    dx_warn "Kept local branch ${branch}: Dex could not tell whether its commits exist anywhere else."
    return 3
  fi
  if [[ "$unique_count" -gt 0 ]]; then
    dx_warn "Kept local branch ${branch}: ${unique_count} commit(s) exist only on it. Push or merge them, then delete it with: git branch -D ${branch}"
    return 3
  fi
  git -C "$repo_dir" branch -D "$branch" >/dev/null 2>&1 || return 1
}

# __dx_rescue_dir_create <wt-name>
# Create a fresh, private rescue directory and print its path. The leaf is
# made with a plain mkdir, which fails if it exists, so two teardowns in the
# same second get -2, -3, ... instead of sharing one directory.
__dx_rescue_dir_create() {
  local wt_name="$1" rescue_root stamp dest attempt=1
  rescue_root="${DX_RESCUE_DIR:-$HOME/.dex/rescue}"
  stamp=$(date -u +"%Y%m%dT%H%M%SZ")
  (umask 077 && mkdir -p "$rescue_root") || return 1
  dest="${rescue_root}/${wt_name}-${stamp}"
  while ! (umask 077 && mkdir "$dest") 2>/dev/null; do
    attempt=$((attempt + 1))
    [[ "$attempt" -le 99 ]] || return 1
    dest="${rescue_root}/${wt_name}-${stamp}-${attempt}"
  done
  printf '%s\n' "$dest"
}

# __dx_rescue_copy_entry <src> <dest>
# Copy one untracked entry, keeping a symlink as a link and copying a nested
# repository (listed by git as a directory) whole.
__dx_rescue_copy_entry() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")" || return 1
  if [[ -L "$src" ]]; then
    ln -s -- "$(readlink "$src")" "$dest"
  elif [[ -d "$src" ]]; then
    cp -RpP "$src" "$dest"
  else
    cp -p "$src" "$dest"
  fi
}

# __dx_wt_untracked_list <wt-dir>
# Print the NUL-separated untracked paths a removal would destroy. Dex excludes `.claude` in every repository it links into
# (dx_exclude_claude_artifacts), and that unanchored pattern also hides files
# under a real .claude directory, so those are listed with only the
# repository's own .gitignore rules. Dex's .claude link itself is a symlink,
# which the `**/.claude/**` pathspec never matches.
__dx_wt_untracked_list() {
  local wt_dir="$1"
  git -C "$wt_dir" ls-files -z --others --exclude-standard 2>/dev/null || return 1
  git -C "$wt_dir" ls-files -z --others --exclude-per-directory=.gitignore \
    -- ':(glob)**/.claude/**' 2>/dev/null
}

# __dx_wt_submodule_risk <wt-dir>
# Print one line per initialised submodule whose removal would lose work:
# untracked files, uncommitted edits, or commits no remote-tracking ref holds.
# A worktree's submodule repositories live under its own git directory, so
# `git worktree remove` deletes them, and neither the untracked list nor
# tracked.patch can carry them. Fails when git cannot inspect them.
__dx_wt_submodule_risk() {
  local wt_dir="$1"
  [[ -f "${wt_dir}/.gitmodules" ]] || return 0
  # shellcheck disable=SC2016 # expanded by git submodule foreach
  git -C "$wt_dir" submodule foreach --recursive --quiet '
    if [ -n "$(git status --porcelain --untracked-files=normal 2>/dev/null | head -1)" ]; then
      echo "submodule $displaypath has untracked files or uncommitted changes"
    elif [ "$(git rev-list --count HEAD --branches --not --remotes 2>/dev/null || echo unknown)" != 0 ]; then
      echo "submodule $displaypath has commits that exist nowhere else"
    fi' 2>/dev/null
}

# dx_wt_rescue <wt-dir> <wt-name>
# Copy what removing a registered worktree would destroy into a new directory
# under DX_RESCUE_DIR and print its path:
#   untracked/<path>   files git does not track or ignore
#   tracked.patch      uncommitted edits to tracked files (git diff HEAD --binary)
#   info.txt           where it came from, and how to restore it
# Returns 1 if anything could not be copied; the caller must then keep the
# worktree. A partial rescue directory is left in place.
dx_wt_rescue() {
  local wt_dir="$1" wt_name="$2" dest list_file rel failed=0 head_oid branch
  dest=$(__dx_rescue_dir_create "$wt_name") || {
    dx_error "Could not create a rescue directory under ${DX_RESCUE_DIR:-$HOME/.dex/rescue}."
    return 1
  }
  list_file="${dest}/.untracked-list"
  if ! __dx_wt_untracked_list "$wt_dir" >"$list_file"; then
    dx_error "Could not list untracked files in ${wt_dir}."
    return 1
  fi
  while IFS= read -r -d '' rel; do
    [[ -n "$rel" ]] || continue
    rel="${rel%/}"
    __dx_rescue_copy_entry "${wt_dir}/${rel}" "${dest}/untracked/${rel}" || failed=1
  done <"$list_file"
  rm -f "$list_file"
  if ! git -C "$wt_dir" diff HEAD --binary >"${dest}/tracked.patch" 2>/dev/null; then
    failed=1
  elif [[ ! -s "${dest}/tracked.patch" ]]; then
    rm -f "${dest}/tracked.patch"
  fi
  head_oid=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || echo "")
  branch=$(dx_wt_branch "$wt_dir" "(detached)")
  {
    printf 'worktree: %s\n' "$wt_dir"
    printf 'branch: %s\n' "$branch"
    printf 'head: %s\n' "$head_oid"
    printf 'rescued_at: %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '\nTo restore into a checkout of that commit:\n'
    printf '  git checkout %s\n' "$head_oid"
    printf '  git apply --binary %s/tracked.patch   # if present\n' "$dest"
    printf '  cp -R %s/untracked/. .\n' "$dest"
  } >"${dest}/info.txt" || failed=1
  if [[ "$failed" -ne 0 ]]; then
    dx_error "Rescue of ${wt_dir} was incomplete; the worktree was kept. Partial copy: ${dest}"
    return 1
  fi
  printf '%s\n' "$dest"
}

# __dx_rescue_unregistered <dir> <name>
# A directory under .dex/worktrees that git does not list as a worktree: git
# cannot say what in it is untracked, so the whole directory is moved (or, on
# another filesystem, copied) into the rescue directory.
__dx_rescue_unregistered() {
  local src="$1" name="$2" dest
  dest=$(__dx_rescue_dir_create "$name") || return 1
  if mv "$src" "${dest}/untracked" 2>/dev/null || cp -RpP "$src" "${dest}/untracked"; then
    printf '%s\n' "$dest"
    return 0
  fi
  dx_error "Could not copy ${src} into ${dest}; it was kept."
  return 1
}

# dx_wt_teardown_gate <wt-dir> <repo-root>
# Decide whether a worktree may be removed, applying teardown_untracked.
# Returns 0 when removal may go ahead (after a successful rescue if one was
# needed), 3 when it refuses, and 1 when a rescue failed.
#
# Unpushed commits on the checked-out branch are reported but do not block a
# rescue-mode removal: the branch keeps them, and dx_branch_delete_safe keeps
# the branch. Under refuse they block the whole teardown. A detached HEAD with
# commits no branch holds gets a dex-rescue/<name>-<time> branch in rescue mode.
dx_wt_teardown_gate() {
  local wt_dir="$1" repo_root="$2" mode wt_name untracked_count=0 tracked_dirty=0
  local branch unique_count="" rescue_path stamp detached=0 merged_oid
  local submodule_risk
  [[ -d "$wt_dir" ]] || return 0
  wt_name=$(basename "$wt_dir")
  mode=$(dx_teardown_setting "$repo_root" teardown_untracked)

  if [[ -z "$repo_root" ]] || ! dx_wt_is_registered "$repo_root" "$wt_dir"; then
    # Nothing to lose in an empty directory.
    [[ -n "$(ls -A "$wt_dir" 2>/dev/null)" ]] || return 0
    if [[ "$mode" == "refuse" ]]; then
      dx_warn "Kept ${wt_dir}: it is not a registered git worktree and is not empty (teardown_untracked: refuse)."
      return 3
    fi
    rescue_path=$(__dx_rescue_unregistered "$wt_dir" "$wt_name") || return 1
    dx_info "Moved the contents of unregistered ${wt_name} to ${rescue_path}"
    return 0
  fi

  # Submodule content cannot be copied out, so both modes keep the worktree.
  if ! submodule_risk=$(__dx_wt_submodule_risk "$wt_dir"); then
    dx_warn "Kept worktree ${wt_name}: Dex could not inspect its submodules."
    return 3
  fi
  if [[ -n "$submodule_risk" ]]; then
    dx_warn "Kept worktree ${wt_name}: removing it would delete submodule work Dex cannot rescue:"
    printf '%s\n' "$submodule_risk" | sed 's/^/    /'
    return 3
  fi

  if ! untracked_count=$(set -o pipefail
    __dx_wt_untracked_list "$wt_dir" | tr -cd '\000' | wc -c | tr -d ' '); then
    dx_error "Could not list untracked files in ${wt_dir}; the worktree was kept."
    return 1
  fi
  git -C "$wt_dir" diff HEAD --quiet 2>/dev/null || tracked_dirty=1
  branch=$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
  if [[ -n "$branch" ]]; then
    unique_count=$(dx_branch_unpushed_count "$repo_root" "$branch") || unique_count=""
  else
    detached=1
    unique_count=$(git -C "$wt_dir" rev-list --count HEAD --not --branches --remotes 2>/dev/null) || unique_count=""
  fi
  [[ "$unique_count" =~ ^[0-9]+$ ]] || unique_count="unknown"

  if [[ "$mode" == "refuse" ]]; then
    # A squash-merged branch whose remote GitHub deleted holds commits no
    # ref has; its merged pull request is where they went.
    if [[ "$unique_count" != 0 && -n "$branch" ]] \
      && merged_oid=$(dx_pr_merged_head "$repo_root" "$branch"); then
      unique_count=$(dx_branch_unpushed_count "$repo_root" "$branch" "$merged_oid") || unique_count=""
      [[ "$unique_count" =~ ^[0-9]+$ ]] || unique_count="unknown"
    fi
    if [[ "$untracked_count" -gt 0 || "$tracked_dirty" -eq 1 || "$unique_count" != 0 ]]; then
      dx_warn "Kept worktree ${wt_name} (teardown_untracked: refuse):"
      if [[ "$untracked_count" -gt 0 ]]; then
        dx_info "  ${untracked_count} untracked file(s):"
        __dx_wt_untracked_list "$wt_dir" | tr '\000' '\n' | head -10 | sed 's/^/    /'
      fi
      [[ "$tracked_dirty" -eq 0 ]] || dx_info "  uncommitted changes to tracked files"
      [[ "$unique_count" == 0 ]] || dx_info "  ${unique_count} commit(s) on ${branch:-a detached HEAD} that exist nowhere else"
      return 3
    fi
    return 0
  fi

  if [[ "$untracked_count" -gt 0 || "$tracked_dirty" -eq 1 ]]; then
    rescue_path=$(dx_wt_rescue "$wt_dir" "$wt_name") || return 1
    dx_info "Saved untracked files and uncommitted changes from ${wt_name} to ${rescue_path}"
  fi
  if [[ "$detached" -eq 1 && "$unique_count" != 0 ]]; then
    stamp=$(date -u +"%Y%m%dT%H%M%SZ")
    if ! git -C "$repo_root" branch "dex-rescue/${wt_name}-${stamp}" \
      "$(git -C "$wt_dir" rev-parse HEAD)" >/dev/null 2>&1; then
      dx_error "Could not keep the detached commits of ${wt_name}; the worktree was kept."
      return 1
    fi
    dx_info "Kept the detached commits of ${wt_name} on branch dex-rescue/${wt_name}-${stamp}"
  fi
  return 0
}

# dx_pr_merged_head <repo-dir> <branch>
# Ask GitHub whether a pull request from <branch> was merged. Prints its head
# commit and returns 0 when it was, returns 1 when no merged pull request
# exists, and 2 when the answer is unknown (no gh, an error, a timeout).
# Callers must treat 2 as "not merged" for anything that deletes.
dx_pr_merged_head() {
  local repo_dir="$1" branch="$2" head_oid="" lookup_result=0
  [[ -n "$branch" ]] || return 1
  command -v gh >/dev/null 2>&1 || return 2
  head_oid=$(__dx_ticket_branch_run "${DEX_TEARDOWN_GH_TIMEOUT:-30}" \
    __dx_ticket_branch_gh "$repo_dir" pr list --state merged --head "$branch" \
    --limit 1 --json headRefOid --jq '.[0].headRefOid // ""' 2>/dev/null) || lookup_result=$?
  [[ "$lookup_result" -eq 0 ]] || return 2
  [[ -n "$head_oid" ]] || return 1
  [[ "$head_oid" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 2
  printf '%s\n' "$head_oid"
}

# dx_remote_branch_delete_if_merged <repo-dir> <branch> <merged-oid> [remote]
# With delete_remote_branch_on_merge: true, delete <branch> on its remote.
# Only when the pull request was merged (the caller passes its head commit),
# the branch is not the default branch, and the remote branch still points at
# that commit, so work pushed after the merge is never deleted. The push
# carries that commit as a lease, so a push racing the check is not deleted
# either. Pass [remote] when the local branch, and with it its
# branch.<name>.remote setting, may already be gone. Returns 0 when deleted
# or skipped; a failed push only warns.
dx_remote_branch_delete_if_merged() {
  local repo_dir="$1" branch="$2" merged_oid="$3" remote="${4:-}" remote_oid
  [[ -n "$branch" && -n "$merged_oid" ]] || return 0
  [[ "$(dx_teardown_setting "$repo_dir" delete_remote_branch_on_merge)" == "true" ]] || return 0
  [[ "$branch" != "$(dx_default_branch "$repo_dir")" ]] || return 0
  [[ -n "$remote" ]] || remote=$(git -C "$repo_dir" config --get "branch.${branch}.remote" 2>/dev/null || echo "")
  [[ -n "$remote" && "$remote" != "." ]] || remote=origin
  remote_oid=$(__dx_ticket_branch_run "${DEX_TEARDOWN_GH_TIMEOUT:-30}" \
    git -C "$repo_dir" ls-remote --heads "$remote" "refs/heads/${branch}" 2>/dev/null | awk 'NR == 1 { print $1 }')
  if [[ -z "$remote_oid" ]]; then
    return 0
  fi
  if [[ "$remote_oid" != "$merged_oid" ]]; then
    dx_warn "Kept ${remote}/${branch}: it has moved since its pull request was merged."
    return 0
  fi
  if __dx_ticket_branch_run "${DEX_TEARDOWN_GH_TIMEOUT:-30}" \
    git -C "$repo_dir" push --quiet --force-with-lease="refs/heads/${branch}:${merged_oid}" \
    "$remote" --delete "$branch" >/dev/null 2>&1; then
    dx_info "Deleted merged remote branch ${remote}/${branch}"
  else
    dx_warn "Could not delete remote branch ${remote}/${branch}; delete it by hand if you no longer need it."
  fi
  return 0
}

# dx_lifecycle_branch_release <repo-dir> <branch> [merged-oid]
# Delete a lifecycle branch Dex is done with, and its remote branch when the
# project asked for that. GitHub is only asked about a merge when the answer
# matters: the branch holds commits nothing else does (a squash merge leaves
# exactly that), or delete_remote_branch_on_merge is on. Returns what
# dx_branch_delete_safe returns.
dx_lifecycle_branch_release() {
  local repo_dir="$1" branch="$2" merged_oid="${3:-}" unique_count delete_result=0 remote
  [[ -n "$branch" ]] || return 0
  # Deleting the local branch drops its branch.<name>.remote setting.
  remote=$(git -C "$repo_dir" config --get "branch.${branch}.remote" 2>/dev/null || echo "")
  if [[ -z "$merged_oid" ]]; then
    unique_count=$(dx_branch_unpushed_count "$repo_dir" "$branch" 2>/dev/null) || unique_count=""
    if [[ "$unique_count" != 0 ]] \
      || [[ "$(dx_teardown_setting "$repo_dir" delete_remote_branch_on_merge)" == "true" ]]; then
      merged_oid=$(dx_pr_merged_head "$repo_dir" "$branch") || merged_oid=""
    fi
  fi
  dx_branch_delete_safe "$repo_dir" "$branch" "$merged_oid" || delete_result=$?
  [[ -z "$merged_oid" ]] || dx_remote_branch_delete_if_merged "$repo_dir" "$branch" "$merged_oid" "$remote"
  return "$delete_result"
}

# dx_teardown_defer <session-id> <deferral> <branch>
# Record at completion that this lifecycle's teardown waits for a merge
# (on_merge) or for the caller (caller). The branch is copied into .meta
# because dxclean's stale sweep removes the per-phase .branch record after a
# week, and the sweep and dxrm still need it after that.
dx_teardown_defer() {
  local sid="$1" deferral="$2" branch="$3"
  dx_meta_write "$sid" "teardown_deferred=${deferral}" "teardown_branch=${branch}" \
    "teardown_at=$(date +%s)"
}

# dx_teardown_deferred_list <repo-root>
# One line per lifecycle in this repository whose teardown was deferred at
# completion (worktree_teardown: on_merge or caller), fields separated by the
# unit separator (\037), which, unlike a tab, read does not merge when a field
# is empty:
#   session_id wt_name wt_dir workspace_mode branch deferral
dx_teardown_deferred_list() {
  local repo_root="$1" repo_key meta_file sid deferral wt_name wt_dir workspace_mode branch
  [[ -d "$DX_STATE_DIR" ]] || return 0
  repo_key=$(cd "$repo_root" 2>/dev/null && dx_session_repo_key) || return 0
  # Only the sidecars that carry a deferral are read key by key; this runs at
  # every `dx` start, and most repositories have none.
  while IFS= read -r meta_file; do
    [[ -n "$meta_file" && -f "$meta_file" ]] || continue
    sid=$(basename "$meta_file" .meta)
    deferral=$(dx_meta_read "$sid" teardown_deferred)
    [[ "$deferral" == "on_merge" || "$deferral" == "caller" ]] || continue
    wt_name=$(dx_meta_read "$sid" wt_name)
    wt_dir=$(dx_meta_read "$sid" wt_dir)
    workspace_mode=$(dx_meta_read "$sid" workspace_mode)
    branch=$(dx_meta_read "$sid" teardown_branch)
    [[ -n "$wt_name" ]] || continue
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$sid" "$wt_name" "$wt_dir" \
      "${workspace_mode:-worktree}" "$branch" "$deferral"
  done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-*.meta" \
    -exec grep -l '^teardown_deferred=' {} + 2>/dev/null)
}

# dx_session_known_branch <session-id>
# The lifecycle branch Dex last recorded for a session, even after its
# worktree is gone: the deferral record, then the per-phase branch record,
# then the branch recorded when the ticket branch was prepared.
dx_session_known_branch() {
  local sid="$1" branch
  branch=$(dx_meta_read "$sid" teardown_branch)
  [[ -n "$branch" ]] || branch=$(dx_session_branch_read "$sid" 2>/dev/null || echo "")
  [[ -n "$branch" ]] || branch=$(dx_meta_read "$sid" current_branch)
  printf '%s\n' "$branch"
}

# dx_session_branch_records <repo-root>
# One line per Dex session in this repository whose branch Dex recorded,
# fields separated by \037 like dx_teardown_deferred_list:
#   branch session_id wt_name wt_dir deferral
# dxclean uses it to find lifecycle branches renamed away from worktree-*.
dx_session_branch_records() {
  local repo_root="$1" repo_key meta_file sid branch
  [[ -d "$DX_STATE_DIR" ]] || return 0
  repo_key=$(cd "$repo_root" 2>/dev/null && dx_session_repo_key) || return 0
  while IFS= read -r meta_file; do
    [[ -n "$meta_file" && -f "$meta_file" ]] || continue
    sid=$(basename "$meta_file" .meta)
    branch=$(dx_session_known_branch "$sid")
    [[ -n "$branch" ]] || continue
    printf '%s\037%s\037%s\037%s\037%s\n' "$branch" "$sid" "$(dx_meta_read "$sid" wt_name)" \
      "$(dx_meta_read "$sid" wt_dir)" "$(dx_meta_read "$sid" teardown_deferred)"
  done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-*.meta" -print 2>/dev/null)
}
