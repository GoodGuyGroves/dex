#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-hook-input-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DEX_SESSION_ID="hook-input-test"
export DEX_LOOP_PHASE=6
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

CAPTURE_SID="provider-session-capture"
CLAUDE_HANDLE="01999999-1111-4222-8333-444444444444"
CODEX_HANDLE="01999999-aaaa-4bbb-8ccc-dddddddddddd"
printf '%s\n' \
  "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CLAUDE_HANDLE\"}" \
  | DEX_SESSION_ID="$CAPTURE_SID" DX_PROVIDER_ENGINE=claude \
    bash "$ROOT/hooks/capture-provider-session.sh"
assert_eq "$CLAUDE_HANDLE" \
  "$(dx_agent_session_handle_read "$CAPTURE_SID" claude)" \
  "captured Claude session ID"
assert_eq "600" \
  "$(dx_path_mode "$(dx_agent_session_handle_file "$CAPTURE_SID" claude)")" \
  "Claude session ID permissions"

printf '%s\n' \
  "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$CODEX_HANDLE\"}" \
  | DEX_SESSION_ID="$CAPTURE_SID" DX_PROVIDER_ENGINE=codex-plugin \
    bash "$ROOT/hooks/capture-provider-session.sh"
assert_eq "$CODEX_HANDLE" \
  "$(dx_agent_session_handle_read "$CAPTURE_SID" codex)" \
  "captured Codex session ID"

INVALID_CAPTURE_SID="provider-session-invalid"
printf '%s\n' '{"hook_event_name":"Stop","session_id":"../unsafe"}' \
  | DEX_SESSION_ID="$INVALID_CAPTURE_SID" DX_PROVIDER_ENGINE=claude \
    bash "$ROOT/hooks/capture-provider-session.sh"
assert_no_file "$(dx_agent_session_handle_file "$INVALID_CAPTURE_SID" claude)"

PAUSE_FILE=$(dx_watch_pause_file "$DEX_SESSION_ID")
printf 'paused\n' > "$PAUSE_FILE"

printf '%s\n' '{"prompt":"Please resume watcher monitoring."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/resume.out"
[[ ! -f "$PAUSE_FILE" ]] || assert_at $LINENO
grep -q 'resumed scheduled Phase 6 watcher loops' "$TMP_DIR/resume.out"

printf 'paused\n' > "$PAUSE_FILE"
printf '%s\n' '{"prompt":"Do not resume watcher monitoring."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/negated.out"
[[ -f "$PAUSE_FILE" ]] || assert_at $LINENO
grep -q 'paused the scheduled PR watcher loop' "$TMP_DIR/negated.out"

printf '%s\n' '{"prompt":"Please do not run /dxcomplete yet."}' \
  | bash "$ROOT/hooks/user-prompt-submit.sh" > "$TMP_DIR/negated-command.out"
[[ -f "$PAUSE_FILE" ]] || assert_at $LINENO
grep -q 'paused the scheduled PR watcher loop' "$TMP_DIR/negated-command.out"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit --allow-empty -qm init
git -C "$REPO" checkout -qb ticket-12-ticket-34

(
  cd "$REPO"
  DEX_SESSION_ID="ticket-hook-test" bash "$ROOT/hooks/load-ticket-context.sh"
) > "$TMP_DIR/ticket.out"

grep -q '^Ticket number: 12$' "$TMP_DIR/ticket.out"
if grep -q '^34$' "$TMP_DIR/ticket.out"; then
  printf 'ticket hook emitted more than one ticket number\n' >&2
  exit 1
fi

# Ticket detection with and without `## Tickets` prefixes. The hook renders
# a stand-in instructions template so both placeholders are visible.
FAKE_DEX="$TMP_DIR/fake-dex"
mkdir -p "$FAKE_DEX/prompts"
ln -s "$ROOT/lib" "$FAKE_DEX/lib"
ln -s "$ROOT/scripts" "$FAKE_DEX/scripts"
printf 'Render: num={{TICKET_NUM}} id={{TICKET_ID}} branch={{BRANCH}}\n' \
  > "$FAKE_DEX/prompts/ticket-instructions.md"

