# Review Judge Policy

Cycle should own review judgement policy. Symphony can provide run evidence, but
Cycle should decide when automated review is enough and when a human should stay
in the loop.

Review judge settings are fleet policy, not only per-repo defaults. Cycle should
validate project workflows against the configured global judge policy, report
drift, and optionally propagate narrow workflow updates when the operator asks.

## Current Behavior To Preserve

The adapted Symphony review judge:

- watches a configured source state, usually `Human Review`
- uses the same opted-in project discovery boundary as normal dispatch
- skips issues that are blocked, running, claimed, or already being judged
- builds evidence from issue details, labels, comments, workpad, workspace, and
  git state
- computes an evidence hash
- skips repeated identical judgements
- applies hard human-review stops before asking the model
- runs a read-only judge turn
- expects structured JSON output
- posts a decision comment with evidence and hash
- re-checks current Linear state before writing
- moves allowed issues to the proceed state, usually `Merging`

## Policy Inputs

Cycle review policy should include:

- `enabled`
- `source_state`
- `review_state`
- `proceed_state`
- `model`
- `reasoning_effort`
- `service_tier`
- `policy`
- `minimum_skip_confidence`
- `hard_require_human_review.paths`
- `hard_require_human_review.labels`
- project policy profile
- engine or workflow version for judgement provenance
- global policy version
- drift status for the project's judge settings

## Decision Model

The judge should return structured data:

```json
{
  "decision": "proceed_to_merging",
  "confidence": "medium",
  "human_review_value": "low",
  "reason": "The change is scoped, validated, and low risk.",
  "evidence": ["Tests passed", "Diff only touches documentation"]
}
```

Allowed decisions:

- `proceed_to_merging`
- `require_human_review`

Cycle should treat unknown or malformed output as `require_human_review`.

## Confidence Gate

`proceed_to_merging` is allowed only when confidence meets or exceeds
`minimum_skip_confidence`.

Recommended ordering:

```text
low < medium < high
```

If confidence is too low, Cycle should leave or move the issue to the review
state and explain why.

## Hard Human-Review Stops

Hard stops should take precedence over model output. Examples:

- changed files match a configured path
- issue labels match configured labels
- validation evidence is missing
- git evidence is unavailable for a code-changing issue
- workflow, infrastructure, security, data, or public API surfaces changed
- review judge itself fails

Policy profiles may tune this, but failure should be conservative.

## Global Judge Policy And Drift

Cycle global policy should be able to require judge settings such as:

```yaml
review_judge:
  model: gpt-5.5
  reasoning_effort: xhigh
  service_tier: fast
  policy: standard
```

If a project workflow omits these values, Cycle may apply defaults when the
selected engine supports them. If a project workflow explicitly differs, Cycle
should report drift. Whether drift blocks dispatch depends on the configured
policy enforcement mode.

Optional propagation should be explicit and auditable. A propagation action may
prepare a branch, commit, or pull request that updates only review judge policy
fields in the repo workflow.

The first propagation command is dry-run first: it prints the proposed workflow
patch from recorded drift and does not mutate the project repo. Because workflow
front matter is rewritten with Cycle's YAML emitter only where needed, comments
inside edited YAML blocks are not guaranteed to be preserved; operators should
review the patch before applying it.

## Evidence Hash

Cycle should hash stable evidence inputs and include the hash in the judge
comment. The hash prevents repeated identical judgements.

The hash should include:

- issue id, identifier, title, state, labels
- workpad and relevant comments
- git changed files and summary
- workflow or policy version
- judge policy profile
- global policy version and effective project policy

The hash should exclude volatile timestamps unless they represent meaningful
evidence.

If an optional external reviewer is added later, its stable fingerprint should
be included in the evidence hash input. A changed external review fingerprint
must produce a different hash so Cycle does not skip a meaningfully different
judgement as a duplicate.

External review evidence must be tied to the inspected workspace. Cycle's guard
source is `evidence.git["workspace_path"]`; if git evidence comes from a
different workspace than the run evidence, Cycle should require human review
before trusting the automated result.

## External Review And Fix Boundaries

External review providers are planned evidence sources, not state machines.
They should feed findings, fingerprints, and summaries into Cycle-owned review
policy. They should not move Linear issues, post comments directly, mutate
workspaces outside the inspected checkout, or replace Cycle's duplicate-hash
and stale-state checks.

The local Clawpatch provider should reuse existing repo-local Clawpatch and
Crabbox config when present, or explicit operator config paths when supplied.
When no Crabbox config exists, Cycle may create a review-job artifact that uses
the opinionated Crabbox-on-Cloudflare-Workers default. That artifact is
Cycle-owned state; it is not written into the project repo and it must not
contain Cloudflare credentials.

Human Review is review-only. Cycle must not invoke an automated fix path for an
issue just because it is in `Human Review`; that state is where Cycle decides
whether the existing change can proceed or needs a person.

Automated fix support for `Rework` is planned but disabled in v1. Until an
operator explicitly enables a future fix provider, `Rework` should be handled
by the normal execution engine lifecycle and reviewer feedback should remain
visible to the agent and operator.

## Linear Write Safety

Before posting or moving an issue, Cycle should:

1. Refresh the issue by Linear id.
2. Confirm it is still in `source_state`.
3. Confirm the project is still enabled.
4. Confirm no newer judge comment with the same evidence hash already exists.
5. Post the decision comment.
6. Move state only if the decision allows it.

If the issue left `source_state`, Cycle should skip writes.

## Status Surface

`cycle status` should show:

- issues waiting in review source state
- active judge tasks
- last judge decision per issue
- skipped duplicate judgements
- hard human-review reasons
- judge policy drift per project
- judge failures
- route write failures

## Tests

Review judge tests should cover:

- duplicate evidence hash skip
- stale Linear state before write
- hard path stop
- hard label stop
- malformed model output
- confidence below threshold
- successful proceed route
- failed evidence build falls back to human review
