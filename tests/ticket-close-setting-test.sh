#!/usr/bin/env bash
# ticket_close: the `## Tickets` setting, the DEX_TICKET_CLOSE run override, the
# launch snapshot in .meta, and the tracker kind read from `## Integrations`.
# Runs the same table under bash and zsh, since lib/ticket.sh is sourced by
# both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ticket-close-setting.XXXXXX")"
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
unset DEX_TICKET_CLOSE
mkdir -p "$HOME" "$DX_STATE_DIR"

make_repo() {
  local repo="$1" body="${2:-}"
  mkdir -p "$repo/.dex"
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body" > "$repo/.dex/dex.md"
  fi
}

tickets_block() {
  printf '# Dex\n\n## Tickets\n\n```yaml\n%s\n```\n' "$1"
}

export REPO_NONE="$TMP_DIR/none"
export REPO_NO_SECTION="$TMP_DIR/no-section"
export REPO_PREFIXES="$TMP_DIR/prefixes"
export REPO_MERGE="$TMP_DIR/merge"
export REPO_NEVER="$TMP_DIR/never"
export REPO_COMPLETE="$TMP_DIR/complete"
export REPO_UPPER="$TMP_DIR/upper"
export REPO_TYPO="$TMP_DIR/typo"
export REPO_LIST="$TMP_DIR/list"
export REPO_MALFORMED="$TMP_DIR/malformed"
export REPO_PROSE="$TMP_DIR/prose"
mkdir -p "$REPO_NONE"
make_repo "$REPO_NO_SECTION" '# Dex

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | GitHub Issues (`gh`) | enabled |'
make_repo "$REPO_PREFIXES" "$(tickets_block 'ticket_prefixes: [ENG]')"
make_repo "$REPO_MERGE" "$(tickets_block 'ticket_prefixes: [ENG]
ticket_close: on_merge')"
make_repo "$REPO_NEVER" "$(tickets_block 'ticket_close: never')"
make_repo "$REPO_COMPLETE" "$(tickets_block 'ticket_close: on_complete')"
make_repo "$REPO_UPPER" "$(tickets_block 'ticket_close: On_Merge')"
make_repo "$REPO_TYPO" "$(tickets_block 'ticket_close: on_mrege')"
make_repo "$REPO_LIST" "$(tickets_block 'ticket_close: [on_merge, never]')"
make_repo "$REPO_MALFORMED" "$(tickets_block 'ticket_close:
  nested: on_merge')"
make_repo "$REPO_PROSE" '# Dex

Nothing here sets ticket_close yet.'

export REPO_LINEAR="$TMP_DIR/linear"
export REPO_OFF="$TMP_DIR/off"
export REPO_TEMPLATE="$TMP_DIR/template"
make_repo "$REPO_LINEAR" '# Dex

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | Linear MCP | enabled |'
make_repo "$REPO_OFF" '# Dex

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | GitHub Issues | not configured |'
make_repo "$REPO_TEMPLATE" '# Dex

## Other

| Ticket tracker | GitHub Issues | enabled |

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Design | Figma MCP | enabled |'

# The assertions are written once and run in each shell. Each shell gets
# assert_at, not helpers.sh and its bash-only ERR trap.
cat > "$TMP_DIR/cases.sh" <<'CASES'
set -e
source "$DEX_DIR/lib/common.sh"
unset DEX_TICKET_CLOSE

setting() {
  dx_ticket_close_setting "$1" 2>"$TMP_DIR/setting.err"
}

# Existing dex.md files keep today's behaviour: every setting is optional.
[[ "$(setting "$REPO_NONE")" == on_complete && ! -s "$TMP_DIR/setting.err" ]] || assert_at $LINENO
[[ "$(setting "$REPO_NO_SECTION")" == on_complete && ! -s "$TMP_DIR/setting.err" ]] || assert_at $LINENO
[[ "$(setting "$REPO_PREFIXES")" == on_complete && ! -s "$TMP_DIR/setting.err" ]] || assert_at $LINENO
[[ "$(setting "$REPO_PROSE")" == on_complete && ! -s "$TMP_DIR/setting.err" ]] || assert_at $LINENO
[[ "$(setting "")" == on_complete ]] || assert_at $LINENO

# Each value, in any case.
[[ "$(setting "$REPO_MERGE")" == on_merge && ! -s "$TMP_DIR/setting.err" ]] || assert_at $LINENO
[[ "$(setting "$REPO_NEVER")" == never ]] || assert_at $LINENO
[[ "$(setting "$REPO_COMPLETE")" == on_complete ]] || assert_at $LINENO
[[ "$(setting "$REPO_UPPER")" == on_merge && ! -s "$TMP_DIR/setting.err" ]] || assert_at $LINENO