PREFIXED_REPO="$TMP_DIR/prefixed-repo"
git init -q "$PREFIXED_REPO"
git -C "$PREFIXED_REPO" config user.email test@example.com
git -C "$PREFIXED_REPO" config user.name Test
mkdir -p "$PREFIXED_REPO/.dex"
printf '# Dex\n\n## Tickets\n\n```yaml\nticket_prefixes: [ENG, OPS]\n```\n' \
  > "$PREFIXED_REPO/.dex/dex.md"
git -C "$PREFIXED_REPO" add .dex/dex.md
git -C "$PREFIXED_REPO" commit -qm init

ticket_hook() {
  local repo="$1" branch="$2" out="$3"
  git -C "$repo" checkout -qB "$branch"
  (
    cd "$repo"
    DEX_DIR="$FAKE_DEX" DEX_SESSION_ID="ticket-hook-test" \
      bash "$ROOT/hooks/load-ticket-context.sh"
  ) > "$out"
}

# Configured: lowercase tracker branches and Dex's own prefixed branches.
ticket_hook "$PREFIXED_REPO" user/eng-1234-short-title "$TMP_DIR/lower.out"
grep -qx 'Ticket number: 1234' "$TMP_DIR/lower.out"
grep -qx 'Ticket ID: ENG-1234' "$TMP_DIR/lower.out"
grep -qx 'Render: num=1234 id=ENG-1234 branch=user/eng-1234-short-title' "$TMP_DIR/lower.out"
ticket_hook "$PREFIXED_REPO" worktree-ticket-ops-77 "$TMP_DIR/dex-branch.out"
grep -qx 'Render: num=77 id=OPS-77 branch=worktree-ticket-ops-77' "$TMP_DIR/dex-branch.out"
ticket_hook "$PREFIXED_REPO" feature/OPS-9 "$TMP_DIR/upper.out"
grep -qx 'Ticket ID: OPS-9' "$TMP_DIR/upper.out"
# A number-only Dex branch keeps its plain output.
ticket_hook "$PREFIXED_REPO" worktree-ticket-1234 "$TMP_DIR/bare.out"
grep -qx 'Ticket number: 1234' "$TMP_DIR/bare.out"
if grep -q '^Ticket ID:' "$TMP_DIR/bare.out"; then
  printf 'ticket hook printed a prefixed ID for a bare ticket\n' >&2
  exit 1
fi
grep -qx 'Render: num=1234 id=1234 branch=worktree-ticket-1234' "$TMP_DIR/bare.out"
# Only the configured prefixes count, and only as a whole word.
for not_ticket_branch in feature/add-3-things fix/reeng-12 FOO-12-thing v-2; do
  ticket_hook "$PREFIXED_REPO" "$not_ticket_branch" "$TMP_DIR/not-ticket.out"
  grep -q 'No ticket number detected' "$TMP_DIR/not-ticket.out" || {
    printf 'ticket hook detected a ticket in %s\n' "$not_ticket_branch" >&2
    exit 1
  }
done

# Unconfigured: lowercase is still not a ticket, uppercase still is, and the
# output has no Ticket ID line.
git -C "$REPO" checkout -qb user/eng-1234-short-title
(
  cd "$REPO"
  DEX_DIR="$FAKE_DEX" DEX_SESSION_ID="ticket-hook-test" bash "$ROOT/hooks/load-ticket-context.sh"
) > "$TMP_DIR/plain-lower.out"
grep -q 'No ticket number detected' "$TMP_DIR/plain-lower.out"
git -C "$REPO" checkout -qb feature/ENG-123
(
  cd "$REPO"
  DEX_DIR="$FAKE_DEX" DEX_SESSION_ID="ticket-hook-test" bash "$ROOT/hooks/load-ticket-context.sh"
) > "$TMP_DIR/plain-upper.out"
grep -qx 'Ticket number: 123' "$TMP_DIR/plain-upper.out"
grep -qx 'Render: num=123 id=123 branch=feature/ENG-123' "$TMP_DIR/plain-upper.out"
if grep -q '^Ticket ID:' "$TMP_DIR/plain-upper.out"; then
  printf 'unconfigured ticket hook printed a Ticket ID line\n' >&2
  exit 1
