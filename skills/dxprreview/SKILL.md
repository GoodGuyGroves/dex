---
name: "dxprreview"
description: "Critically evaluate PR review comments, fix valid issues, push back when appropriate, and prepare reviewer replies."
---

# Skill: dxprreview

Read and follow `$DEX_DIR/prompts/workflows/dxprreview.md` before responding to reviews. If
`$DEX_DIR` is unset, resolve this skill directory's real path (realpath) and
use its grandparent. Do not substitute a file from the target project.

The full workflow governs evidence, accepted fixes, replies, thread resolution
and issue hygiene. Preserve every requirement. After compaction, reload it only
while responding to PR feedback is the active task.
