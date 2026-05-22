# Future Dashboard And Engine Protocol Roadmap

Cycle v1 is intentionally CLI-first. Operators should use `cycle status`,
`cycle doctor`, foreground `cycle start`, and the localhost API to inspect
projects, engines, runs, policy drift, and service health.

This roadmap captures future dashboard and multi-engine protocol work without
making it part of the v1 commitment.

## V1 Commitments

V1 should provide:

- read-only CLI status and doctor output for local operators
- a localhost-only JSON API for health, projects, engines, runs, and log
  pointers
- explicit Cycle-owned state files for registries, engine locks, run records,
  and policy validation results
- a conservative Symphony adapter that does not depend on private Symphony
  internals staying stable
- clear reporting when an installed engine cannot accept a single-issue
  dispatch request

V1 should not provide:

- a web dashboard
- browser authentication
- non-local API binding by default
- a generic multi-engine dispatch protocol beyond the adapter capability model
- direct mutation of existing Symphony services

## Future Dashboard Scope

A future dashboard should be a client of the local API, not a reader of Cycle
state files or Symphony internals. It can start as a local-only operator view
before any remote access is considered.

Useful dashboard surfaces:

- watched projects, invalid metadata, and workflow drift
- queued, running, failed, Human Review, and Merging work
- per-engine health, locked revisions, adapter capabilities, and upgrade
  status
- run timelines with links to workspaces, logs, PRs, and Linear issues
- capacity, token, retry, and rate-limit pressure across projects and engines
- release and migration readiness checks

Out of scope until explicitly designed:

- replacing the CLI
- editing project workflows from the browser
- starting or stopping existing Symphony services
- exposing a non-local API without authentication and authorization

## API Gaps

The v1 localhost API is enough for local status tools, but a dashboard would
need additional structured data before it can be useful:

- paginated run history and filtering by project, engine, state, issue, and
  time range
- stable event summaries for run lifecycle, retries, review judgement, and
  dispatch decisions
- normalized workflow validation and policy drift records
- explicit links to Linear issues, GitHub PRs, workspace paths, and log
  pointers with secret redaction rules
- engine capability and compatibility records exposed as API resources
- service lifecycle status for Cycle without mutating existing Symphony
  services
- versioned API schemas with backwards-compatible additions

If the API ever binds outside localhost, Cycle needs an explicit auth model,
transport security guidance, audit logging, and a review of which fields are
safe to expose remotely.

## Engine Protocol Gaps

The current adapter model can describe capabilities, run foreground processes,
and report that an engine lacks stable single-issue dispatch. A future engine
protocol should make the run boundary explicit and versioned.

Open gaps:

- request schema for one issue run, including issue identity, repo, workflow,
  workspace mode, policy inputs, and operator constraints
- status schema for queued, starting, running, retrying, judging, completed,
  failed, cancelled, and stale runs
- structured events for logs, workspace creation, Codex turn progress, review
  evidence, PR creation, and terminal summaries
- cancellation and retry semantics that do not affect unrelated services
- capability negotiation for workflow schema, workspace ownership, status API,
  review evidence, and supported policy fields
- stable error codes for workflow, config, auth, capacity, engine startup,
  unsupported capability, and operator-action-required failures
- version compatibility rules for multiple Symphony releases or non-Symphony
  engines

Cycle should continue to treat unknown or unsupported capabilities as explicit
adapter limitations rather than falling through to private engine behavior.

## Upstream Symphony Needs

Better dispatch would require upstream Symphony, or any compatible engine, to
expose a stable external contract for:

- accepting one issue run with a workflow path and structured run request
- returning an engine-owned run id and machine-readable status
- reporting lifecycle events and terminal summaries without requiring Cycle to
  parse private logs
- identifying the workspace path, changed files, PR URL, and review evidence
  when available
- advertising supported workflow schema versions and adapter capabilities
- returning structured, versioned errors for unsupported requests
- allowing foreground test runs separately from service installation

Cycle should keep the adapter boundary narrow until those contracts exist.

## Migration Strategy

The migration path should be staged:

1. Keep v1 on CLI plus localhost API and document unsupported engine
   capabilities clearly.
2. Extend the local API with versioned resources for run history, events,
   policy drift, and engine capabilities.
3. Add a read-only local dashboard that consumes only the API.
4. Introduce an explicit `cycle.engine.run.v1` request/status protocol in
   parallel with the current Symphony adapter.
5. Add compatibility shims per Symphony version and mark capability gaps in the
   engine registry.
6. Move dispatch from process/status adapters to the explicit protocol only
   after the selected engine advertises support.
7. Consider non-local dashboard access only after authentication,
   authorization, audit logging, and redaction rules are defined.

At each stage, Cycle remains the control plane and Symphony remains the
execution engine for isolated coding-agent runs.
