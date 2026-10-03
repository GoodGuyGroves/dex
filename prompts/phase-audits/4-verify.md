Before stopping, audit the final PR gate and commit quality. This phase does
not reserve commits until verification is green: while repairing a failing
gate, commit and push each coherent checkpoint as it forms, then continue the
pipeline. The complete required pipeline must pass before Phase 5.

Follow § Resource Discipline in `$DEX_DIR/prompts/guardrails.md`: heavy work queues through `dx run-gate`; own what you start.

Apply `$DEX_DIR/prompts/issue-hygiene.md` when verification exposes material new
requirements, a distinct defect, or stale issue/PR context. Do not create an
issue for a transient test failure that was fixed as part of the accepted
scope. End the phase summary with the contract's exact `Issue/PR work:` line.

## Step 0: Sync with the base branch

Before any gate runs, bring the branch up to date with its base so this phase
verifies the tree that will merge:

```bash
bash "$DEX_DIR/bin/branch-sync.sh" sync
```

Follow `$DEX_DIR/prompts/base-sync.md` for every answer. A `rebased` answer (exit 1)
means the tree changed and is already pushed with a lease; the gate receipt
check below then asks for a fresh `full-gate` run, which is what this phase
needs. A `not-owned` answer is reported in the summary, never rewritten.

## Step 1: Verification checks

Confirm every quality gate passed:
- Format: PASS? If not, run the formatter and re-check.
- Lint: PASS? If not, fix lint errors (don't disable rules).
- Typecheck: PASS? If not, fix type errors.
- Tests: ALL passing? No skipped tests, no flaky failures? If any test was skipped or failed intermittently, investigate and fix the root cause — unless it is a known baseline failure (below).

When `.dex/dex.md` declares a `## Verification` block, the Phase 4 handoff and
this audit print its policy (`dx_verification_phase_block`):

- Declared `lanes` are the required Phase 4 gate, run in order in place of the
  project aggregate gate. Record them under the `full-gate` receipt name, for
  example `dx run-gate --name full-gate bash -c '<lane 1> && <lane 2>'`.
- A failing test listed under `known_failures` for a base this branch contains
  was failing before this unit. Report it as `baseline (<issue-ref>)` and do
  not fix it here: a fix belongs in its own issue and branch. Rerun it alone
  first when it may be a timing flake. A failure not on that list is this
  unit's to fix.
- A lane that fails only on listed baseline failures still meets the gate:
  its `full-gate` receipt records the failure (`gate-receipt.sh full-gate`
  answers 3), and the summary names every failing test as
  `baseline (<issue-ref>)`. Any other failing test makes it a gate to fix.

Every required gate needs a passing result for *this* tree, and this is the
phase that runs the complete suite. Before running it, ask
`bash "$DEX_DIR/bin/gate-receipt.sh" full-gate` (0 reuse, 1 run it, 3 it failed here):
a `full-gate` receipt Phase 2 wrote on this exact checkout, working tree and
base is the evidence, so reuse it and say so; a receipt for any other gate is
not. A resume is no exception: never waive or pass this phase on a receipt or
gate log that `gate-receipt.sh` does not accept for the current HEAD and base,
such as one recorded before the base moved.
Otherwise run `dx run-gate --name full-gate <project aggregate gate, or the
declared ## Verification lanes>` now, which records the receipt; one that
failed on this tree is a gate to fix, not to re-run, unless every failure in it
is a listed baseline failure (above). When `.dex/dex.md` § Resources declares `full_gate: ci`, run the fast
gates and focused tests here, leave the complete suite to CI, keep the PR a
draft, and let Phase 6 treat CI as the final gate — unless this ticket
changed the gates, CI, or test infrastructure, which runs locally regardless.

Run /dxverify if you haven't already, or if you've made changes since the last run.

## Step 2: Commit quality

Review your commit history (`git log --oneline origin/<default-branch>..HEAD`):
- Are commits atomic? Each commit should contain one logical change.
- Do commit messages follow conventional format? (`type(scope): description`)
- Are there any commits that should be split or combined?
- Are there any files that should NOT have been committed?
  - Generated files that should be in .gitignore
  - Debug logs or temporary files
  - Files containing secrets or credentials

## Step 2.5: `.dex/` in commits

Earlier phases should already have committed and pushed any `.dex/` updates
implementation or review required. If final verification added more, commit them
as a coherent checkpoint, ideally `docs(.dex): sync project config`. Do not move
an implementation-owned `.dex/` update into Phase 4 because it was left staged.

## Step 3: Diff review

Run `git diff --stat origin/<default-branch>` and review:
- Does the overall diff look clean and focused?
- Are there any unexpected files in the diff?
- Is the total scope of changes proportional to the task?

## Step 4: Push

Earlier phases should already have pushed their implementation and review-fix
checkpoints, and Step 0's sync pushed any rebase itself. Confirm local HEAD
matches `origin/<current-branch>`. Never force-push here: after a rebase, a
lease push that failed is retried with `bash "$DEX_DIR/bin/branch-sync.sh" push`. If final
verification still left changes, split them only at natural logical boundaries,
commit and push each coherent repair checkpoint immediately, and rerun the
affected checks; do not wait for the rest of the pipeline before recording one.

If you pushed and got errors (e.g., remote rejection, hook failures), fix the issues and push again.

If a newly created local branch has no branch-specific commits, keep it
unpushed. It cannot satisfy the ordinary Phase 4 completion gate or continue to
Phase 5; return to Phase 2's user-direction path instead. The user may stop the
lifecycle as no-change or choose an explicit lifecycle control action. Do not
create an empty commit.

## Completion criteria

ALL of these must be true before you stop:
- Step 0's base sync ran before the gates and answered `current`, `disabled`,
  `rebased` (gates then ran on the rebased tree), or `not-owned` (reported);
  any other answer was handled under `$DEX_DIR/prompts/base-sync.md`
- Every required gate has a passing result for this tree: a reused `dx run-gate`
  receipt with matching checkout, working-tree and base fingerprints, a fresh
  run, or CI under `full_gate: ci`.
  With a declared `## Verification` policy, the declared lanes are the required
  gate; a lane run whose only failures are listed `known_failures` entries
  counts as passing when the summary lists each as `baseline (<issue-ref>)`
  with no fix commit for it on this branch
- No session-owned background process in flight, per `dx ps`
- Commits are clean and atomic with conventional messages
- No unwanted files in the diff
- Any `.dex/` changes are committed cleanly
- Every branch-specific commit is pushed to origin successfully
- A newly created local branch with no branch-specific commits did not enter
  the ordinary Phase 4 flow
- Material verification findings were handled under
  `$DEX_DIR/prompts/issue-hygiene.md`, and the summary contains `Issue/PR work:`

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions.
