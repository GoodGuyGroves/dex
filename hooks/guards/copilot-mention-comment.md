---
name: block-copilot-mention
enabled: true
event: bash
detector: copilot-mention-comment
action: block
case_sensitive: false
---

Blocked: this command would post a PR or issue comment that mentions @copilot.

Writing `@copilot` in a comment, review, or PR or issue body summons the
GitHub Copilot coding agent, which can push commits to the branch. That hands
control of the work to another agent, so this guard blocks instead of warning.

To ask Copilot for a review, request it as a reviewer:

    gh pr edit <pr> --add-reviewer @copilot

In Dex, `dx_reviewer_trigger <session> <repo> <pr> Copilot copilot` does this,
and `dx_reviewer_comment` posts reviewer comments with the same check. When a
reply has to name Copilot, write "Copilot" without the `@`.

If a human really wants the coding agent summoned, they can post the comment
themselves, or allow it for this lifecycle with
`dx control override guard.block-copilot-mention allow`.
