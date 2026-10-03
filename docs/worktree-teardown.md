# Worktree teardown

When a lifecycle finishes, Dex removes its worktree and deletes its local
branch. That is also what `dxrm`, `dxrm --all`, `dxclean` and
`dx worktree audit --apply` do. None of them destroys work git does not
already hold somewhere else:

- **Untracked files** that are not gitignored, and **uncommitted edits** to
  tracked files, are copied out before the directory goes, or the removal is
  refused. See [`teardown_untracked`](#teardown_untracked).
- **A branch** is deleted only when every commit on it is also on another
  branch, on a remote-tracking ref, or in a merged pull request. Otherwise the
  branch is kept and Dex says why.

When the removal happens is a setting too. See
[`worktree_teardown`](#worktree_teardown).

Removing a worktree also forgets its session: the phase, run ID, clock and
runtime lease, so the next lifecycle there starts a run of its own. A runtime
that is still live keeps its lease, and `dxrm` says so. A pending
[ticket close](#ticket-close) is kept for the merge sweep. When a worktree
disappears some other way (`git worktree remove`, say), the next
`dx <ticket>` notices the earlier run. On a terminal it asks whether to
resume it or start a new run, and a new run is the default. Without a
terminal it starts a new run and says so. It never discards a run whose
runtime is still live.

## Settings

A fenced YAML block under `## Worktree Teardown` in `.dex/dex.md`, read from
the main checkout like `## Worktree Hooks`:

```yaml
worktree_teardown: on_complete        # on_complete | on_merge | caller
teardown_untracked: rescue            # rescue | refuse
delete_remote_branch_on_merge: false  # true | false
```

Every key is optional, and so is the section. The values above are the
defaults. A value Dex does not recognise, or a block that is not a flat
mapping, is ignored with a warning, and Dex uses the value that removes the
least: `caller`, `refuse` and `false`.

### `teardown_untracked`

| Value | What a removal does with untracked files and uncommitted edits |
|-------|-------------------------------------------------------------|
| `rescue` | Copies them into a new directory under `DX_RESCUE_DIR`, then removes the worktree. If any copy fails, the worktree is kept. |
| `refuse` | Keeps the worktree and lists what is there. `dxrm <name>` exits non-zero, `dxrm --all` says which it kept, and Phase 6 reports that local cleanup did not finish. |

Commits that exist only on the worktree's branch are handled the same way.
Under `rescue` the worktree is removed and the branch is kept. Under `refuse`
nothing is removed. Commits on a detached HEAD that no branch holds get a
`dex-rescue/<worktree>-<time>` branch under `rescue`.

Gitignored files (build output, `node_modules`, `.env`) are not rescued.
Neither are the links Dex itself adds to a worktree, such as `.claude`. Files
under a real `.claude` directory are rescued unless the repository's own
`.gitignore` ignores them.

Submodule work cannot be copied out: a worktree's submodule repositories are
deleted with it. If a submodule has untracked files, uncommitted edits or
commits no remote-tracking ref holds, the worktree is kept under either
setting, and Dex lists the submodules.

A directory under `.dex/worktrees/` that git does not list as a worktree
cannot be inspected file by file. Under `rescue` it is copied whole into the
rescue directory; under `refuse` it is kept unless it is empty.

The `before_remove` [worktree hook](worktree-hooks.md) runs after this check,
and only for a worktree that is actually removed.

### `worktree_teardown`

| Value | When Phase 6's worktree (or, in place, branch) is removed |
|-------|-------------------------------------------------------------|
| `on_complete` | At completion, as before. |
| `on_merge` | Once its pull request has merged. `dxclean`, and the next `dx` run in that repository, ask GitHub (`gh pr list --state merged`). An open pull request keeps everything quietly, and so does one closed without merging: run `dxrm <name>` for those. If `gh` is missing, fails or times out, everything is kept and Dex says it could not confirm the merge. A merged pull request counts only when its head contains the local branch, so one merged earlier from the same branch name does not. At `dx` start the check waits at most 10 seconds per lookup and starts no new lookup after 20 seconds. |
| `caller` | Never by Dex on its own. Whoever launched Dex (a person, an orchestrator) runs `dxrm <name>` after the merge. `dxclean` skips it. |

With `on_merge` or `caller`, completion writes `teardown_deferred`,
`teardown_branch` and `teardown_at` into the session's `.meta` record, which
`dxclean`'s stale-file sweep does not delete. Running `dx` on a deferred
lifecycle again says its teardown is deferred. `dxrm <name>` removes it at
any time.

For an in-place lifecycle (`dx --no-worktree`), `on_merge` switches a clean
checkout back to the default branch after the merge and deletes the lifecycle
branch. A checkout with uncommitted changes is left alone.

### `delete_remote_branch_on_merge`

With `true`, Dex deletes the branch on its remote after the pull request
merged. It does this only when all of these hold:

- GitHub reports the pull request as merged;
- the remote branch still points at the merged head, so nothing pushed after
  the merge is lost;
- the branch is not the default branch.

Dex checks this when it releases a branch in `dxrm`, `dxclean` and the
`on_merge` sweep. A failed push only warns. It is off by default because many
repositories already delete merged branches on GitHub.

## Ticket close

When Phase 6 moves the ticket to Done is a setting too. It goes in the
`## Tickets` block of `.dex/dex.md`:

```yaml
ticket_close: on_complete   # on_complete | on_merge | never
```

| Value | What Phase 6 does with the ticket |
|-------|-----------------------------------|
| `on_complete` | Marks the ticket, and each sub-issue the pull request completes, Done once CI is green and review feedback is resolved, before the merge. This is the default and what Dex always did. |
| `on_merge` | Posts the final summary and leaves the ticket and its sub-issues open. Dex closes them once the pull request merges. |
| `never` | Posts the final summary and leaves every status to whoever launched Dex. A ticket with several deliverables, or a parent whose children close separately, is the caller's to close. |

The key is optional. A value Dex does not recognise, or a `## Tickets` block
that is not a flat mapping, is ignored with a warning and Dex uses `never`,
so a typo cannot close a ticket before its merge.

A run can override the project. `dx run` takes `workflow.ticket_close` from
the run spec (see [run specs](run-specs.md)), and any launch takes
`DEX_TICKET_CLOSE`. The run spec beats the environment variable, and both
beat `.dex/dex.md`. Dex records the mode in the session's `.meta` when the
lifecycle starts. A resume keeps that value unless the override is passed
again.

### How `on_merge` closes the ticket

`on_merge` uses the same record and sweep as `worktree_teardown: on_merge`.
At completion, Dex writes these keys into the session's `.meta`:

- the ticket, plus the sub-issues Phase 6 registered;
- the tracker kind, read from the "Ticket tracker" row of `## Integrations`;
- the pull request's number and head.

If the worktree is removed at completion, Dex keeps only those keys in the
`.meta`, so the record survives the teardown.

`dxclean`, and the next `dx` run in that repository, handle the record. They
ask GitHub about the recorded pull request (`gh pr view <number>`) under the
same time limits as the teardown check. What happens next depends on the
answer:

- **Merged, GitHub Issues tracker.** Each recorded issue that is still open is
  closed with `gh issue close --reason completed` and a comment naming the
  pull request. One already closed by a `Closes #N` line is left as it is.
- **Merged, any other tracker.** Dex has no client for other trackers, so it
  prints which tickets to move to Done and drops the record. Linear and Jira
  usually move a ticket on merge through their own GitHub integration.
- **Open, or the answer is unknown.** The record is kept. That includes a
  `gh` that is missing, fails or times out. So is a failed close, which the
  next sweep retries.
- **Closed without merging.** The record is dropped and the ticket stays
  open.

A lifecycle reopened on the same ticket is left alone until it completes
again. `dx sessions forget` drops a pending close along with the session.
Once the worktree is gone, `dx sessions` no longer lists the record, but
`dx sessions forget <name or session ID>` still drops it without closing
anything: use it for a close Dex can never confirm, such as one whose
pull request it cannot ask about.

On GitHub Issues the pull request body follows the mode as well. Under
`on_merge` it carries `Closes #N`. GitHub honours that keyword only for a
pull request into the default branch, which is why Dex also closes the ticket
itself. Under `never` the body uses `Refs #N` and no closing keyword. Under
`on_complete` the body is unchanged.

## The rescue directory

`DX_RESCUE_DIR` is `$DEX_HOME/rescue` when `DEX_HOME` is set, and
`~/.dex/rescue` otherwise (see [State root](reference.md#state-root)). Each
rescue gets its own private directory named after the worktree and the UTC
time, with `-2`, `-3` and so on added when two land in the same second:

```text
$DX_RESCUE_DIR/ticket-142-20261002T091500Z/
  untracked/<path>   untracked files, at their paths in the worktree
  tracked.patch      uncommitted edits (git diff HEAD --binary), if any
  info.txt           worktree, branch, HEAD commit, and how to restore
```

To restore, check out the commit in `info.txt`, then:

```bash
git apply --binary "$DX_RESCUE_DIR/ticket-142-20261002T091500Z/tracked.patch"
cp -R "$DX_RESCUE_DIR/ticket-142-20261002T091500Z/untracked/." .
```

Dex never deletes rescue directories. Remove them yourself when you no longer
need them.

## `dxclean` and renamed branches

Phase 0 often renames a lifecycle branch to the tracker's name, for example
from `worktree-ticket-142` to `feat/ENG-142-login`. `dxclean`'s gone-branch and
orphan-branch passes include the branches recorded in this repository's Dex
session records, so renamed branches are cleaned up too. A branch Dex has no
record of is never touched. `dxrm` finds a renamed branch the same way when the
worktree directory is already gone.

A worktree whose remote branch GitHub deleted after a merge has no
`origin/<branch>` to compare against. `dxclean` then accepts a merged pull
request whose head is the branch's tip instead.
