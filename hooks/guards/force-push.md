---
name: warn-force-push
enabled: true
event: bash
detector: force-push
action: warn
---

This command force-pushes. It can replace commits on the remote branch that
nobody else has, including someone else's work.

Dex rewrites a branch only to bring it up to date with its base, and only
through `bin/branch-sync.sh`: that runs on a branch this lifecycle created and
pushes with `--force-with-lease=refs/heads/<branch>:<oid>` on the exact remote
commit it last saw. Use `bash "$DEX_DIR/bin/branch-sync.sh" push` to retry a
lease push that failed. For any other force-push, stop and ask the user first
(`skills/dxcommit/SKILL.md`, `prompts/base-sync.md`).

Caught: `git push` with `-f` (alone or combined, such as `-fu`), `--force`,
any `--force-with-lease` form, `--force-if-includes`, `--mirror`, or a
`+refspec`. It also catches `git -C <dir> push -f`, `env`/`command`/`sudo`
prefixes, and pushes inside `bash -c` payloads, heredocs and command
substitutions. Not caught: plain `git push`, `git push -u origin HEAD`, text
that only mentions a force push (`echo git push --force`,
`git commit -m "--force"`), and the push `bin/branch-sync.sh` makes itself.

This guard advises and does not deny. A project that wants to forbid force
pushes outright can add its own `block` guard; see `docs/guards.md`.