fi

# Context providers: the SessionStart hook appends a project's recall after
# Dex's own context, labelled unverified, and keeps the whole output inside
# Claude Code's 10,000-character hook budget even with the real ticket
# instructions and a provider that prints far more.
PROVIDER_REPO="$TMP_DIR/provider-repo"
git init -q "$PROVIDER_REPO"
git -C "$PROVIDER_REPO" config user.email test@example.com
git -C "$PROVIDER_REPO" config user.name Test
mkdir -p "$PROVIDER_REPO/.dex"
printf '# Dex\n\n## Context Providers\n\n```yaml\nsession_start: echo "recalled for $DX_TICKET_ID at phase $DX_PHASE"; touch "$HOME/.provider-ran"\n```\n' \
  > "$PROVIDER_REPO/.dex/dex.md"
git -C "$PROVIDER_REPO" add .dex/dex.md
git -C "$PROVIDER_REPO" commit -qm init
git -C "$PROVIDER_REPO" checkout -qb worktree-ticket-55

provider_hook() {
  (
    cd "$PROVIDER_REPO"
    DEX_SESSION_ID="ticket-hook-test" DEX_LOOP_PHASE=0 bash "$ROOT/hooks/load-ticket-context.sh"
  )
}

rm -f "$HOME/.provider-ran"
DEX_LAUNCHED=1 provider_hook > "$TMP_DIR/provider.out"
grep -qx 'Ticket number: 55' "$TMP_DIR/provider.out" || assert_at $LINENO
grep -qx -- '--- External recall (unverified; verify against current code before relying on it) ---' \
  "$TMP_DIR/provider.out" || assert_at $LINENO
grep -qx 'recalled for 55 at phase 0' "$TMP_DIR/provider.out" || assert_at $LINENO
# Dex's own context comes first, the recall after it.
[[ "$(grep -n '^Ticket number:' "$TMP_DIR/provider.out" | cut -d: -f1)" -lt \
  "$(grep -n '^--- External recall' "$TMP_DIR/provider.out" | cut -d: -f1)" ]] || assert_at $LINENO

rm -f "$HOME/.provider-ran"
DEX_LAUNCHED=1 DEX_REVIEW_PASS_ACTIVE=1 provider_hook > "$TMP_DIR/provider-review.out"
assert_not_contains 'External recall' "$TMP_DIR/provider-review.out"
assert_no_file "$HOME/.provider-ran"
DEX_LAUNCHED=1 DEX_REVIEW_ASSESSMENT_ACTIVE=1 provider_hook > "$TMP_DIR/provider-assess.out"
assert_not_contains 'External recall' "$TMP_DIR/provider-assess.out"
assert_no_file "$HOME/.provider-ran"
(unset DEX_LAUNCHED; provider_hook) > "$TMP_DIR/provider-plain.out"
assert_not_contains 'External recall' "$TMP_DIR/provider-plain.out"
assert_no_file "$HOME/.provider-ran"

printf '# Dex\n\n## Context Providers\n\n```yaml\nsession_start: python3 -c "print(\\"z\\" * 50000)"\nmax_chars: 32000\n```\n' \
  > "$PROVIDER_REPO/.dex/dex.md"
DEX_LAUNCHED=1 provider_hook > "$TMP_DIR/provider-big.out"
grep -q '^\[truncated: kept ' "$TMP_DIR/provider-big.out" || assert_at $LINENO
grep -qx 'Ticket number: 55' "$TMP_DIR/provider-big.out" || assert_at $LINENO
big_chars=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' \
  "$TMP_DIR/provider-big.out")
[[ "$big_chars" -le 10000 ]] || fail "SessionStart output is ${big_chars} characters, over 10,000"

printf 'hook input tests passed\n'
