# BCR approval-freshness TOCTOU PoC

## Result

This controlled reproduction demonstrates that the BCR PR reviewer at the production-pinned revision
`bazelbuild/continuous-integration@957b0ac44549a70ccb951361b804d07d955aeb79` can accept a maintainer approval that was submitted for an older PR HEAD as approval for a newer, unreviewed HEAD.

The test is confined to `SwayZGl1tZyyy/bazel-central-registry` and uses harmless marker changes.

## Accounts / roles

- PR author / external-contributor role: `SwayZGl1tZyy`
- module maintainer role: `SwayZGl1tZyyy`
- target PR: #5 (`poc-toctou-cross-module`)
- module: `abc`

`modules/abc/metadata.json` on `main` lists `SwayZGl1tZyyy` as a maintainer.

## Commits

### Commit A — reviewed state

`8af37e47ee8644e77a21b9d4baac068bbfa75ced`

This is the state explicitly approved by the module-maintainer account.

### Commit B2 — unreviewed state

`9905e6513b3ff0c12eedeed080323f1f828493b7`

B2 is a descendant of A and adds only:

`modules/abc/0.68-yosyshq/BCR_TIMESTAMP_POC.txt`

The marker is harmless and exists only in this research fork.

B2 author time observed by the upstream reviewer:

`2026-09-07 21:04:23 UTC`

The maintainer approval on A was submitted later:

`2026-09-07 21:04:57 UTC`

This ordering is important because the vulnerable implementation compares `review.submitted_at` with `latestCommit.commit.author.date` instead of binding the review to the reviewed commit SHA.

## Vulnerable logic

The pinned upstream reviewer computes freshness from the latest commit's Git author timestamp:

```js
const latestCommit = commits[commits.length - 1];
const latestCommitTime = new Date(latestCommit.commit.author.date);
...
if (new Date(review.submitted_at) < latestCommitTime) {
  return;
}
```

A review is therefore accepted whenever its submission time is after the current HEAD's `author.date`, even if that review was submitted for a different commit.

Separately, `runPrReviewer()` waits for `dismiss_approvals` only once globally, before it lists and processes open PRs. A `synchronize` event that occurs after this check can therefore create a new dismissal run while the reviewer continues processing.

## Deterministic race harness

Workflow:

`.github/workflows/bcr_toctou_orchestrator.yml`

The harness checks out the exact pinned upstream revision and makes one lab-only modification: a synchronization barrier is inserted immediately after the existing global `waitForDismissApprovalsWorkflow()` call and immediately before the open-PR scan.

No approval-freshness logic, module-approval logic, PR HEAD checking, review creation logic, or merge logic is changed.

The workflow prints the complete source diff in its Actions log so this can be verified directly.

When the barrier is reached, it posts:

`BCR_POC_SYNC_READY_B2: reviewer passed global dismissal wait; externally move PR #5 to single-module commit B2 now.`

The branch is then moved externally from A to B2. That normal branch update triggers the real `pull_request_target` `synchronize` path and the real `dismiss_approvals` workflow. The harness waits until GitHub's Pulls API itself reports B2 as the PR HEAD and then resumes the unchanged reviewer.

## Successful run

Actions run:

`34161811883`

Job:

`101865015285`

After the barrier, the exact reviewer emitted:

```text
Processing PR #5
Modified modules: abc
Fetching metadata for module: abc
Maintainers Map:
- Maintainer: uebelandre, Modules: abc
- Maintainer: swayzgl1tzyyy, Modules: abc
Latest commit: 9905e6513b3ff0c12eedeed080323f1f828493b7
Latest commit time: Mon Sep 07 2026 21:04:23 GMT+0000 (Coordinated Universal Time)
Latest Reviews:
- Reviewer: SwayZGl1tZyyy, State: APPROVED, Submitted At: 2026-09-07T21:04:57Z
Approvers: swayzgl1tzyyy
Module 'abc' has maintainers' approval from 'swayzgl1tzyyy'.
All modified modules have maintainers' approval
```

This is the security assertion:

1. the maintainer approved A;
2. the PR HEAD was changed to B2 after that approval;
3. the exact upstream reviewer observed B2 as the current HEAD;
4. the old review was still `APPROVED` in the race window;
5. `getPrApprovers()` accepted the stale review because B2's author timestamp predates the review timestamp;
6. the unchanged module-approval logic concluded that **all modules in B2 had maintainer approval**, even though the maintainer never reviewed B2.

## Why the later HEAD check does not fix this

`reviewPR()` captures the current HEAD at the beginning of analysis and re-fetches it before privileged actions. That protects against HEAD changing *during* one `reviewPR()` invocation.

It does not protect this case because B2 is already the current HEAD when `reviewPR()` begins. Both the initial and later HEAD checks therefore agree on B2. The incorrect state is the stale approval associated with B2.

## Lab token limitation

After reaching `All modified modules have maintainers' approval`, this deterministic harness stops later at:

```text
GET /user -> 403 Resource not accessible by integration
```

because the harness uses the repository `GITHUB_TOKEN`, which is a GitHub App installation token. The production BCR workflow uses its privileged helper-token context for the reviewer.

This token limitation occurs **after** the vulnerable freshness calculation and after the reviewer has concluded that all modified modules are approved. It therefore does not invalidate the approval-bypass reproduction, but this particular run does not claim that B2 was actually merged.

## Fix

Approval validity should be bound to the reviewed commit rather than to wall-clock timestamps. At minimum, require an effective approval to be associated with the current PR HEAD SHA (for example using the review's `commit_id` / equivalent review-to-HEAD binding), and perform the dismissal/freshness synchronization per PR and per HEAD rather than once globally before scanning all PRs.
