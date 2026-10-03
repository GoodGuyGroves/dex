# shellcheck shell=bash
# Dex shared library - project file ownership tracking and the machine-readable
# half of the `.dex/dex.md` project contract.

# dx_project_contract_values <repo-dir> <section> <key>
# Read one key out of the fenced block under `## <section>` in the repository's
# `.dex/dex.md`, one value per line.
#
# This is the only entry point for the machine-readable part of the project
# contract, so every section that grows one — `## Resources`,
# `## Worktree Hooks` and `## Context Providers` among them — parses the same
# way and a caller never re-implements the reading. The parser is
# scripts/project-contract.py: stdlib only, a flat mapping of scalars and lists.
#
# Returns 0 with the value, 1 when the file, the section, the block or the key
# is absent — which every caller must treat as "this project declared nothing"
# and carry on — and 2 when the block exists but is not a flat mapping, with
# the reason on stderr.
dx_project_contract_values() {
  [[ $# -eq 3 ]] || return 2
  local repo_dir="$1" contract_section="$2" contract_key="$3" contract_file
  [[ -n "$repo_dir" && -n "$contract_section" && -n "$contract_key" ]] || return 2
  contract_file="$repo_dir/.dex/dex.md"
  [[ -f "$contract_file" ]] || return 1
  python3 "$DEX_DIR/scripts/project-contract.py" "$contract_file" \
    "$contract_section" "$contract_key"
}

# dx_project_worktree_hook <repo-dir> <hook-name>
# The shell command a project declared for one worktree lifecycle hook, from
# the fenced block under `## Worktree Hooks` in its `.dex/dex.md`.
#
# The same parser and the same return codes as dx_project_contract_values,
# which this is a named front door for. The difference is the closed key set:
# a misspelled hook name is a Dex bug, so it returns 2 here instead of looking
# like a project that declared nothing.
dx_project_worktree_hook() {
  [[ $# -eq 2 ]] || return 2
  local hook_repo="$1" hook_key="$2"
  case "$hook_key" in
    after_create | before_remove | on_session_end | orphan_resources) ;;
    *) return 2 ;;
  esac
  dx_project_contract_values "$hook_repo" "Worktree Hooks" "$hook_key"
}

# dx_project_context_provider <repo-dir> <key>
# One raw setting from the fenced block under `## Context Providers` in the
# repository's `.dex/dex.md`: the command Dex runs at session start or at a
# phase handoff, or one of its limits. lib/context-providers.sh runs the
# command and validates the limits.
#
# Same parser and return codes as dx_project_contract_values, with a closed
# key set like dx_project_worktree_hook: a misspelled key is a Dex bug, so it
# returns 2 instead of looking like a project that declared nothing.
dx_project_context_provider() {
  [[ $# -eq 2 ]] || return 2
  local provider_repo="$1" provider_key="$2"
  case "$provider_key" in
    session_start | phase_handoff | timeout_seconds | max_chars) ;;
    *) return 2 ;;
  esac
  dx_project_contract_values "$provider_repo" "Context Providers" "$provider_key"
}

# dx_project_pr_template <repo-dir>
# The real path of the PR template a project declared as `template:` under
# `## Pull Requests`. prompts/pr-template-resolution.md decides what happens
# when there is none.
#
# Returns 1 when nothing is declared and 2, with the reason on stderr, when the
# block is malformed or the path is absolute, leaves the repository, or is not
# a readable, non-empty regular file. Phase 5 then falls back to the next
# template source rather than stopping.
dx_project_pr_template() {
  [[ $# -eq 1 && -n "$1" ]] || return 2
  local pr_repo="$1" declared="" read_rc=0
  declared=$(dx_project_contract_values "$pr_repo" "Pull Requests" template) \
    || read_rc=$?
  [[ "$read_rc" -eq 0 ]] || return "$read_rc"
  if [[ "$declared" == *$'\n'* ]]; then
    printf 'PR template must be one path, not a list\n' >&2
    return 2
  fi
  python3 "$DEX_DIR/scripts/pr-contract.py" template "$pr_repo" "$declared"
}

# dx_project_pr_label_rules <repo-dir>
# The `labels_when` rules under `## Pull Requests`, one `glob<TAB>label` line
# each. Returns 1 when none are declared and 2, with the reason on stderr, when
# the block or any one rule is malformed.
dx_project_pr_label_rules() {
  [[ $# -eq 1 && -n "$1" ]] || return 2
  __dx_pr_label_rules_run rules "$1"
}

# dx_pr_labels_for_paths <repo-dir>
# Read NUL-separated paths on stdin and print each label whose rule matches one
# of them, once, in rule order. Same return codes as dx_project_pr_label_rules;
# a declared rule set that matches nothing prints nothing and returns 0.
dx_pr_labels_for_paths() {
  [[ $# -eq 1 && -n "$1" ]] || return 2
  __dx_pr_label_rules_run match "$1"
}

__dx_pr_label_rules_run() {
  local rules_mode="$1" pr_repo="$2" raw_rules="" read_rc=0 rule
  local rule_args=()
  raw_rules=$(dx_project_contract_values "$pr_repo" "Pull Requests" labels_when) \
    || read_rc=$?
  [[ "$read_rc" -eq 0 ]] || return "$read_rc"
  while IFS= read -r rule; do
    rule_args+=("$rule")
  done <<< "$raw_rules"
  python3 "$DEX_DIR/scripts/pr-contract.py" "$rules_mode" "${rule_args[@]}"
}

# dx_pr_changed_files <repo-dir> [pr-number]
# The paths a PR changes, NUL-separated. With a PR number the diff is against
# the PR's own base branch, so a PR stacked on another branch is not charged
# with its parent's files; otherwise, or when gh cannot say, it is against the
# default branch. --no-renames lists both sides of a rename, so a file moved
# out of a matched directory still counts.
dx_pr_changed_files() {
  [[ $# -ge 1 && -n "$1" ]] || return 2
  local pr_repo="$1" pr_number="${2:-}" base_name="" base_ref=""
  if [[ -n "$pr_number" ]]; then
    base_name=$(cd "$pr_repo" && gh pr view "$pr_number" --json baseRefName \
      -q .baseRefName 2>/dev/null </dev/null) || base_name=""
  fi
  if [[ -n "$base_name" && "$base_name" != -* && "$base_name" != *[[:space:]]* ]]; then
    git -C "$pr_repo" fetch origin "$base_name" --quiet 2>/dev/null || true
    if git -C "$pr_repo" rev-parse --verify --quiet "refs/remotes/origin/$base_name" >/dev/null 2>&1; then
      base_ref="origin/$base_name"
    fi
  fi
  if [[ -z "$base_ref" ]]; then
    base_ref=$(dx_default_branch_base_ref "$pr_repo") || return 1
  fi
  git -C "$pr_repo" diff --name-only --no-renames -z "${base_ref}...HEAD" --
}

# dx_pr_apply_label_rules <pr-number> [repo-dir]
# Add every label the project's rules select for the PR's changed paths. Labels
# are only added: one a person put on the PR stays, and one the repository does
# not have is reported, never created. A project with no rules gets no gh call.
#
# Returns 0 when every label was added or there was nothing to add, 1 when at
# least one could not be added or the changed paths could not be listed, and 2
# for a usage error or a malformed rule set, which applies nothing.
dx_pr_apply_label_rules() {
  local pr_number="${1:-}" pr_repo="${2:-$PWD}" rules_rc=0 labels="" label failed=0
  if [[ -z "$pr_number" ]]; then
    dx_warn "dx_pr_apply_label_rules needs a PR number"
    return 2
  fi
  dx_project_pr_label_rules "$pr_repo" >/dev/null || rules_rc=$?
  case "$rules_rc" in
    0) ;;
    1) return 0 ;;
    *)
      dx_warn "Not applying PR labels: fix labels_when under '## Pull Requests' in .dex/dex.md"
      return 2
      ;;
  esac
  if ! labels=$(set -o pipefail; dx_pr_changed_files "$pr_repo" "$pr_number" \
    | dx_pr_labels_for_paths "$pr_repo"); then
    dx_warn "Not applying PR labels: could not list the files PR #${pr_number} changes"
    return 1
  fi
  [[ -n "$labels" ]] || return 0
  while IFS= read -r label; do
    if (cd "$pr_repo" && gh pr edit "$pr_number" --add-label "$label") >/dev/null 2>&1 </dev/null; then
      dx_ok "Labelled PR #${pr_number}: ${label}"
    else
      dx_warn "Could not add label '${label}' to PR #${pr_number}; the repository may not have it"
      failed=1
    fi
  done <<< "$labels"
  [[ "$failed" -eq 0 ]] || return 1
}

# dx_project_teardown_value <repo-dir> <key>
# A project's raw setting from the fenced block under `## Worktree Teardown`
# in its `.dex/dex.md`. Same parser and return codes as
# dx_project_contract_values, with a closed key set like
# dx_project_worktree_hook. dx_teardown_setting validates the value.
dx_project_teardown_value() {
  [[ $# -eq 2 ]] || return 2
  local teardown_repo="$1" teardown_key="$2"
  case "$teardown_key" in
    worktree_teardown | teardown_untracked | delete_remote_branch_on_merge) ;;
    *) return 2 ;;
  esac
  dx_project_contract_values "$teardown_repo" "Worktree Teardown" "$teardown_key"
}

# dx_project_verification_value <repo-dir> <key>
# A project's raw Phase 4 setting from the fenced block under
# `## Verification` in its `.dex/dex.md`: `lanes` (the commands that make up
# the Phase 4 gate, in order) or `known_failures` (a repo-relative file of
# baseline failures). Same parser and return codes as
# dx_project_contract_values, with a closed key set.
dx_project_verification_value() {
  [[ $# -eq 2 ]] || return 2
  local verification_repo="$1" verification_key="$2"
  case "$verification_key" in
    lanes | known_failures) ;;
    *) return 2 ;;
  esac
  dx_project_contract_values "$verification_repo" "Verification" "$verification_key"
}

# dx_verification_known_failures <repo-dir>
# The baseline failures that apply to this checkout, one
# `test-id<TAB>base-ref<TAB>issue-ref` line each, from the file named by
# `known_failures:` under `## Verification`. The file holds one such line per
# failure, with `#` comments and blank lines allowed. An entry applies while
# its base ref resolves to a commit HEAD contains: the failure was already on
# the base this branch grew from, so it is not this branch's to fix.
#
# Returns 1 when nothing is declared, and 2, with the reason on stderr, when
# the block is malformed or the path is absolute, leaves the repository, or is
# not a regular file. A malformed line is reported on stderr and skipped.
dx_verification_known_failures() {
  [[ $# -eq 1 && -n "$1" ]] || return 2
  local failures_repo="$1" declared="" read_rc=0 failures_file test_id base_ref issue_ref extra
  declared=$(dx_project_verification_value "$failures_repo" known_failures) || read_rc=$?
  [[ "$read_rc" -eq 0 ]] || return "$read_rc"
  failures_file=$(python3 - "$failures_repo" "$declared" <<'PY'
import os
import sys

repo, declared = sys.argv[1], sys.argv[2]
if "\n" in declared or not declared or os.path.isabs(declared):
    print(f"known_failures must be one repository-relative path: {declared!r}", file=sys.stderr)
    raise SystemExit(2)
root = os.path.realpath(repo)
path = os.path.realpath(os.path.join(root, declared))
if os.path.commonpath([root, path]) != root:
    print(f"known_failures leaves the repository: {declared}", file=sys.stderr)
    raise SystemExit(2)
if not os.path.isfile(path):
    print(f"known_failures is not a regular file: {declared}", file=sys.stderr)
    raise SystemExit(2)
print(path)
PY
) || return 2
  while IFS=$'\t' read -r test_id base_ref issue_ref extra || [[ -n "$test_id" ]]; do
    case "$test_id" in
      "" | \#*) continue ;;
    esac
    if [[ -z "$base_ref" || -z "$issue_ref" || -n "$extra" ]]; then
      printf 'dex: skipping malformed known_failures line for %s: want test-id<TAB>base-ref<TAB>issue-ref\n' \
        "$test_id" >&2
      continue
    fi
    git -C "$failures_repo" rev-parse --verify --quiet "${base_ref}^{commit}" > /dev/null 2>&1 \
      || continue
    git -C "$failures_repo" merge-base --is-ancestor "$base_ref" HEAD 2>/dev/null || continue
    printf '%s\t%s\t%s\n' "$test_id" "$base_ref" "$issue_ref"
  done < "$failures_file"
}

# dx_verification_phase_block <repo-dir>
# The Phase 4 policy a project declared under `## Verification`, as text for
# the Phase 4 handoff and audit: the lanes that make up the gate and the
# baseline failures not to fix in this unit. Prints nothing when the project
# declared neither, so the default Phase 4 text is unchanged.
dx_verification_phase_block() {
  [[ $# -eq 1 ]] || return 2
  local block_repo="$1" lanes="" lanes_rc=0 failures="" failures_rc=0 lane test_id base_ref issue_ref
  [[ -n "$block_repo" ]] || return 0
  lanes=$(dx_project_verification_value "$block_repo" lanes 2>/dev/null) || lanes_rc=$?
  failures=$(dx_verification_known_failures "$block_repo" 2>/dev/null) || failures_rc=$?
  if [[ "$lanes_rc" -eq 1 && "$failures_rc" -eq 1 ]]; then
    return 0
  fi
  printf '%s\n' "Phase 4 verification policy (.dex/dex.md § Verification):"
  if [[ "$lanes_rc" -eq 0 && -n "$lanes" ]]; then
    printf '%s\n' "- Run these lanes, in order, as the required Phase 4 gate (receipt name full-gate), instead of the project's aggregate gate:"
    while IFS= read -r lane; do
      [[ -z "$lane" ]] || printf '    %s\n' "$lane"
    done <<< "$lanes"
  elif [[ "$lanes_rc" -eq 2 ]]; then
    printf '%s\n' "- The lanes setting could not be read; use the default Phase 4 gate."
  fi
  if [[ "$failures_rc" -eq 0 && -n "$failures" ]]; then
    printf '%s\n' "- Known baseline failures on this branch's base. Report each one you hit as baseline (<issue-ref>) and do not fix it in this unit:"
    while IFS=$'\t' read -r test_id base_ref issue_ref; do
      printf '    %s (base %s, %s)\n' "$test_id" "$base_ref" "$issue_ref"
    done <<< "$failures"
  elif [[ "$failures_rc" -eq 2 ]]; then
    printf '%s\n' "- The known_failures setting could not be read; treat every failure as this unit's to fix or report."
  fi
  return 0
}

dx_project_state_file() {
  local repo_root="$1"
  local git_dir

  if ! git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$git_dir/dex-project-state.json"
}

dx_project_state_begin() {
  local repo_root="$1"
  local state_file

  state_file=$(dx_project_state_file "$repo_root") || return 1
  python3 "$DEX_DIR/scripts/project-state.py" project-begin "$repo_root" "$state_file"
}

dx_project_state_finalize() {
  local repo_root="$1"
  local state_file

  state_file=$(dx_project_state_file "$repo_root") || return 1
  python3 "$DEX_DIR/scripts/project-state.py" project-finalize "$repo_root" "$state_file"
}

dx_project_state_remove_managed() {
  local repo_root="$1"
  local state_file

  state_file=$(dx_project_state_file "$repo_root") || return 1
  [[ -f "$state_file" ]] || return 3
  python3 "$DEX_DIR/scripts/project-state.py" project-remove "$repo_root" "$state_file"
}

dx_project_has_other_init_state() {
  local repo_root="$1"
  local current_git_dir line worktree_path candidate_git_dir worktree_output git_status

  if current_git_dir=$(git -C "$repo_root" rev-parse --path-format=absolute \
    --absolute-git-dir 2>/dev/null); then
    :
  else
    git_status=$?
    return "$git_status"
  fi
  if worktree_output=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null); then
    :
  else
    git_status=$?
    return "$git_status"
  fi
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        worktree_path=${line#worktree }
        # A worktree whose directory was deleted without `git worktree prune`
        # still appears in the porcelain listing. It is not an active checkout,
        # so skip it rather than aborting uninit and attribution restore.
        [[ -d "$worktree_path" ]] || continue
        if candidate_git_dir=$(git -C "$worktree_path" rev-parse --path-format=absolute \
          --absolute-git-dir 2>/dev/null); then
          :
        else
          git_status=$?
          return "$git_status"
        fi
        if [[ "$candidate_git_dir" != "$current_git_dir" ]] \
          && [[ -f "$candidate_git_dir/dex-project-state.json" ]]; then
          return 0
        fi
        ;;
    esac
  done < <(printf '%s\n' "$worktree_output")
  return 1
}
