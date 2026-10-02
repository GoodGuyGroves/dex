# shellcheck shell=bash
# Dex shared library - ticket references and the workspace names built from
# them.
#
# A ticket reference is a bare number (`1234`, the GitHub Issues shape) or
# PREFIX-N (`ENG-1234`). A prefix only becomes part of the ticket ID when the
# project lists it under `## Tickets` in its `.dex/dex.md`:
#
#   ```yaml
#   ticket_prefixes: [ENG, OPS]
#   ```
#
# Without that list every ticket is its number, so ENG-1234 and OPS-1234 share
# the workspace ticket-1234, as they always have. With it, ENG-1234 and
# OPS-1234 are different tickets and get ticket-eng-1234 and ticket-ops-1234.
# Every place that turns user input or a branch into a ticket goes through
# here, so the digits are stripped in one place.

# dx_ticket_prefixes <repo-dir>
# The prefixes the project declared, upper case, deduplicated, one per line.
# Prints nothing when the repository declares none. An entry that is not 2-10
# letters and digits starting with a letter, or that is TICKET (Dex's own
# workspace prefix), is ignored with a warning, as is a block that is not a flat
# mapping.
dx_ticket_prefixes() {
  local ticket_repo="${1:-}" ticket_values="" ticket_rc=0
  local ticket_entry ticket_upper ticket_seen=" "
  [[ -n "$ticket_repo" ]] || return 0
  # Most repositories never set this, and dx reads it on every ticket command:
  # spare them the python3 start.
  grep -q 'ticket_prefixes' "$ticket_repo/.dex/dex.md" 2>/dev/null || return 0
  command -v dx_project_contract_values >/dev/null 2>&1 || return 0
  ticket_values=$(dx_project_contract_values "$ticket_repo" Tickets ticket_prefixes) \
    || ticket_rc=$?
  if [[ "$ticket_rc" -eq 2 ]]; then
    dx_warn "Ignoring '## Tickets' in ${ticket_repo}/.dex/dex.md: it is not a flat mapping."
    return 0
  fi
  [[ "$ticket_rc" -eq 0 ]] || return 0
  while IFS= read -r ticket_entry; do
    [[ -n "$ticket_entry" ]] || continue
    ticket_upper=$(printf '%s' "$ticket_entry" | tr '[:lower:]' '[:upper:]')
    if [[ ! "$ticket_upper" =~ ^[A-Z][A-Z0-9]{1,9}$ || "$ticket_upper" == TICKET ]]; then
      dx_warn "Ignoring ticket prefix '${ticket_entry}' in ${ticket_repo}/.dex/dex.md: use 2-10 letters and digits, starting with a letter."
      continue
    fi
    case "$ticket_seen" in
      *" ${ticket_upper} "*) continue ;;
    esac
    ticket_seen="${ticket_seen}${ticket_upper} "
    printf '%s\n' "$ticket_upper"
  done <<EOF
$ticket_values
EOF
}

