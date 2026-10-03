---
name: block-review-wave-history-rewrite
enabled: true
event: bash
detector: history-rewrite
action: block
env_var: DEX_REVIEW_PASS_ACTIVE
env_value: "1"
---

Blocked: a review wave does not rewrite commits.

Review fixes land as new commits, and that includes a fix to an earlier
commit's message or trailer. A wave pushes each fix as soon as it commits it,
so amending or force-pushing replaces a commit that is already on the remote
branch, outside the lease checks Dex uses for that.

Make the correction a follow-up commit instead. The only rewrite Dex makes is
bringing a branch it created up to date with its base, through
`bash "$DEX_DIR/bin/branch-sync.sh" sync` (or `push` to retry its lease push),
and a review wave leaves that to the lifecycle. For any other rewrite, stop
and report it; a human can allow it for this session with
`dx control override guard.block-review-wave-history-rewrite allow`.

Caught, only while `DEX_REVIEW_PASS_ACTIVE=1`: `git commit --amend` in any
form, and every force push the `warn-force-push` guard catches (`-f`,
`--force`, any `--force-with-lease` form, `--force-if-includes`, `--mirror`,
a `+refspec`), including after `git -C <dir>`, behind `env`/`command`/`sudo`,
and inside a heredoc, a `bash -c` payload or a command substitution. Not
caught: plain `git commit` and `git push`, text that only mentions an amend
(`echo git commit --amend`, `git commit -m "--amend"`), and
`bin/branch-sync.sh`, which makes its lease push itself. Outside a review
wave this guard does nothing; `warn-force-push` still advises there.
