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
Neither are the links Dex itself adds to a worktree, such as `.claude`.

A directory under `.dex/worktrees/` that git does not list as a worktree
cannot be inspected file by file. Under `rescue` it is moved whole into the
rescue directory; under `refuse` it is kept unless it is empty.

The `before_remove` [worktree hook](worktree-hooks.md) runs after this check,
and only for a worktree that is actually removed.

### `worktree_teardown`

| Value | When Phase 6's worktree (or, in place, branch) is removed |
|-------|-------------------------------------------------------------|
| `on_complete` | At completion, as before. |
| `on_merge` | Once its pull request has merged. `dxclean`, and the next `dx` run in that repository, ask GitHub (`gh pr list --state merged`). An open pull request keeps everything quietly. If `gh` is missing, fails or times out, everything is kept and Dex says it could not confirm the merge. |
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