# dx_ticket_parse <raw> [prefixes]
# Classify user input as a ticket reference. Sets _dx_ticket_id,
# _dx_ticket_number and _dx_ticket_prefix; returns 1, with all three empty,
# when the input is not a ticket. The ID is PREFIX-N only when the prefix is in
# the newline-separated <prefixes> list from dx_ticket_prefixes; otherwise it is
# the number. Pass no list to check the shape alone, which reads no config.
dx_ticket_parse() {
  local ticket_raw="${1:-}" ticket_prefixes="${2:-}" ticket_head ticket_upper
  _dx_ticket_id=""
  _dx_ticket_number=""
  _dx_ticket_prefix=""
  ticket_raw="${ticket_raw#"${ticket_raw%%[![:space:]]*}"}"
  ticket_raw="${ticket_raw%"${ticket_raw##*[![:space:]]}"}"
  if [[ "$ticket_raw" =~ ^[0-9]+$ ]]; then
    _dx_ticket_number="$ticket_raw"
    _dx_ticket_id="$ticket_raw"
    return 0
  fi
  [[ "$ticket_raw" =~ ^[A-Za-z][A-Za-z0-9]{1,9}-[0-9]+$ ]] || return 1
  _dx_ticket_number="${ticket_raw##*-}"
  _dx_ticket_id="$_dx_ticket_number"
  [[ -n "$ticket_prefixes" ]] || return 0
  ticket_head="${ticket_raw%-*}"
  ticket_upper=$(printf '%s' "$ticket_head" | tr '[:lower:]' '[:upper:]')
  # ticket-N is Dex's own workspace name, not a tracker prefix.
  [[ "$ticket_upper" != TICKET ]] || return 0
  if grep -qxF -- "$ticket_upper" <<< "$ticket_prefixes"; then
    _dx_ticket_prefix="$ticket_upper"
    _dx_ticket_id="${ticket_upper}-${_dx_ticket_number}"
  else
    dx_warn "${ticket_head} is not in ticket_prefixes; treating ${ticket_raw} as ticket ${_dx_ticket_number}."
  fi
  return 0
}

# dx_ticket_workspace_name <ticket-id>
# ENG-1234 -> ticket-eng-1234; 1234 -> ticket-1234.
dx_ticket_workspace_name() {
  local ticket_id="${1:-}"
  case "$ticket_id" in
    *-*) printf 'ticket-%s\n' "$(printf '%s' "$ticket_id" | tr '[:upper:]' '[:lower:]')" ;;
    *) printf 'ticket-%s\n' "$ticket_id" ;;
  esac
}

# dx_ticket_id_from_workspace_name <workspace-name>
# The ticket ID a Dex workspace name carries: ticket-eng-1234 -> ENG-1234,
# ticket-1234 -> 1234. Returns 1 for any other name. Reads no config, because
# Dex only writes a prefixed name for a configured prefix.
dx_ticket_id_from_workspace_name() {
  local ticket_name="${1:-}" ticket_rest
  [[ "$ticket_name" == ticket-* ]] || return 1
  ticket_rest="${ticket_name#ticket-}"
  if [[ "$ticket_rest" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ticket_rest"
    return 0
  fi
  [[ "$ticket_rest" =~ ^[a-z][a-z0-9]{1,9}-[0-9]+$ ]] || return 1
  printf '%s\n' "$ticket_rest" | tr '[:lower:]' '[:upper:]'
}

# ─── ticket_close: when Dex moves the ticket to Done ─────────────────────────
#
# `ticket_close` under `## Tickets` in `.dex/dex.md`:
#   on_complete  Phase 6 marks the ticket Done before merge (the default)
#   on_merge     Phase 6 posts the summary; the ticket closes once the pull
#                request merges (the deferred-teardown sweep does it)
#   never        Phase 6 posts the summary and leaves the status to the caller
# A run overrides the project with DEX_TICKET_CLOSE, which `dx run` sets from
# the run spec's workflow.ticket_close. See $DEX_DIR/docs/worktree-teardown.md.

# __dx_ticket_close_normalize <value>
# Print <value> in lower case when it is one of the three modes; return 1
# otherwise, printing nothing.
__dx_ticket_close_normalize() {
  local ticket_mode
  ticket_mode=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$ticket_mode" in
    on_complete | on_merge | never) printf '%s\n' "$ticket_mode" ;;
    *) return 1 ;;
  esac
}

# dx_ticket_close_setting <repo-dir>
# The project's ticket_close. An absent file, section or key gives
# on_complete. A value Dex does not recognise, or a `## Tickets` block that is
# not a flat mapping, gives never with a warning: a typo must not close a
# ticket earlier than the project asked for.
dx_ticket_close_setting() {
  local ticket_repo="${1:-}" ticket_value="" ticket_rc=0 ticket_mode
  # Most repositories never set this: spare them the python3 start.
  if [[ -z "$ticket_repo" ]] || ! grep -q 'ticket_close' "$ticket_repo/.dex/dex.md" 2>/dev/null \
    || ! command -v dx_project_contract_values >/dev/null 2>&1; then
    printf 'on_complete\n'
    return 0
  fi
  ticket_value=$(dx_project_contract_values "$ticket_repo" Tickets ticket_close 2>/dev/null) \
    || ticket_rc=$?
  if [[ "$ticket_rc" -eq 1 ]]; then
    printf 'on_complete\n'
    return 0
  fi
  if [[ "$ticket_rc" -ne 0 ]]; then
    dx_warn "Ignoring '## Tickets' in ${ticket_repo}/.dex/dex.md: it is not a flat mapping. Using ticket_close: never."
    printf 'never\n'
    return 0
  fi
  if ticket_mode=$(__dx_ticket_close_normalize "$ticket_value"); then
    printf '%s\n' "$ticket_mode"
    return 0
  fi
  dx_warn "Ignoring ticket_close: '${ticket_value}' in ${ticket_repo}/.dex/dex.md (expected on_complete, on_merge or never). Using never."
  printf 'never\n'
}

