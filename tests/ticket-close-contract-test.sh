#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

# ticket_close: every Phase 6 text that used to say "close the ticket" has to
# follow the setting, or an agent marks the ticket Done before merge under
# on_merge and never.

COMPLETE="$ROOT/skills/dxcomplete/SKILL.md"
assert_file "$COMPLETE"
assert_contains 'dx_ticket_close_mode "$(git rev-parse --show-toplevel)" "$SESSION_ID"' "$COMPLETE"
assert_contains '- `on_complete` (the default): mark the ticket as Done' "$COMPLETE"
assert_contains '- `on_merge`: post the same final summary, but leave the ticket and its' "$COMPLETE"
assert_contains 'dx_ticket_close_items_add "$SESSION_ID" <id>...' "$COMPLETE"
assert_contains '- `never`: post the same final summary and leave every status as it is.' "$COMPLETE"
assert_contains 'Ticket close: <on_complete: marked Done | on_merge: closes when the PR merges | never: left to the caller>' "$COMPLETE"

AUDIT="$ROOT/prompts/phase-audits/6-complete.md"
assert_file "$AUDIT"
assert_contains 'mark it Done under `on_complete`; under `on_merge` or `never`, post the final summary and leave its status alone.' "$AUDIT"
assert_contains 'the ticket is handled per `ticket_close`:' "$AUDIT"
assert_not_contains 'the ticket is marked Done if a tracker is configured' "$AUDIT"
assert_not_contains 'Completion means the ticket is closed' "$AUDIT"

PR="$ROOT/prompts/workflows/dxpr.md"
assert_file "$PR"
assert_contains '- `on_complete` (the default): reference the ticket as you do today; this' "$PR"
assert_contains '- `on_merge` on GitHub Issues: add a `Closes #N` line for the ticket and one' "$PR"
assert_contains '- `never` on GitHub Issues: reference the ticket as `Refs #N` and use no' "$PR"

# The handoff and orchestrator texts no longer say "close the ticket".
for text in "$ROOT/hooks/phase-loop.sh" "$ROOT/dx.sh" "$ROOT/prompts/workflows/dxwatchpr.md" \
  "$ROOT/prompts/workflows/dxpr.md" "$ROOT/skills/dex/SKILL.md" "$COMPLETE" "$AUDIT"; do
  if grep -n -i -E 'close (the )?ticket (when|once|only)|and close the ticket|Update the tracker to Done|Ticket updated to Done' "$text"; then
    fail "${text#"$ROOT"/} still closes the ticket regardless of ticket_close"
  fi
done
assert_contains 'settle the ticket per ticket_close (mark it Done under on_complete; under on_merge or never post the summary and leave its status)' "$ROOT/hooks/phase-loop.sh"
assert_contains 'settle the ticket per ticket_close when CI is green' "$ROOT/dx.sh"
assert_contains 'Ticket settled per `ticket_close` (if tracker configured)' "$ROOT/skills/dex/SKILL.md"

# Docs and the init template describe the setting.
assert_contains 'ticket_close: on_complete' "$ROOT/prompts/init-analysis.md"
assert_contains '## Ticket close' "$ROOT/docs/worktree-teardown.md"
assert_contains '`workflow.ticket_close`' "$ROOT/docs/run-specs.md"
assert_contains 'DEX_TICKET_CLOSE' "$ROOT/docs/reference.md"

printf 'ticket close contract tests passed\n'
