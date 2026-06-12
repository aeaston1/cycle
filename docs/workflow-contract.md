# Workflow Contract

Cycle should treat repo-owned `WORKFLOW.md` files as the project-local workflow
source. Symphony should treat them as execution instructions for one issue run.
Cycle's operator config is the source for global policy, validation, drift
reporting, and optional propagation.

The same file can serve both purposes, but Cycle should read only the fields it
needs for orchestration.

## Current Adapted Symphony Behavior

The adapted Symphony implementation resolves the target repo's root
`WORKFLOW.md`, parses the full Symphony workflow schema, and uses project agent
settings for scheduling. When an issue is dispatched, the agent run uses the
repo workflow as the effective workflow.

Cycle should preserve that behavior while moving orchestration decisions into
Cycle-owned code. The adapted Symphony global workflow merge can supply defaults,
but project workflows override those defaults. Cycle must therefore validate
effective project settings against global policy instead of assuming inherited
defaults are enforced.

## Cycle Reads

Cycle may read these workflow sections:

- `agent.max_concurrent_agents`
- `agent.max_concurrent_agents_by_state`
- `agent.max_turns`
- `tracker.active_states`
- `tracker.terminal_states`
- `review_judge.enabled`
- `review_judge.source_state`
- `review_judge.review_state`
- `review_judge.proceed_state`
- `review_judge.policy`
- `review_judge.minimum_skip_confidence`
- `review_judge.hard_require_human_review`
- `worker.ssh_hosts`
- `worker.max_concurrent_agents_per_host`
- `hooks` only for display and pass-through in the first Cycle versions

Cycle should not need to understand every prompt, instruction, or engine detail
inside `WORKFLOW.md`.

Cycle should also compare the fields it reads against global policy and store
whether each project is in policy, drifting, or invalid.

Repo-owned workflow hooks that need the GitHub repository slug should receive
it through an environment variable such as `CYCLE_WORKFLOW_REPOSITORY=OWNER/REPO`
instead of hardcoding a private owner/name in `WORKFLOW.md`. This keeps the
workflow usable for real runs while preserving public repository hygiene.

## Symphony Receives

When Cycle dispatches a run, the selected Symphony engine needs:

- Linear issue identity and current issue payload
- repo URL
- workspace path or workspace allocation instruction
- workflow path or full workflow content
- selected engine config
- sandbox and approval policy
- any run-specific metadata Cycle wants returned in status

Until upstream Symphony has a stable external run protocol, Cycle records queued
or blocked scheduler decisions and dispatches only through an adapter capability
that explicitly advertises single-issue dispatch support.

## Project Workflow Lookup

Cycle should resolve the workflow in this order:

1. Explicit `cycle.workflow` path from Linear metadata, relative to repo root.
2. Default `WORKFLOW.md` at repo root.
3. Compatibility lookup for existing local checkouts during development.
4. Cached clone under Cycle state.

The registry should store both the configured workflow path and the concrete
resolved path or cache location used during the last discovery pass.

## Validation

A project workflow is usable when:

- the repo can be cloned or opened
- the workflow file exists
- YAML front matter parses
- fields Cycle reads have valid types and values
- required engine pass-through fields for the selected Symphony version are
  present or defaultable
- required Cycle global policy fields are present or can be defaulted
- project overrides do not violate blocked fleet policy

Invalid workflow state should prevent dispatch for that project only. It should
be visible in `cycle status`.

Policy drift is less severe than invalid workflow state by default. In `report`
mode, drift should be visible but dispatch may continue. In `block` mode, drift
against required policy should prevent dispatch.

## Drift And Propagation

Cycle should never mutate repo `WORKFLOW.md` files during discovery. When a
project drifts from global policy, Cycle should report:

- project and repo
- workflow path
- setting path
- desired value
- observed value
- whether the drift is informational, blocking, or propagatable

Optional propagation should be an explicit operator action. It may prepare a
patch, branch, commit, or pull request that changes only the relevant workflow
settings. Cycle should not silently push workflow policy changes.

## Compatibility

Cycle should accept current Symphony workflow fields unchanged. New Cycle-only
workflow fields should live under a `cycle:` key to avoid confusing upstream
Symphony:

```yaml
cycle:
  policy_profile: default
  engines:
    allow:
      - openai-symphony@main
```

Cycle must pass through unknown workflow content to Symphony rather than
rewriting or dropping it.

## Non-Goals

- Do not move project prompts into Linear metadata.
- Do not vendor project workflows into Cycle state except as a cache.
- Do not mutate repo `WORKFLOW.md` during discovery.
- Do not treat `symphony:` Linear metadata as a Cycle project opt-in.
