# Context providers

Teams keep context in their own tools: a semantic memory store, a knowledge
base, notes from earlier work. A Dex session gets that context only if the
agent decides to call an MCP tool for it, and some phases launch with no MCP
servers at all.

A context provider is a command your repository names that prints recalled
context. Dex runs it at session start and at each phase handoff, and puts what
it prints in front of the agent, labelled as unverified. Dex's own
`.dex/memory/` stays the reviewed source of repository facts; provider output
sits beside it and is never treated as one of them.

## Declaring one

A fenced YAML block under `## Context Providers` in `.dex/dex.md`:

```yaml
session_start: bin/context recall
phase_handoff: bin/context recall --phase "$DX_PHASE"
timeout_seconds: 20
max_chars: 8000
```

Every key is optional, and so is the whole section. With none of it, nothing
runs and nothing changes. Dex reads the block from the main checkout, the same
`.dex/dex.md` every other section comes from.

| Key | Meaning | Default |
|-----|---------|---------|
| `session_start` | Run when Dex starts a new Claude session (the SessionStart `startup` event, so not on a resume). The output follows Dex's ticket context. | none |
| `phase_handoff` | Run when the lifecycle hands to the next phase, and when `dx control` moves it to another phase. The output goes into the handoff the agent reads. | none |
| `timeout_seconds` | How long one run may take before its process tree is stopped. Clamped to 1-45. | 20 |
| `max_chars` | The most characters of output Dex injects. Clamped to 200-32000. | 8000 |

Each command is **one shell command string**, run by `bash -c` in the
worktree. A list is refused with a warning, as for
[worktree hooks](worktree-hooks.md). Put a sequence in a script and name the
script.

## What the command gets

| Variable | Value |
|----------|-------|
| `DX_TICKET_ID` | The ticket (`142`, or `ENG-142`) when Dex knows one, empty otherwise |
| `DX_TICKET_TITLE` | The tracker's title, which Phase 0 records. Before Phase 0 has run, only `dx --title` or a run spec's title supplies it, so a provider must cope with an empty value at the first session start |
| `DX_PHASE` | The phase the context is for: the session's phase at session start, the phase being handed to at a handoff |
| `DX_REPO_ROOT` | The main checkout, where `.dex/dex.md` lives |
| `DX_WORKTREE_NAME` | The worktree's directory name (`ticket-142`) |
| `DX_SESSION_ID` | Dex's session ID |
| `DX_CHANGED_FILES` | Path to a file listing the paths the branch changes against the default branch, one per line. It always exists, and may be empty. Dex computes it without fetching and deletes it after the run |

stdin is `/dev/null`. stderr is discarded, never injected. stdout is read up to
four bytes per `max_chars` character (plus 4 KiB); a provider that keeps
printing past that is cut off there and its output truncated, not treated as
a failure.

## What the agent sees

```
--- External recall (unverified; verify against current code before relying on it) ---
Source: .dex/dex.md Context Providers (phase_handoff, phase 2)
...the provider's output...
--- End external recall ---
```

Before wrapping it, Dex:

- strips terminal escape sequences and control characters other than newline
  and tab,
- drops any line that repeats the header or the end marker, so output cannot
  close the block early or open a second one,
- cuts output over `max_chars` and ends it with
  `[truncated: kept N of M characters]`,
- injects nothing when the output is empty or only whitespace.

Treat a provider like any other code your repository runs: the content is not
filtered beyond this, and the label is what tells the agent to check it
against the code before relying on it.

### The session start budget

Claude Code keeps at most 10,000 characters of a hook's output. Over that it
swaps the whole output for a file path and a short preview, which would hide
the ticket instructions Dex prints first. So at session start the provider
gets only what is left of those 10,000 characters after Dex's own context,
less a 500-character margin, even when `max_chars` allows more. With less than
a few hundred characters left, the provider is not run and the skip is
journalled. Handoffs are not limited this way.

## Failure is not fatal

A provider that exits non-zero, runs past `timeout_seconds`, prints too much,
or cannot be read produces at most one `[warn]` line on stderr. The session
starts, or the handoff goes ahead, without it. Partial output from a failed or
stopped run is not injected.

Each outcome is written to the run journal (`events.jsonl`, see
[events](events.md)):

| Event | When |
|-------|------|
| `context_provider.injected` | Output was injected; `data.chars` is how much |
| `context_provider.truncated` | Output was cut to fit |
| `context_provider.failed` | `data.reason` is `exit`, `timeout`, `malformed` (a block Dex cannot parse, or a list), `invalid_limit` (a limit that is not a whole number; the default is used), `no_budget` or `render` |

A `## Context Providers` block that is not a flat mapping is ignored whole.
Read a key back the way Dex does:

```bash
python3 scripts/project-contract.py .dex/dex.md "Context Providers" phase_handoff
```

## Who does not get recall

- **Review waves and the risk assessor.** Phase 3 reviewers are independent
  and memory-free. They get no provider output and the provider is not run for
  them.
- **Sessions Dex did not launch.** If Dex's hooks are installed globally, a
  plain `claude` session in the repository does not run `session_start`.
- **Triage and session-only launches**, which skip ticket context altogether.

**Codex** runs the same Stop hook, so it receives `phase_handoff` output. It
does not run Dex's SessionStart context hook, so `session_start` is
Claude-only for now.

## Example: semantic memory keyed by ticket

A provider can be a thin wrapper around whatever search the team already has.
This one asks a command-line memory store for notes about the ticket, and at a
handoff adds notes about the files the branch has touched:

```yaml
session_start: bin/recall
phase_handoff: bin/recall
timeout_seconds: 15
max_chars: 6000
```

```bash
#!/usr/bin/env bash
# bin/recall: print notes relevant to this ticket, or nothing.
set -euo pipefail
query="${DX_TICKET_TITLE:-$DX_TICKET_ID}"
[[ -n "$query" ]] || exit 0
memory search "$query" --limit 5 --format text
if [[ "$DX_PHASE" -ge 2 && -s "$DX_CHANGED_FILES" ]]; then
  memory search "$(head -n 20 "$DX_CHANGED_FILES" | tr '\n' ' ')" --limit 3 --format text
fi
```

`memory` stands for your own tool. Keep the output short and specific. A
provider that prints its whole store wastes the budget.
