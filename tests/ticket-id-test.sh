#!/usr/bin/env bash
# Ticket references: parsing, the optional `## Tickets` prefix list, and the
# workspace names built from them. Runs the same table under bash and zsh,
# since lib/ticket.sh is sourced by both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ticket-id.XXXXXX")"
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME"

make_repo() {
  local repo="$1" body="${2:-}"
  mkdir -p "$repo/.dex"
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body" > "$repo/.dex/dex.md"
  fi
}

export REPO_NONE="$TMP_DIR/none"
export REPO_PLAIN="$TMP_DIR/plain"
export REPO_SET="$TMP_DIR/set"
export REPO_BAD="$TMP_DIR/bad"
export REPO_MALFORMED="$TMP_DIR/malformed"
mkdir -p "$REPO_NONE"
make_repo "$REPO_PLAIN" '# Dex

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | Linear | enabled |'
make_repo "$REPO_SET" '# Dex

## Tickets

```yaml
ticket_prefixes: [eng, OPS, Eng]
```'
make_repo "$REPO_BAD" '# Dex

## Tickets

```yaml
ticket_prefixes:
  - ENG
  - E
  - TICKET
  - ABCDEFGHIJK
  - "1OPS"
  - ops
```'
make_repo "$REPO_MALFORMED" '# Dex

## Tickets

```yaml
ticket_prefixes:
  nested:
    - ENG
```'

# The assertions are written once and run in each shell. Each shell gets
# assert_at, not helpers.sh and its bash-only ERR trap.
cat > "$TMP_DIR/cases.sh" <<'CASES'
set -e
source "$DEX_DIR/lib/common.sh"

parse() {
  dx_ticket_parse "$1" "${2:-}" 2>"$TMP_DIR/parse.err"
}

# Shape: a bare number, or PREFIX-N with a 2-10 character prefix.
parse 1234 || assert_at $LINENO
[[ "$_dx_ticket_id" == 1234 && "$_dx_ticket_number" == 1234 && -z "$_dx_ticket_prefix" ]] || assert_at $LINENO
parse '  12  ' || assert_at $LINENO
[[ "$_dx_ticket_id" == 12 ]] || assert_at $LINENO
parse 0123 || assert_at $LINENO
[[ "$_dx_ticket_id" == 0123 ]] || assert_at $LINENO
parse ENG-1 || assert_at $LINENO
[[ "$_dx_ticket_id" == 1 && "$_dx_ticket_number" == 1 ]] || assert_at $LINENO
parse ticket-999 || assert_at $LINENO
[[ "$_dx_ticket_id" == 999 ]] || assert_at $LINENO
parse A1B2C3D4E5-7 || assert_at $LINENO
for not_ticket in ENG999 v-2 E-1 ABCDEFGHIJK-1 1ENG-2 ENG-1a 'ENG 1' '' '  ' fix-login 'ENG--1' '-1'; do
  if parse "$not_ticket"; then
    printf 'parsed a non-ticket: %s\n' "$not_ticket" >&2
    assert_at $LINENO
  fi
  [[ -z "$_dx_ticket_id" && -z "$_dx_ticket_number" ]] || assert_at $LINENO
done

# Without a prefix list the prefix is dropped, as Dex always did.
parse eng-1234 || assert_at $LINENO
[[ "$_dx_ticket_id" == 1234 && -z "$_dx_ticket_prefix" ]] || assert_at $LINENO
[[ ! -s "$TMP_DIR/parse.err" ]] || assert_at $LINENO