# dx_ticket_close_mode <repo-dir> [session-id]
# The ticket_close in force for a lifecycle: the value recorded in the
# session's .meta when it launched, then DEX_TICKET_CLOSE (a run override; an
# invalid value is ignored with a warning), then the project setting.
dx_ticket_close_mode() {
  local ticket_repo="${1:-}" ticket_sid="${2:-}" ticket_mode
  if [[ -n "$ticket_sid" ]] \
    && ticket_mode=$(__dx_ticket_close_normalize "$(dx_meta_read "$ticket_sid" ticket_close 2>/dev/null)"); then
    printf '%s\n' "$ticket_mode"
    return 0
  fi
  if [[ -n "${DEX_TICKET_CLOSE:-}" ]]; then
    if ticket_mode=$(__dx_ticket_close_normalize "$DEX_TICKET_CLOSE"); then
      printf '%s\n' "$ticket_mode"
      return 0
    fi
    dx_warn "Ignoring DEX_TICKET_CLOSE='${DEX_TICKET_CLOSE}' (expected on_complete, on_merge or never)."
  fi
  dx_ticket_close_setting "$ticket_repo"
}

# dx_ticket_tracker_kind <repo-dir>
# github when the `## Integrations` table in .dex/dex.md has an enabled
# "Ticket tracker" row naming GitHub Issues, other for any other enabled
# tracker, none otherwise. The ticket_close sweep closes only github tickets
# itself; Dex has no shell client for the others.
dx_ticket_tracker_kind() {
  local ticket_repo="${1:-}"
  [[ -n "$ticket_repo" && -f "$ticket_repo/.dex/dex.md" ]] || { printf 'none\n'; return 0; }
  awk -F'|' '
    /^[[:space:]]*##[[:space:]]/ { in_table = ($0 ~ /^[[:space:]]*##[[:space:]]+Integrations[[:space:]]*$/); next }
    in_table && $2 ~ /^[[:space:]]*[Tt]icket [Tt]racker[[:space:]]*$/ {
      tool = tolower($3); state = tolower($4)
      if (state !~ /enabled/ || state ~ /not/) { print "none"; found = 1; exit }
      print (tool ~ /github/ ? "github" : "other"); found = 1; exit
    }
    END { if (!found) print "none" }
  ' "$ticket_repo/.dex/dex.md"
}

# dx_ticket_close_snapshot <session-id> <repo-dir>
# Record the lifecycle's ticket_close in its .meta at launch, so Phase 6 and
# the merge sweep read the value the run started with after its environment
# is gone. A valid DEX_TICKET_CLOSE always replaces the record; otherwise a
# resume keeps the value it already has.
dx_ticket_close_snapshot() {
  local ticket_sid="${1:-}" ticket_repo="${2:-}" ticket_mode=""
  [[ -n "$ticket_sid" ]] || return 0
  if [[ -n "${DEX_TICKET_CLOSE:-}" ]]; then
    ticket_mode=$(__dx_ticket_close_normalize "$DEX_TICKET_CLOSE") \
      || dx_warn "Ignoring DEX_TICKET_CLOSE='${DEX_TICKET_CLOSE}' (expected on_complete, on_merge or never)."
  fi
  if [[ -z "$ticket_mode" ]]; then
    __dx_ticket_close_normalize "$(dx_meta_read "$ticket_sid" ticket_close)" >/dev/null && return 0
    ticket_mode=$(dx_ticket_close_setting "$ticket_repo")
  fi
  dx_meta_write "$ticket_sid" "ticket_close=${ticket_mode}"
}
