#!/usr/bin/env bash
# shellcheck disable=SC1091
# dx attribution — the current repository's attribution settings and models
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx attribution <command>

Show how this repository attributes commits and PRs, as set under
`## Attribution` in .dex/dex.md.

Commands:
  mode            Print the attribution mode: dex, claude, both or none
  settings        Print every attribution setting as key=value
  model           Print the model behind the current Dex session's latest turn
  models [<base>] Print the models recorded on this branch since <base>
                  (default: the merge base with origin's default branch),
                  plus the current one; nothing when the model trailer is off

Options:
  -h, --help      Show this help
USAGE
}

attribution_command="${1:-}"
case "$attribution_command" in
  -h|--help|help|"")
    usage
    [[ -n "$attribution_command" ]] || exit 1
    exit 0
    ;;
esac
shift

if ! attribution_repo=$(git rev-parse --show-toplevel 2>/dev/null); then
  dx_error "Not in a git repository."
  exit 1
fi

case "$attribution_command" in
  mode)
    [[ $# -eq 0 ]] || { usage >&2; exit 1; }
    dx_attribution_mode "$attribution_repo"
    ;;
  settings)
    [[ $# -eq 0 ]] || { usage >&2; exit 1; }
    dx_attribution_settings "$attribution_repo"
    ;;
  model)
    [[ $# -eq 0 ]] || { usage >&2; exit 1; }
    dx_attribution_model "${DEX_SESSION_ID:-}" "$attribution_repo"
    ;;
  models)
    [[ $# -le 1 ]] || { usage >&2; exit 1; }
    attribution_base="${1:-}"
    if [[ -z "$attribution_base" ]]; then
      attribution_default=$(dx_default_branch "$attribution_repo")
      attribution_base=$(git -C "$attribution_repo" merge-base HEAD "origin/${attribution_default}" 2>/dev/null \
        || git -C "$attribution_repo" merge-base HEAD "$attribution_default" 2>/dev/null || true)
      if [[ -z "$attribution_base" ]]; then
        dx_error "Could not find where this branch started; pass the base: dx attribution models <base>"
        exit 1
      fi
    fi
    dx_attribution_branch_models "$attribution_repo" "$attribution_base"
    ;;
  *)
    dx_error "Unknown attribution command: $attribution_command"
    usage >&2
    exit 1
    ;;
esac