# A value Dex does not recognise closes nothing early: never, with a warning.
[[ "$(setting "$REPO_TYPO")" == never ]] || assert_at $LINENO
grep -q "Ignoring ticket_close: 'on_mrege'" "$TMP_DIR/setting.err" || assert_at $LINENO
[[ "$(setting "$REPO_LIST")" == never ]] || assert_at $LINENO
grep -q "Ignoring ticket_close" "$TMP_DIR/setting.err" || assert_at $LINENO
[[ "$(setting "$REPO_MALFORMED")" == never ]] || assert_at $LINENO
grep -q "Ignoring '## Tickets'" "$TMP_DIR/setting.err" || assert_at $LINENO
# ticket_prefixes is unaffected by the new key.
[[ "$(dx_ticket_prefixes "$REPO_MERGE" 2>/dev/null)" == ENG ]] || assert_at $LINENO

mode() {
  dx_ticket_close_mode "$@" 2>"$TMP_DIR/mode.err"
}

# Precedence: launch snapshot, then the run override, then the project.
[[ "$(mode "$REPO_MERGE")" == on_merge ]] || assert_at $LINENO
[[ "$(DEX_TICKET_CLOSE=never mode "$REPO_MERGE")" == never ]] || assert_at $LINENO
[[ "$(DEX_TICKET_CLOSE=ON_MERGE mode "$REPO_NONE")" == on_merge ]] || assert_at $LINENO
[[ "$(DEX_TICKET_CLOSE= mode "$REPO_NEVER")" == never ]] || assert_at $LINENO
# An invalid run override is ignored with a warning; the project still applies.
[[ "$(DEX_TICKET_CLOSE=bogus mode "$REPO_MERGE")" == on_merge ]] || assert_at $LINENO
grep -q "Ignoring DEX_TICKET_CLOSE='bogus'" "$TMP_DIR/mode.err" || assert_at $LINENO
[[ "$(DEX_TICKET_CLOSE=bogus mode "$REPO_NONE")" == on_complete ]] || assert_at $LINENO

sid="repo-test-1234-worktree-ticket-7"
[[ "$(mode "$REPO_MERGE" "$sid")" == on_merge ]] || assert_at $LINENO
dx_meta_write "$sid" "ticket_close=never"
[[ "$(mode "$REPO_MERGE" "$sid")" == never ]] || assert_at $LINENO
[[ "$(DEX_TICKET_CLOSE=on_merge mode "$REPO_MERGE" "$sid")" == never ]] || assert_at $LINENO
# A damaged snapshot falls through to the run override and the project.
dx_meta_write "$sid" "ticket_close=garbage"
[[ "$(DEX_TICKET_CLOSE=on_complete mode "$REPO_MERGE" "$sid")" == on_complete ]] || assert_at $LINENO
[[ "$(mode "$REPO_MERGE" "$sid")" == on_merge ]] || assert_at $LINENO
rm -f "$(dx_meta_file "$sid")"

# Tracker kind, from the Ticket tracker row of `## Integrations` only.
[[ "$(dx_ticket_tracker_kind "$REPO_NO_SECTION")" == github ]] || assert_at $LINENO
[[ "$(dx_ticket_tracker_kind "$REPO_LINEAR")" == other ]] || assert_at $LINENO
[[ "$(dx_ticket_tracker_kind "$REPO_OFF")" == none ]] || assert_at $LINENO
[[ "$(dx_ticket_tracker_kind "$REPO_TEMPLATE")" == none ]] || assert_at $LINENO
[[ "$(dx_ticket_tracker_kind "$REPO_PREFIXES")" == none ]] || assert_at $LINENO
[[ "$(dx_ticket_tracker_kind "$REPO_NONE")" == none ]] || assert_at $LINENO
[[ "$(dx_ticket_tracker_kind "")" == none ]] || assert_at $LINENO
CASES

bash -c "$(declare -f assert_at)"$'\n''source "$1"' cases "$TMP_DIR/cases.sh"
zsh -fc "$(declare -f assert_at)"$'\n''source "$1"' cases "$TMP_DIR/cases.sh"

# A repository that never mentions ticket_close must not pay for a python3
# start whenever Dex resolves the mode.
mkdir -p "$TMP_DIR/stub-bin"
# A shell stub, written with printf so tests/inline-python.py does not read
# it as Python.
printf '%s\n' '#!/bin/sh' 'echo "python3 ran" >> "$PYTHON_LOG"' 'exit 1' \
  > "$TMP_DIR/stub-bin/python3"
chmod +x "$TMP_DIR/stub-bin/python3"
export PYTHON_LOG="$TMP_DIR/python.log"
bash -c '
  source "$DEX_DIR/lib/common.sh"
  PATH="$1:$PATH"
  dx_ticket_close_mode "$REPO_PREFIXES" >/dev/null
  dx_ticket_close_mode "$REPO_NONE" >/dev/null
' stub "$TMP_DIR/stub-bin"
[[ ! -e "$PYTHON_LOG" ]] || assert_at $LINENO

printf 'ticket close setting tests passed\n'
