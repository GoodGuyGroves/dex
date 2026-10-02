# shellcheck shell=bash
# Dex shared library - context providers.
#
# A project can name a command under `## Context Providers` in its
# `.dex/dex.md` that recalls context from the team's own memory or knowledge
# tool. Dex runs it at session start (hooks/load-ticket-context.sh) and at each
# phase handoff (hooks/phase-loop.sh), and injects its output labelled as
# unverified, because nothing about it has been reviewed the way `.dex/memory/`
# has. See docs/context-providers.md.

DEX_CONTEXT_PROVIDER_TIMEOUT_DEFAULT=20
# Session start and handoff both wait on the command, so a typo cannot hold a
# session for Claude Code's own ten-minute hook default.
DEX_CONTEXT_PROVIDER_TIMEOUT_MAX=45
DEX_CONTEXT_PROVIDER_MAX_CHARS_DEFAULT=8000
DEX_CONTEXT_PROVIDER_MAX_CHARS_MIN=200
DEX_CONTEXT_PROVIDER_MAX_CHARS_MAX=32000
# Claude Code keeps at most 10,000 characters of a hook's plain stdout. Over
# that it swaps the whole output for a file path and a short preview, which
# would hide the ticket instructions printed before the provider. Session start
# therefore gives the provider only what is left, less a margin.
DEX_CONTEXT_PROVIDER_HOOK_OUTPUT_LIMIT=10000
DEX_CONTEXT_PROVIDER_HOOK_OUTPUT_MARGIN=500

DEX_CONTEXT_PROVIDER_HEADER='--- External recall (unverified; verify against current code before relying on it) ---'
DEX_CONTEXT_PROVIDER_FOOTER='--- End external recall ---'

# __dx_context_provider_skipped <slot>
# Returns 0 when this session must not run a provider. Review passes and the
# risk assessor are independent and memory-free, so they get no recall. A
# session start outside a Dex launch is a plain session that happens to have
# Dex's hooks installed; it does not run a repository's command.
__dx_context_provider_skipped() {
  [[ "${DEX_REVIEW_PASS_ACTIVE:-0}" == 1 ]] && return 0
  [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == 1 ]] && return 0
  if [[ "$1" == session_start && "${DEX_LAUNCHED:-}" != 1 ]]; then
    return 0
  fi
  return 1
}

# __dx_context_provider_journal <session_id> <type> <severity> <message> <phase> <data_json>
# Non-fatal by construction: a session without a run journal records nothing.
__dx_context_provider_journal() {
  command -v dx_event_emit_for_session >/dev/null 2>&1 || return 0
  dx_event_emit_for_session "$1" "context_provider.$2" "$3" "$4" "$5" "$6" \
    >/dev/null 2>&1 || true
}

