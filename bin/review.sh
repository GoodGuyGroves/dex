#!/usr/bin/env bash
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<USAGE
Usage: dx review stats [--json] [--root <dir>]
       dx review status [--json | --line] [--session <id>]
       dx review -h | --help

status: the current review loop for this session (or --session): tier, wave N
of the budget, clean streak, the running wave's stage and elapsed time against
its timeout, and each finished wave's verdict. It reads the run's events.jsonl
and the Phase 3 busy record, and changes nothing.

stats: report what the review loop actually did, per risk tier, from the telemetry
Dex already writes under $DX_RUN_ROOT/*/events.jsonl.

Per tier: loops recorded, median passes and minutes per loop, how many loops
reached the clean gate and how many never did, how many passes ran after clean
credit was already banked, and how many of those found something anyway.

That last pair is the number to set a default by. Requiring a second or third
consecutive clean pass is worth its time only while confirmation passes keep
finding things; when they stop, lower the requirement and publish these numbers
in the pull request that changes it.

Options:
  --json         Emit the rows (stats) or the summary (status) as JSON
  --line         status only: one line, as the Phase 3 wait shows it
  --session <id> status only: summarise this Dex session instead of the current one
  --root <dir>   stats only: read telemetry from this directory instead of $DX_RUN_ROOT
  -h, --help     Show this help
USAGE
}

REVIEW_COMMAND="${1:-}"
[[ $# -eq 0 ]] || shift

case "$REVIEW_COMMAND" in
  -h|--help|help|"")
    usage
    exit 0
    ;;
  stats)
    python3 "$DEX_DIR/scripts/review_stats.py" "$@"
    ;;
  status)
    STATUS_FORMAT=text
    STATUS_SESSION="${DEX_SESSION_ID:-}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) STATUS_FORMAT=json ;;
        --line) STATUS_FORMAT=line ;;
        --session)
          [[ $# -ge 2 ]] || { dx_error "--session needs a session id"; exit 2; }
          STATUS_SESSION="$2"
          shift
          ;;
        -h|--help) usage; exit 0 ;;
        *) dx_error "Unknown review status option: $1"; usage; exit 2 ;;
      esac
      shift
    done
    [[ -n "$STATUS_SESSION" ]] || STATUS_SESSION=$(dx_session_id)
    if ! dx_session_id_valid "$STATUS_SESSION"; then
      dx_error "Not a valid Dex session id: ${STATUS_SESSION}"
      exit 2
    fi
    dx_review_status "$STATUS_SESSION" "$STATUS_FORMAT"
    ;;
  *)
    dx_error "Unknown review command: ${REVIEW_COMMAND}"
    usage
    exit 2
    ;;
esac
