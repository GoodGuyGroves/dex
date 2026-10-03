# Sync With the Base Branch

A lifecycle branch can fall behind its base between planning and PR handoff.
Final verification should cover the tree that will merge, and a PR should not
be marked ready while it is behind. `bin/branch-sync.sh` does the deterministic
part: it fetches the base, rebases only a branch this lifecycle created, and
pushes with a lease on the remote commit it last saw. You decide two things:
whether a conflict is simple enough to resolve here, and when to escalate.

Dex runs the sync at two points:

- **Phase 4, before any gate runs:** `bash "$DEX_DIR/bin/branch-sync.sh" sync`
- **Right before any `gh pr ready`:**
  `bash "$DEX_DIR/bin/branch-sync.sh" sync --before-ready`. It counts against
  `pr.rebase-attempts` (default 2). Phase 4's sync does not count.

The project turns both off with `rebase_before_ready: false` in `.dex/dex.md`
§ Resources. The command then answers `disabled` with exit 0.

## Which base

The sync picks the base in this order and reports it as `base_source=`:

1. `pr`: the open PR's base branch. This applies only when the branch is on
   origin, `gh` is installed, and origin is a GitHub repository `gh` can
   resolve, meaning `github.com` or a host `gh` holds credentials for.
2. `recorded`: `base_branch` in the session meta. A branch stacked on another
   branch records it before its PR exists:
   `dx_meta_write "$DEX_SESSION_ID" base_branch=<parent-branch>`.
3. `default`: the repository's default branch.

When `gh` is missing, origin isn't GitHub, or the branch has no open PR, the
sync moves on to the next source. It fails with `fetch-failed` (exit 5) rather
than guessing in two cases: `gh` errors or times out against a GitHub origin,
or the chosen base doesn't exist on origin. A stacked branch rebased onto the
default branch would replay its parent's commits.

## What each answer means

The first output line is the status word; `key=value` lines follow.

| Exit | Status | Do this |
|------|--------|---------|
| 0 | `current` / `disabled` | Nothing to do. Continue. |
| 1 | `rebased` | The tree changed and is already pushed. Every earlier gate result is stale: run `dx run-gate --name full-gate <project aggregate gate, or the declared ## Verification lanes>` on this tree before continuing. Before ready, sync again after the gate passes. |
| 2 | `cannot-run` | Fix the stated cause, such as uncommitted tracked changes or a detached HEAD, and run it again. A rebase left in progress is listed as conflicts; finish or abort it first. |
| 3 | `conflict` | The rebase stopped. Apply the conflict policy below. |
| 4 | `not-owned` | Dex did not create this branch, so it is never rewritten. Record the `behind=` count and base in the phase summary and the PR handoff, then continue on the current tree. |
| 5 | `fetch-failed` / `push-failed` | A network or remote failure. Retry once: `sync` again for `fetch-failed`, `bash "$DEX_DIR/bin/branch-sync.sh" push` for `push-failed` (the branch is already rebased locally). In Phase 4, if a fetch still fails, record that the base could not be checked and continue; a push that still fails blocks Phase 4 like any unpushed commit. Before ready, escalate: do not mark a PR ready without knowing where its base is. |
| 6 | `limit` | The base kept moving after `pr.rebase-attempts` rebases. Escalate. Do not mark the PR ready. |
| 7 | `remote-diverged` | Someone else pushed to this branch, or the lease was rejected. Escalate. Never retry with `--force`, and never push over it. |

## Conflict policy

A conflict is **simple** only when all of these hold:

- at most 3 files conflict, and each is an ordinary text conflict (`UU` in
  `git status --short`);
- every hunk is resolved by keeping both sides, without choosing between two
  behaviours. Examples: adjacent-line edits, two new rows in a manifest or
  registry, two new entries in a list or changelog;
- lockfiles and generated files are regenerated with the project's own tool,
  never merged by hand;
- the resolution does not change what the approved plan says the code does.

Resolve a simple conflict, `git add` each file, then record what you did:

```bash
bash "$DEX_DIR/bin/branch-sync.sh" continue --note "<files>: <what was kept>"
```

The note becomes a `Rebase-note:` trailer on the replayed commit. `continue`
answers like `sync`: `rebased` (exit 1) when finished, `conflict` (exit 3)
when a later commit also conflicts. Apply the same policy to that one.

Everything else is **non-trivial**. Examples: both sides changed the same
logic; a modify/delete, rename, add/add, binary or submodule conflict; more
than 3 files; a resolution that would change approved behaviour; or a gate
failure that traces back to the merge. Run `git rebase --abort`, confirm the
branch is back where it was, and escalate. Name the conflicting files and the
base commit in the escalation.

## Escalating

Use the exact generation-bound escalation command supplied with the current
launch or audit (`$DEX_DIR/prompts/failure-recovery.md`). It pauses the run without
claiming completion. Report:

- the status word and its `key=value` lines;
- for a conflict, the conflicting files and why they are not simple;
- for `limit`, that a human can allow more rebases with
  `dx control override pr.rebase-attempts <n> --source human --reason "<why>"`
  from their own terminal and resume;
- that the PR was not marked ready.

## Pushing

`branch-sync.sh` pushes for you, with
`--force-with-lease=refs/heads/<branch>:<oid>`. Do not run
`git push --force`, `--force-with-lease` or `+refspec` yourself. To retry a
lease push that failed on the network, run
`bash "$DEX_DIR/bin/branch-sync.sh" push`. It re-checks ownership and uses the
same recorded lease.