# __dx_context_provider_limit <repo> <key> <default> <min> <max>
# The declared limit clamped to [min, max], or the default when it is absent.
# Prints "<value> invalid" when the declaration is not a whole number, so the
# caller can journal it once.
__dx_context_provider_limit() {
  local limit_repo="$1" limit_key="$2" limit_default="$3" limit_min="$4" limit_max="$5"
  local limit_raw="" limit_rc=0
  limit_raw=$(dx_project_context_provider "$limit_repo" "$limit_key" 2>/dev/null) \
    || limit_rc=$?
  if [[ "$limit_rc" -ne 0 || -z "$limit_raw" ]]; then
    printf '%s\n' "$limit_default"
    return 0
  fi
  if [[ ! "$limit_raw" =~ ^[0-9]+$ ]] || [[ ${#limit_raw} -gt 6 ]]; then
    printf '%s invalid\n' "$limit_default"
    return 0
  fi
  limit_raw=$((10#$limit_raw))
  [[ "$limit_raw" -lt "$limit_min" ]] && limit_raw="$limit_min"
  [[ "$limit_raw" -gt "$limit_max" ]] && limit_raw="$limit_max"
  printf '%s\n' "$limit_raw"
}

# __dx_context_provider_ticket_id <session_id> <worktree_dir>
# The session's recorded ticket, else the one the worktree's name carries
# (ticket-142), else the one Dex's lifecycle branch carries (worktree-ticket-142),
# which is what an in-place session has.
__dx_context_provider_ticket_id() {
  local id_value="" id_branch=""
  if [[ -n "$1" ]] && command -v dx_meta_read >/dev/null 2>&1; then
    id_value=$(dx_meta_read "$1" ticket_id 2>/dev/null || true)
    [[ -n "$id_value" ]] || id_value=$(dx_meta_read "$1" tracker_key 2>/dev/null || true)
  fi
  command -v dx_ticket_id_from_workspace_name >/dev/null 2>&1 || {
    printf '%s' "$id_value"
    return 0
  }
  [[ -n "$id_value" ]] || id_value=$(dx_ticket_id_from_workspace_name "${2##*/}" 2>/dev/null || true)
  if [[ -z "$id_value" ]]; then
    id_branch=$(git -C "$2" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ "$id_branch" == worktree-ticket-* ]] \
      && id_value=$(dx_ticket_id_from_workspace_name "${id_branch#worktree-}" 2>/dev/null || true)
  fi
  printf '%s' "$id_value"
}

# __dx_context_provider_ticket_title <session_id>
# Phase 0 records the tracker's title; before that only `dx --title` or a run
# spec supplies one.
__dx_context_provider_ticket_title() {
  local title_value=""
  if [[ -n "$1" ]] && command -v dx_meta_read >/dev/null 2>&1; then
    title_value=$(dx_meta_read "$1" ticket_title 2>/dev/null || true)
  fi
  [[ -n "$title_value" ]] || title_value="${DEX_SESSION_TITLE:-}"
  if command -v dx_session_title_sanitize >/dev/null 2>&1; then
    title_value=$(dx_session_title_sanitize "$title_value")
  fi
  printf '%s' "$title_value"
}

# __dx_context_provider_render <slot> <phase> <max_chars> <budget> <raw_file> <block_file>
# Sanitise the provider's stdout and wrap it. Writes the block to block_file
# and prints "<raw_chars> <kept_chars>" (both of the cleaned text). Exits 3
# when nothing is left to inject and 4 when the budget cannot hold a block.
__dx_context_provider_render() {
  python3 - "$@" "$DEX_CONTEXT_PROVIDER_HEADER" "$DEX_CONTEXT_PROVIDER_FOOTER" \
    "$DEX_CONTEXT_PROVIDER_MAX_CHARS_MIN" <<'PY'
import re
import sys

slot, phase, max_chars, budget, raw_path, block_path, header, footer, floor = sys.argv[1:10]
max_chars, budget, floor = int(max_chars), int(budget), int(floor)

with open(raw_path, "rb") as handle:
    text = handle.read().decode("utf-8", errors="replace")

# Terminal escapes and control characters other than newline and tab.
text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
text = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", text)
text = text.replace("\r\n", "\n").replace("\r", "\n")
text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
# A line that reads like either marker could end the block early or open a
# second one, so the provider cannot write one.
markers = {header.strip(), footer.strip()}
text = "\n".join(line for line in text.split("\n") if line.strip() not in markers)
text = text.strip("\n")
if not text.strip():
    sys.exit(3)

source = f"Source: .dex/dex.md Context Providers ({slot}, phase {phase})"
overhead = len(header) + len(source) + len(footer) + 3
allowed = max_chars
if budget >= 0:
    allowed = min(allowed, budget - overhead)
if allowed < floor:
    print(f"{len(text)} 0")
    sys.exit(4)

total = len(text)
if total > allowed:
    note_room = len(f"\n[truncated: kept {allowed} of {total} characters]")
    kept = max(0, allowed - note_room)
    text = text[:kept].rstrip("\n") + f"\n[truncated: kept {kept} of {total} characters]"
else:
    kept = total

with open(block_path, "w", encoding="utf-8") as handle:
    handle.write(f"{header}\n{source}\n{text}\n{footer}\n")
print(f"{total} {kept}")
PY
}

# dx_context_provider_block <session_start|phase_handoff> <phase> <session_id> [printed_chars]
#
# Run the project's provider for one moment and print the wrapped block, or
# nothing. printed_chars is how much the calling hook has already written to
# stdout; at session start it is taken off the 10,000-character hook budget.
#
# Always returns 0: a missing section, a failing command, a timeout or an
# oversize answer never stops a session or a handoff. Failures are reported
# with dx_warn on stderr and journalled as context_provider.failed.
dx_context_provider_block() {
  local slot="${1:-}" phase="${2:-0}" session_id="${3:-}" printed="${4:-0}"
  local repo="" worktree="" provider_cmd="" read_rc=0 limit_line=""
  local timeout_secs max_chars budget=-1 limit_invalid=""
  local scratch_dir="" out_file="" err_file="" files_file="" block_file=""
  local run_rc=0 render_rc=0 render_stats="" base_ref="" raw_chars kept_chars
  local scratch_prefix="" capture_bytes=0

  case "$slot" in
    session_start | phase_handoff) ;;
    *) return 0 ;;
  esac
  [[ "$phase" =~ ^[0-9]+$ ]] || phase=0
  [[ "$printed" =~ ^[0-9]+$ ]] || printed=0
  __dx_context_provider_skipped "$slot" && return 0
  command -v dx_run_with_timeout >/dev/null 2>&1 || return 0

  worktree=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  repo=$(dx_repo_root 2>/dev/null) || repo=""
  [[ -n "$repo" ]] || repo="$worktree"
  # Every session start and handoff comes through here, and most projects
  # declare nothing: one grep for the heading, the shape
  # scripts/project-contract.py matches, spares them a Python start.
  grep -qiE '^#{1,6}[[:space:]]+Context Providers[[:space:]]*$' \
    "$repo/.dex/dex.md" 2>/dev/null || return 0

  provider_cmd=$(dx_project_context_provider "$repo" "$slot" 2>/dev/null) || read_rc=$?
  if [[ "$read_rc" -eq 2 ]]; then
    dx_warn "Ignoring '## Context Providers' in ${repo}/.dex/dex.md: it is not a flat mapping."
    __dx_context_provider_journal "$session_id" failed warn \
      "Context provider block is malformed" "$phase" \
      "{\"slot\":\"${slot}\",\"reason\":\"malformed\"}"
    return 0
  fi
  [[ "$read_rc" -eq 0 && -n "$provider_cmd" ]] || return 0
  if [[ "$provider_cmd" == *$'\n'* ]]; then
    dx_warn "Ignoring the ${slot} context provider: it must be one shell command, not a list."
    __dx_context_provider_journal "$session_id" failed warn \
      "Context provider is a list, not one command" "$phase" \
      "{\"slot\":\"${slot}\",\"reason\":\"malformed\"}"
    return 0
  fi

  limit_line=$(__dx_context_provider_limit "$repo" timeout_seconds \
    "$DEX_CONTEXT_PROVIDER_TIMEOUT_DEFAULT" 1 "$DEX_CONTEXT_PROVIDER_TIMEOUT_MAX")
  timeout_secs="${limit_line%% *}"
  [[ "$limit_line" == *" invalid" ]] && limit_invalid="timeout_seconds"
  limit_line=$(__dx_context_provider_limit "$repo" max_chars \
    "$DEX_CONTEXT_PROVIDER_MAX_CHARS_DEFAULT" "$DEX_CONTEXT_PROVIDER_MAX_CHARS_MIN" \
    "$DEX_CONTEXT_PROVIDER_MAX_CHARS_MAX")
  max_chars="${limit_line%% *}"
  [[ "$limit_line" == *" invalid" ]] && limit_invalid="${limit_invalid:+${limit_invalid},}max_chars"
  if [[ -n "$limit_invalid" ]]; then
    dx_warn "Context providers: ${limit_invalid} in .dex/dex.md is not a whole number; using the default."
    __dx_context_provider_journal "$session_id" failed warn \
      "Context provider limit is not a whole number" "$phase" \
      "{\"slot\":\"${slot}\",\"reason\":\"invalid_limit\",\"keys\":\"${limit_invalid}\"}"
  fi

  if [[ "$slot" == session_start ]]; then
    budget=$((DEX_CONTEXT_PROVIDER_HOOK_OUTPUT_LIMIT - DEX_CONTEXT_PROVIDER_HOOK_OUTPUT_MARGIN - printed))
    # Below the floor plus the wrapper there is no room for a useful answer,
    # so the command is not worth running.
    if [[ "$budget" -lt $((DEX_CONTEXT_PROVIDER_MAX_CHARS_MIN + 300)) ]]; then
      __dx_context_provider_journal "$session_id" failed warn \
        "No room left in the session-start output for context provider recall" "$phase" \
        "{\"slot\":\"${slot}\",\"reason\":\"no_budget\",\"printed\":${printed}}"
      return 0
    fi
  fi

  # Captures live in Dex's own state directory, never in the repository or a
  # shared temp directory, and are removed before returning.
  # They carry the session ID so dx_cleanup_session sweeps any a killed hook
  # left behind.
  scratch_dir="${DX_LOOP_DIR:-}"
  [[ -n "$scratch_dir" ]] || return 0
  mkdir -p "$scratch_dir" 2>/dev/null || return 0
  scratch_prefix="context"
  if command -v dx_session_id_valid >/dev/null 2>&1 && dx_session_id_valid "$session_id"; then
    scratch_prefix="$session_id"
  fi
  scratch_prefix="$scratch_dir/${scratch_prefix}.context-provider"
  out_file=$(mktemp "${scratch_prefix}.out.XXXXXX" 2>/dev/null) || return 0
  err_file=$(mktemp "${scratch_prefix}.err.XXXXXX" 2>/dev/null) || err_file=""
  files_file=$(mktemp "${scratch_prefix}.files.XXXXXX" 2>/dev/null) || files_file=""
  block_file=$(mktemp "${scratch_prefix}.block.XXXXXX" 2>/dev/null) || block_file=""
  if [[ -z "$err_file" || -z "$files_file" || -z "$block_file" ]]; then
    rm -f "$out_file" "$err_file" "$files_file" "$block_file"
    return 0
  fi

  # The changed-file list never fetches: the hook must not wait on a network.
  if base_ref=$(dx_default_branch_base_ref "$worktree" "" no-fetch 2>/dev/null) \
    && [[ -n "$base_ref" ]]; then
    git -C "$worktree" diff --name-only "${base_ref}...HEAD" -- >"$files_file" 2>/dev/null \
      || : >"$files_file"
  fi

  # stdout is cut at four bytes a character, the most UTF-8 needs, so a
  # runaway provider fills a bounded file rather than the disk. The command's
  # own exit status is kept; head closing the pipe early shows up as SIGPIPE.
  capture_bytes=$((max_chars * 4 + 4096))
  dx_run_with_timeout "$timeout_secs" env \
    DX_TICKET_ID="$(__dx_context_provider_ticket_id "$session_id" "$worktree")" \
    DX_TICKET_TITLE="$(__dx_context_provider_ticket_title "$session_id")" \
    DX_PHASE="$phase" \
    DX_REPO_ROOT="$repo" \
    DX_WORKTREE_NAME="${worktree##*/}" \
    DX_SESSION_ID="$session_id" \
    DX_CHANGED_FILES="$files_file" \
    bash -c 'cd "$1" || exit 1; cap="$2"; shift 2; (eval "$1") | head -c "$cap"; exit "${PIPESTATUS[0]}"' \
    dex-context-provider "$worktree" "$capture_bytes" "$provider_cmd" \
    </dev/null >"$out_file" 2>"$err_file" || run_rc=$?
  # A provider stopped by the cap printed more than can be injected anyway:
  # that is oversize output to truncate, not a failure.
  if [[ "$run_rc" -ne 0 && "$run_rc" -ne 124 ]] \
    && [[ "$(wc -c <"$out_file" | tr -d ' ')" -ge "$capture_bytes" ]]; then
    run_rc=0
  fi

  if [[ "$run_rc" -eq 124 ]]; then
    dx_warn "The ${slot} context provider passed ${timeout_secs}s and was stopped. Continuing without it."
    __dx_context_provider_journal "$session_id" failed warn \
      "Context provider timed out" "$phase" \
      "{\"slot\":\"${slot}\",\"reason\":\"timeout\",\"timeout_seconds\":${timeout_secs}}"
  elif [[ "$run_rc" -ne 0 ]]; then
    dx_warn "The ${slot} context provider failed (exit ${run_rc}). Continuing without it."
    __dx_context_provider_journal "$session_id" failed warn \
      "Context provider exited non-zero" "$phase" \
      "{\"slot\":\"${slot}\",\"reason\":\"exit\",\"exit_code\":${run_rc}}"
  else
    render_stats=$(__dx_context_provider_render "$slot" "$phase" "$max_chars" "$budget" \
      "$out_file" "$block_file" 2>/dev/null) || render_rc=$?
    raw_chars="${render_stats%% *}"
    kept_chars="${render_stats##* }"
    case "$render_rc" in
      0)
        cat "$block_file"
        if [[ "$kept_chars" != "$raw_chars" ]]; then
          __dx_context_provider_journal "$session_id" truncated warn \
            "Context provider output was truncated" "$phase" \
            "{\"slot\":\"${slot}\",\"chars\":${raw_chars},\"kept\":${kept_chars},\"max_chars\":${max_chars}}"
        fi
        __dx_context_provider_journal "$session_id" injected info \
          "Context provider output injected" "$phase" \
          "{\"slot\":\"${slot}\",\"chars\":${kept_chars}}"
        ;;
      3) ;;
      4)
        __dx_context_provider_journal "$session_id" failed warn \
          "No room left for context provider recall" "$phase" \
          "{\"slot\":\"${slot}\",\"reason\":\"no_budget\",\"printed\":${printed}}"
        ;;
      *)
        dx_warn "Could not read the ${slot} context provider's output. Continuing without it."
        __dx_context_provider_journal "$session_id" failed warn \
          "Context provider output could not be rendered" "$phase" \
          "{\"slot\":\"${slot}\",\"reason\":\"render\"}"
        ;;
    esac
  fi

  rm -f "$out_file" "$err_file" "$files_file" "$block_file"
  return 0
}
