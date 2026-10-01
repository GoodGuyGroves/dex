---
name: "dxplan"
description: "Create an implementation plan from a ticket or user request after gathering project context."
---

# Skill: dxplan

Read and follow `$DEX_DIR/prompts/workflows/dxplan.md` before planning. If
`$DEX_DIR` is unset, resolve this skill directory's real path (realpath) and
use its grandparent. Do not substitute a file from the target project.

The full workflow owns plan approval, branch preparation, review criteria and
their approval seal. This short entrypoint does not waive any of those gates.
After compaction, reload the full workflow only while planning is the active task.
