#!/usr/bin/env bash
set -euo pipefail

# Keep a Dex lifecycle branch current with its base before final verification
# and before its PR is marked ready. Phase 4 runs `sync`; the step before any
# `gh pr ready` runs `sync --before-ready`, which counts against
# pr.rebase-attempts. prompts/base-sync.md says what to do with each answer.
#
# Only a branch this lifecycle created is rebased or force-pushed, and only
# with a lease on the remote commit it last saw, so nobody else's push is
# overwritten. Everything else is reported and left alone.
#
#   branch-sync.sh sync [--before-ready]   rebase onto the base if behind
#   branch-sync.sh continue --note TEXT    finish a rebase after resolving a
#                                          simple conflict, then push
#   branch-sync.sh push                    retry the lease push after a
#                                          failed one
#
# Exit status is the answer:
#   0  current, or disabled by rebase_before_ready: false
#   1  rebased and pushed: the tree changed, so re-run the full gate
#   2  cannot run: bad usage, dirty tree, detached HEAD, nothing to continue
#   3  conflict: the rebase stopped; conflicting files are listed
#   4  not owned: behind the base, but Dex did not create this branch
#   5  fetch or push failed
#   6  limit: the base moved again after pr.rebase-attempts rebases
#   7  remote diverged: origin has commits this checkout lacks

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage_line() {
  dx_error "Usage: branch-sync.sh sync [--before-ready] | continue --note TEXT | push"
}

REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
  dx_error "branch-sync.sh must run inside a git checkout."
  exit 2
}

[[ $# -ge 1 ]] || { usage_line; exit 2; }
SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  sync)
    case "$#:${1:-}" in
      0:) dx_branch_sync_with_base "$REPO_DIR" ;;
      1:--before-ready) dx_branch_sync_with_base "$REPO_DIR" --before-ready ;;
      *) usage_line; exit 2 ;;
    esac
    ;;
  continue)
    [[ $# -eq 2 && "$1" == "--note" ]] || { usage_line; exit 2; }
    dx_branch_sync_continue "$REPO_DIR" "$2"
    ;;
  push)
    [[ $# -eq 0 ]] || { usage_line; exit 2; }
    dx_branch_lease_push "$REPO_DIR"
    ;;
  -h|--help)
    usage_line
    exit 0
    ;;
  *)
    usage_line
    exit 2
    ;;
esac
