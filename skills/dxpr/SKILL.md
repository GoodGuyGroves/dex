---
name: "dxpr"
description: "Generate or update a PR description, create or update the pull request, attach request-type reviewers, and mark the PR ready for review."
---

# Skill: dxpr

Read and follow `$DEX_DIR/prompts/workflows/dxpr.md` before PR work. If
`$DEX_DIR` is unset, resolve this skill directory's real path (realpath) and
use its grandparent. Do not substitute a file from the target project.

The full workflow owns verification evidence, attachments, reviewer selection,
attribution and marking the PR ready. Preserve every requirement. After
compaction, reload it only while PR preparation is the active task.
