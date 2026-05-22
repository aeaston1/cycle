# Scheduler Design

Cycle's scheduler decides which Linear issues should run, when they should run,
and which Symphony engine should receive each run.

The adapted Symphony scheduler is already multi-project and capacity-aware. The
main Cycle addition is durable state plus engine-aware scheduling.

## Inputs

- Project registry entries from Linear discovery.
- Candidate issues from opted-in Linear projects.
- Current issue state, blockers, labels, assignee, and timestamps.
- Repo-owned workflow policy.
- Global Cycle config.
- Global Cycle policy and drift state.
- Engine registry and engine health.
- Active run state.
- Token, rate-limit, and budget pressure.

## Candidate Fetch

Cycle should fetch candidates by project:

1. Read valid enabled projects from the registry.
2. For each project, fetch issues in configured active states.
3. Attach registry metadata to each issue.
4. Sort candidates deterministically by priority, creation time, and identifier.

Review judge candidates are fetched from the configured review source state using
the same project boundary.

## Dispatch Gates

An issue can dispatch only when all gates pass:

- issue is still visible in Linear
- issue state is active and non-terminal
- assignee routing allows this worker, if configured
- unresolved Linear blockers are absent
- issue is not already claimed, running, retrying immediately, or judging
- global capacity is available
- project capacity is available
- state capacity for that project is available
- engine capacity is available
- selected engine is healthy
- required workflow is valid
- global policy validation allows dispatch
- budget and rate-limit policy allows a new run

Cycle should re-fetch the issue immediately before dispatch and preserve project
metadata across that refresh.

## Capacity Layers

Cycle should apply capacity in this order:

1. Global Cycle cap.
2. Engine cap.
3. Worker-host cap, if worker pools exist.
4. Project cap from repo workflow or metadata.
5. State cap from repo workflow.
6. Budget/rate-limit cap.

The first public version can implement budget/rate-limit as a conservative
disable or warning gate. Later versions can add weighted scheduling.

Budget and rate-limit gates support `off`, `warn`, and `block` modes. Warn mode
annotates scheduler decisions and status without blocking new dispatch.
Block mode prevents only new dispatch; it must not cancel, stop, or mutate
already running work solely because pressure appeared after the run started.

## Policy Drift Gate

Cycle should evaluate each project workflow against global policy before
dispatch. The scheduler should consume a normalized policy result:

- `valid`: workflow parses and required policy is satisfied.
- `drift`: workflow parses but differs from desired global policy.
- `invalid`: workflow cannot be used or violates a blocking policy.

In the default `report` mode, `drift` should be shown in status but should not
block dispatch. In `block` mode, drift against required settings should block
dispatch with a clear reason. In all modes, `invalid` should block dispatch for
that project only.

## Engine Selection

Engine selection should consider:

- project allowed engines
- global default engine
- engine health
- engine workflow schema compatibility
- engine capacity
- requested model defaults and sandbox capabilities

If no engine is available, the issue remains queued and `cycle status` should
show the reason.

## Run State

Cycle should persist run records with:

- run id
- Linear issue id and identifier
- project id and repo
- selected engine id/version
- workflow path and workflow hash
- workspace path, if Cycle allocates it
- current state: queued, running, retrying, judging, blocked, complete, failed
- start/end timestamps
- retry attempt and next retry time
- last event summary
- evidence pointers for review judge

## Retry And Stale-State Handling

Cycle should retry transient failures with capped backoff. It should not retry
when:

- issue moved to a terminal state
- issue left the active state set
- required workflow became invalid
- project was disabled
- engine version was removed without a replacement

Before each retry, Cycle should refresh Linear state and blockers.

## Status Requirements

`cycle status` should expose:

- polling state and next poll time
- watched project count and invalid project count
- running runs by project and engine
- queued/retrying runs and reasons
- blocked issue count
- review judge queue
- engine health
- capacity used versus available
- budget and rate-limit pressure state and reasons
- last discovery error per project
- policy drift count and drift details by project
- whether drift is report-only, blocking, or eligible for propagation

## Tests

Scheduler tests should cover:

- project-first candidate fetch
- dependency blocker skip
- state and terminal state filtering
- stale-state revalidation before dispatch
- project capacity cap
- state capacity cap
- engine capacity cap
- invalid workflow skip
- policy drift report and block modes
- deterministic sorting
- retry suppression when issue becomes terminal
