---
name: "dxwatchpr"
description: "Monitor a ready PR for CI failures and review feedback, fix issues when appropriate, and hand completion back to dxcomplete."
---

# Skill: dxwatchpr

Read and follow `$DEX_DIR/prompts/workflows/dxwatchpr.md` before watching a PR. If
`$DEX_DIR` is unset, resolve this skill directory's real path (realpath) and
use its grandparent. Do not substitute a file from the target project.

The full workflow owns watcher leases, deadlines, feedback handling and the
completion handoff. Preserve every requirement. After compaction, reload it only
while the PR watcher is the active task.