# With one, a listed prefix is part of the ID, in upper case.
prefixes=$(printf 'ENG\nOPS\n')
parse eng-1234 "$prefixes" || assert_at $LINENO
[[ "$_dx_ticket_id" == ENG-1234 && "$_dx_ticket_number" == 1234 && "$_dx_ticket_prefix" == ENG ]] || assert_at $LINENO
parse OPS-1234 "$prefixes" || assert_at $LINENO
[[ "$_dx_ticket_id" == OPS-1234 ]] || assert_at $LINENO
parse 1234 "$prefixes" || assert_at $LINENO
[[ "$_dx_ticket_id" == 1234 && -z "$_dx_ticket_prefix" ]] || assert_at $LINENO
[[ ! -s "$TMP_DIR/parse.err" ]] || assert_at $LINENO
# An unlisted prefix keeps working as its number, with a warning.
parse FOO-12 "$prefixes" || assert_at $LINENO
[[ "$_dx_ticket_id" == 12 && -z "$_dx_ticket_prefix" ]] || assert_at $LINENO
grep -q 'FOO is not in ticket_prefixes' "$TMP_DIR/parse.err" || assert_at $LINENO
# Dex's own ticket-N name is not a tracker prefix, so it does not warn.
parse ticket-12 "$prefixes" || assert_at $LINENO
[[ "$_dx_ticket_id" == 12 && ! -s "$TMP_DIR/parse.err" ]] || assert_at $LINENO

# Workspace names round-trip through the ticket ID.
[[ "$(dx_ticket_workspace_name 1234)" == ticket-1234 ]] || assert_at $LINENO
[[ "$(dx_ticket_workspace_name ENG-1234)" == ticket-eng-1234 ]] || assert_at $LINENO
[[ "$(dx_ticket_id_from_workspace_name ticket-1234)" == 1234 ]] || assert_at $LINENO
[[ "$(dx_ticket_id_from_workspace_name ticket-eng-1234)" == ENG-1234 ]] || assert_at $LINENO
[[ "$(dx_ticket_id_from_workspace_name ticket-a1b2-7)" == A1B2-7 ]] || assert_at $LINENO
for not_ticket_name in task-fix-login ticket- ticket-eng ticket-ENG-1 ticket-e-1 repo ''; do
  if dx_ticket_id_from_workspace_name "$not_ticket_name" >/dev/null; then
    printf 'read a ticket out of: %s\n' "$not_ticket_name" >&2
    assert_at $LINENO
  fi
done

# The prefix list: optional, validated, upper case, deduplicated.
[[ -z "$(dx_ticket_prefixes "$REPO_NONE" 2>&1)" ]] || assert_at $LINENO
[[ -z "$(dx_ticket_prefixes "$REPO_PLAIN" 2>&1)" ]] || assert_at $LINENO
[[ -z "$(dx_ticket_prefixes "" 2>&1)" ]] || assert_at $LINENO
[[ "$(dx_ticket_prefixes "$REPO_SET" 2>/dev/null)" == "$(printf 'ENG\nOPS')" ]] || assert_at $LINENO
[[ "$(dx_ticket_prefixes "$REPO_BAD" 2>"$TMP_DIR/bad.err")" == "$(printf 'ENG\nOPS')" ]] || assert_at $LINENO
grep -q "Ignoring ticket prefix 'E'" "$TMP_DIR/bad.err" || assert_at $LINENO
grep -q "Ignoring ticket prefix 'TICKET'" "$TMP_DIR/bad.err" || assert_at $LINENO
grep -q "Ignoring ticket prefix 'ABCDEFGHIJK'" "$TMP_DIR/bad.err" || assert_at $LINENO
grep -q "Ignoring ticket prefix '1OPS'" "$TMP_DIR/bad.err" || assert_at $LINENO
[[ -z "$(dx_ticket_prefixes "$REPO_MALFORMED" 2>"$TMP_DIR/malformed.err")" ]] || assert_at $LINENO
grep -q "Ignoring '## Tickets'" "$TMP_DIR/malformed.err" || assert_at $LINENO
CASES

bash -c "$(declare -f assert_at)"$'\n''source "$1"' cases "$TMP_DIR/cases.sh"
zsh -fc "$(declare -f assert_at)"$'\n''source "$1"' cases "$TMP_DIR/cases.sh"

# A repository that never mentions ticket_prefixes must not pay for a python3
# start on every dx command.
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
  dx_ticket_prefixes "$REPO_PLAIN" >/dev/null
  dx_ticket_prefixes "$REPO_NONE" >/dev/null
  dx_ticket_parse ENG-1 "" >/dev/null
' stub "$TMP_DIR/stub-bin"
[[ ! -e "$PYTHON_LOG" ]] || assert_at $LINENO

printf 'ticket id tests passed\n'
