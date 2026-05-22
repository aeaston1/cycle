# Cycle Implementation PRD

Status: Draft implementation plan
Last updated: 2026-05-22
Audience: humans, Codex agents, Symphony agents, and future Linear issue authors

## Purpose

This document is the implementation-ready plan for Cycle, a Linear-native
control plane for running upstream OpenAI Symphony engines across many
repositories with policy, review judgement, capacity management, and
observability built in.

It is intentionally written in PRD and TODO form so it can be converted into
Linear milestones and issues. Each TODO is scoped as a shippable unit with
goal, decisions, acceptance criteria, implementation notes, test plan, and
handoff notes.

## Source Of Truth

This plan consolidates and operationalizes:

- `README.md`
- `AGENTS.md`
- `WORKFLOW.md`
- `docs/architecture.md`
- `docs/config.md`
- `docs/engine-protocol.md`
- `docs/metadata-spec.md`
- `docs/workflow-contract.md`
- `docs/scheduler-design.md`
- `docs/review-judge-policy.md`
- `docs/service-model.md`
- `docs/release.md`
- `docs/porting-map.md`
- `docs/supporting-skills.md`
- `reference/adapted-symphony/`

When implementation reveals drift, update the relevant source doc and this PRD
in the same PR, unless the PR is intentionally limited to a proof-of-concept
branch.

## Executive Summary

Cycle must become an Elixir OTP application with an escript-backed CLI. The
current Bash CLI is useful as a scaffold but should not be the long-term home
for metadata parsing, registries, scheduling, policy drift, review judgement,
service lifecycle, or status APIs.

Cycle owns the control plane:

- Linear project discovery across opted-in projects.
- `cycle:` Linear project metadata parsing.
- Project, engine, and run registries under Cycle state paths.
- Repo-owned `WORKFLOW.md` lookup and read-only orchestration extraction.
- Global policy, validation, drift reporting, and manual propagation.
- Scheduling decisions across projects, states, engines, workers, and budget.
- Linear dependency gating and stale-state revalidation.
- Review judge policy, idempotency, and Linear write safety.
- Status, local API, logs, service lifecycle, release packaging, and operator
  CLI.

Symphony remains the execution engine:

- It runs an isolated coding-agent lifecycle for one issue, one repo/workspace,
  and one workflow.
- It owns Codex app-server/session mechanics, workflow hooks during a run, run
  logs, and execution evidence.
- It should not be renamed, forked publicly, or made responsible for Cycle
  fleet policy.

The copied adapted-Symphony source is reference material. It proves the behavior
Cycle should productize, but it is not Cycle runtime code.

## Non-Negotiable Decisions

- Product name is `Cycle`.
- First real implementation uses Elixir and OTP, not Bash-only scripting.
- Development toolchain uses `mise`; use Erlang `28` and Elixir
  `1.19.5-otp-28` unless a later toolchain issue explicitly changes it.
- Public install path is Homebrew: `brew install aeaston1/tap/cycle`.
- Homebrew installs Cycle only. It must not install or mutate Codex skills.
- `cycle:` metadata is the only supported project opt-in namespace for Cycle.
- Legacy `symphony:` project metadata is not accepted by Cycle discovery.
- Linear metadata contains only project onboarding metadata. Repo workflow
  policy stays in each repo's `WORKFLOW.md`.
- Cycle state belongs under `${CYCLE_HOME:-~/.local/share/cycle}`.
- Cycle config belongs under `${XDG_CONFIG_HOME:-~/.config}/cycle`.
- Secrets are read from environment or operator-owned config outside the repo.
- Cycle never writes secrets into Linear metadata, repo docs, workflow files,
  Homebrew formulae, release artifacts, logs, or registry files.
- Cycle never mutates repo `WORKFLOW.md` files during discovery.
- Policy propagation is manual, explicit, auditable, and narrowly scoped.
- Default policy enforcement mode is `report`.
- Invalid project workflow state blocks that project only.
- `cycle service status` is read-only.
- `cycle service install` is conservative and never overwrites unrelated
  service files.
- Cycle must not stop, restart, replace, or disable existing Symphony services
  unless the operator explicitly asks.
- `reference/adapted-symphony/` is not vendored runtime code.
- Public docs and examples must use `OWNER/REPO` placeholders, except the fixed
  Homebrew tap command.

## Product Surface

### CLI Commands

Required CLI surface:

```sh
cycle --version
cycle help
cycle doctor
cycle linear configure [--from-env | --api-key TOKEN | --print]
cycle symphony install [--repo URL] [--version REF]
cycle symphony path [--version REF]
cycle project opt-in --repo URL
cycle project discover [--limit N] [--raw]
cycle start [--dry-run] [--no-dispatch] [--once]
cycle status [--json]
cycle service install [--dry-run] [--yes]
cycle service status [--json]
```

Later CLI surface, after the core is stable:

```sh
cycle policy drift [--json]
cycle policy propagate --project PROJECT --dry-run
cycle runs list [--json]
cycle runs show RUN_ID [--json]
cycle engines list [--json]
cycle engines health [--json]
cycle skills list
cycle skills install recommended
```

### Local API

The daemon should bind to `127.0.0.1:4765` by default and expose:

- `GET /health`
- `GET /api/v1/status`
- `GET /api/v1/projects`
- `GET /api/v1/engines`
- `GET /api/v1/runs`
- `GET /api/v1/runs/:id`
- `GET /api/v1/logs`

Non-local binding requires explicit config. No mutating API endpoints are in
scope for the first public version.

### Registry Files

Planned local state files:

```text
${CYCLE_HOME}/projects.yaml
${CYCLE_HOME}/engines.yaml
${CYCLE_HOME}/engines.lock
${CYCLE_HOME}/runs.yaml
${CYCLE_HOME}/logs/cycle.log
```

Registry files must be operator-inspectable, machine-readable, and safe to
delete only after stopping Cycle. Deletion may lose run history but must not
corrupt project repos or engine checkouts.

## Architecture

### Runtime Shape

Cycle should be an OTP application with:

- `Cycle.CLI` for command parsing and command dispatch.
- `Cycle.Config` for config loading, defaults, env interpolation, and
  validation.
- `Cycle.Registry.Store` for atomic YAML registry reads and writes.
- `Cycle.Linear.Client` for GraphQL calls.
- `Cycle.ProjectMetadata` for `cycle:` metadata parsing.
- `Cycle.ProjectDiscovery` for Linear project discovery and registry updates.
- `Cycle.WorkflowResolver` for repo workflow lookup and caching.
- `Cycle.WorkflowPolicy` for extracting Cycle-readable workflow fields.
- `Cycle.GlobalPolicy` and `Cycle.PolicyDrift` for fleet policy validation.
- `Cycle.EngineRegistry` for installed engine records and locks.
- `Cycle.Engine.Symphony` for upstream Symphony install, health, start, and
  status integration.
- `Cycle.Scheduler` for candidate selection, gates, capacity, and dispatch
  decisions.
- `Cycle.RunStore` for durable run records.
- `Cycle.Reconciler` for polling, retries, stale-state cleanup, and current
  status snapshots.
- `Cycle.Policy.ReviewJudge` for judge evidence, decisions, hashes, hard stops,
  and Linear routing.
- `Cycle.StatusSnapshot` for structured status.
- `Cycle.API` for the localhost status API.
- `Cycle.Service` for launchd/systemd install and read-only service status.

### Dependencies

Use a small dependency set:

- `yaml_elixir` for YAML and workflow front matter parsing.
- `jason` for JSON.
- `req` for HTTP/GraphQL.
- `nimble_options` only if helpful for option validation.
- `plug` and `bandit` for the local API.
- `bypass` or local fakes for HTTP tests if needed.
- `credo` only for dev/test linting.

Do not pull in Phoenix or LiveView for the first implementation unless a later
dashboard milestone explicitly decides to build a web UI.

### Engine Boundary

Cycle should supervise and integrate with upstream Symphony first. It should
not port Codex app-server mechanics or agent runner internals into Cycle.

The engine adapter must support two concepts:

- Current mode: process/status adapter around the installed upstream Symphony
  CLI and status endpoint.
- Future mode: explicit single-run request/status protocol when Symphony
  exposes one.

Until a stable single-run protocol exists, the scheduler should still build
durable run decisions and dispatch gates, but any real execution path must be
implemented through a clearly named Symphony adapter capability. If the adapter
cannot safely launch one issue run, Cycle must show the queued run and reason in
status rather than pretending dispatch happened.

### Data Flow

1. Load Cycle config from defaults, config file, env, and CLI flags.
2. Discover Linear projects visible to `LINEAR_API_KEY`.
3. Parse `cycle:` metadata.
4. Persist valid and invalid project entries.
5. Resolve each valid project's repo-owned workflow.
6. Extract scheduling and policy fields from workflow front matter.
7. Validate workflow against global policy.
8. Persist drift or invalid status.
9. Refresh engine registry and health.
10. Fetch candidate issues per valid enabled project.
11. Apply dependency, state, capacity, policy, and engine gates.
12. Re-fetch Linear issue state before dispatch.
13. Create or update a run record.
14. Hand the run to the selected engine adapter if supported.
15. Reconcile run status, retry transient failures, and expose status.
16. Review judge watches review source state and routes only after safe
    evidence, idempotency, and stale-state checks.

## Suggested Linear Milestones

- M0 - Runtime Foundation And Scaffold Alignment
- M1 - Config, Registries, And Project Metadata
- M2 - Linear Discovery And Workflow Policy
- M3 - Engine Registry And Symphony Adapter
- M4 - Scheduler, Run Store, And Foreground Daemon
- M5 - Observability, Status API, And Console
- M6 - Review Judge Policy And Routing
- M7 - Service Lifecycle And Migration Safety
- M8 - Release, Homebrew, And Operator Documentation
- M9 - Hardening, Scale, And Future Extensions

## Milestone M0 - Runtime Foundation And Scaffold Alignment

Goal: turn the current scaffold into a real Elixir application while preserving
the documented CLI surface and repo hygiene.

### TODO CYCLE-M0-001: Bootstrap the Elixir application

Status: Todo
Suggested Linear milestone: M0 - Runtime Foundation And Scaffold Alignment
Suggested issue title: Bootstrap Cycle as an Elixir OTP app

Goal:

Create the application skeleton that all later Cycle work will build on.

Background:

The repo currently has docs, a Bash CLI scaffold, smoke tests, and copied
adapted-Symphony reference files. It does not yet have a buildable Cycle app.

Decisions:

- Use Elixir OTP.
- Use `mise` with Erlang `28` and Elixir `1.19.5-otp-28`.
- Keep the app name `:cycle`.
- Keep public binary name `cycle`.
- Do not add Phoenix in this milestone.

Acceptance Criteria:

- `mise.toml` exists with pinned Erlang and Elixir versions.
- `mix.exs` exists with app `:cycle`, version `0.1.0-dev`, escript config, and
  minimal dependencies.
- `lib/cycle/application.ex` starts a supervision tree with no external side
  effects by default.
- `lib/cycle/cli.ex` exposes a callable `main/1`.
- `test/test_helper.exs` and one basic ExUnit test exist.
- `mise exec -- mix test` passes.
- `mise exec -- mix escript.build` builds a runnable `cycle` artifact.

Implementation Notes:

- Use `yaml_elixir`, `jason`, and `req` as early dependencies.
- Add `plug` and `bandit` only when the local API TODO starts, unless the
  implementer wants to pin them now for dependency stability.
- Avoid copying `SymphonyElixir.*` modules directly into runtime paths.
- If any reference code is ported, rename it into `Cycle.*` and trim it to the
  Cycle-owned boundary.

Architecture Review:

- Boundaries affected: build system, CLI entrypoint, application supervision.
- Data flow: none yet beyond CLI args.
- Security/privacy: no secrets should be read during app boot.
- Migration/rollout: existing Bash CLI can remain until the Elixir CLI is ready
  to replace it.

Simplification Notes:

- Do not build the daemon or API in this issue.
- Do not port scheduler or Linear code yet.
- Do not introduce umbrella apps.

Test Plan:

- Unit: basic CLI version/help tests.
- Build: `mise exec -- mix test`.
- Build: `mise exec -- mix escript.build`.
- Manual: run the generated artifact with `--version`.

Multi-Agent Suggestion:

Single implementer recommended. This touches the root app skeleton and will
conflict with most other early changes.

Handoff Notes:

- If `mise install` needs network access, record that as an environment
  prerequisite.
- Do not remove the Bash CLI until CYCLE-M0-002 is ready.

### TODO CYCLE-M0-002: Replace the Bash CLI with the Elixir CLI without breaking local usage

Status: Todo
Suggested Linear milestone: M0 - Runtime Foundation And Scaffold Alignment
Suggested issue title: Route `bin/cycle` through the Elixir CLI

Goal:

Make `bin/cycle` execute the Elixir implementation while preserving the current
operator command surface.

Background:

The Bash CLI currently implements `doctor`, `linear configure`, `symphony
install/path`, `project opt-in/discover`, `start`, `status`, and placeholder
service commands. The Elixir CLI must preserve these command names before
adding deeper behavior.

Decisions:

- `bin/cycle` remains the executable entrypoint for local development.
- Release artifacts may install a built escript as `bin/cycle`.
- The command surface should remain compatible with the current README.
- The new CLI should return stable exit codes: `0` success, `1` user/config
  error, `2` external dependency failure, `3` validation or policy block.

Acceptance Criteria:

- `./bin/cycle --version` prints `cycle 0.1.0-dev`.
- `./bin/cycle help` lists the documented commands.
- Existing command names remain accepted.
- Placeholder commands remain explicit where behavior is not implemented yet.
- `tests/smoke.sh` passes through `./bin/cycle`.
- Bash-only implementation logic is removed or reduced to a thin wrapper.

Implementation Notes:

- Prefer an Elixir argument parser implemented locally for the first version.
  The command surface is small enough that a dependency is not required.
- Keep help text in one place so tests and docs do not drift.
- If the wrapper invokes `mise exec -- mix run`, make sure release packaging has
  a separate path that does not require source checkout layout.

Architecture Review:

- Boundaries affected: local executable, CLI contracts, test harness.
- Data flow: CLI args to command modules.
- Security/privacy: do not print token values.
- Migration/rollout: update tests and README examples only after behavior
  exists.

Simplification Notes:

- Do not implement full command behavior here. Preserve or stub commands
  cleanly and delegate detailed behavior to later TODOs.

Test Plan:

- Unit: command parser tests for every documented command.
- Smoke: `tests/smoke.sh`.
- Manual: `./bin/cycle help`, `./bin/cycle --version`, unknown command behavior.

Multi-Agent Suggestion:

Single implementer recommended because CLI parser and smoke tests are tightly
coupled.

Handoff Notes:

- Keep stdout/stderr behavior intentional. Human output goes to stdout for
  status/help, errors to stderr.

### TODO CYCLE-M0-003: Establish test fixtures and local fakes

Status: Todo
Suggested Linear milestone: M0 - Runtime Foundation And Scaffold Alignment
Suggested issue title: Add test fixture strategy for Cycle registries and Linear calls

Goal:

Create the test foundation needed for config, registry, Linear, workflow, and
scheduler tests.

Background:

Future features touch local files, HTTP GraphQL, git checkouts, workflow YAML,
and service status. Tests need isolated temp directories and fakes before the
real implementation grows.

Decisions:

- Unit tests must not write to real `${CYCLE_HOME}` or `${XDG_CONFIG_HOME}`.
- Tests must use temporary directories for config/state.
- Linear calls must be faked unless a test is explicitly marked integration.
- Registry examples should live in `test/fixtures/`.

Acceptance Criteria:

- Test helper can create isolated config/state env for each test.
- Fixtures exist for valid `cycle:` metadata, `symphony:` metadata that must
  not opt in, invalid metadata, valid workflow, invalid workflow, and drifted
  workflow.
- HTTP fake support exists for Linear GraphQL tests.
- Test helper cleans temporary state after test runs.

Implementation Notes:

- Use `System.tmp_dir!()` plus unique test paths.
- Keep fixtures public-safe with `OWNER/REPO` examples.
- Avoid touching `.git` or global user config in tests.

Architecture Review:

- Boundaries affected: test support, filesystem isolation, HTTP isolation.
- Data flow: fake config/env/HTTP into Cycle modules.
- Security/privacy: tests must not require real `LINEAR_API_KEY`.
- Migration/rollout: none.

Simplification Notes:

- Do not build a full mock framework. A small helper module is enough.

Test Plan:

- Unit: test helper creates and cleans isolated paths.
- Unit: fake Linear returns configured JSON.
- Manual: run `mise exec -- mix test` repeatedly and confirm no state is left in
  real Cycle paths.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Later TODOs should reuse these helpers instead of inventing new temp-path
  setup.

### TODO CYCLE-M0-004: Align scaffold docs and smoke tests with the chosen implementation path

Status: Todo
Suggested Linear milestone: M0 - Runtime Foundation And Scaffold Alignment
Suggested issue title: Align docs and smoke tests with the Elixir Cycle path

Goal:

Remove obvious doc-to-code drift introduced by moving from Bash scaffold to
Elixir implementation.

Background:

The current docs already describe Cycle's target shape, but some scaffold
details are Bash-era details, such as `config.env`, Ruby formatting, and older
metadata guidance that referenced `symphony:` opt-in output.

Decisions:

- Preferred config file is `config.yaml`.
- Legacy `config.env` is compatibility only.
- `project opt-in` should print `cycle:` metadata by default.
- `symphony:` metadata compatibility is removed from the implementation plan
  and user-facing Cycle docs.

Acceptance Criteria:

- README, config docs, release docs, and smoke tests agree on the primary CLI
  behavior.
- Smoke tests expect `cycle:` metadata.
- Docs clearly mark any not-yet-implemented command behavior.
- No public docs hardcode private repo names or local machine paths.

Implementation Notes:

- Keep existing architecture docs intact unless behavior actually changes.
- Update examples in one PR with the CLI changes that make them true.

Architecture Review:

- Boundaries affected: docs, smoke tests.
- Data flow: none.
- Security/privacy: public repo hygiene.
- Migration/rollout: improves clarity for later agents.

Simplification Notes:

- Do not rewrite all docs for style. Fix concrete drift only.

Test Plan:

- Smoke: `tests/smoke.sh`.
- Manual: skim docs for `symphony:` metadata examples and remove them from
  Cycle opt-in guidance, except where they describe historical adapted-Symphony
  behavior.

Multi-Agent Suggestion:

Suitable as a docs-only parallel task once CYCLE-M0-002 is in review.

Handoff Notes:

- This should stay focused on alignment, not new product decisions.

## Milestone M1 - Config, Registries, And Project Metadata

Goal: implement durable local config/state foundations and project metadata
parsing before hitting live Linear.

### TODO CYCLE-M1-001: Implement Cycle config loading and validation

Status: Todo
Suggested Linear milestone: M1 - Config, Registries, And Project Metadata
Suggested issue title: Implement Cycle config loading and precedence

Goal:

Load operator config, environment, CLI overrides, and defaults into a validated
Cycle config struct.

Background:

Cycle needs consistent paths and policy before discovery, scheduling, service
installation, or Linear writes can be safe.

Decisions:

- Main config path is `${XDG_CONFIG_HOME:-~/.config}/cycle/config.yaml`.
- State path is `${CYCLE_HOME:-~/.local/share/cycle}`.
- Config precedence is CLI flags, environment variables, config file,
  repo-owned workflow, built-in defaults.
- `LINEAR_API_KEY` is read from environment by default.
- Legacy `${XDG_CONFIG_HOME:-~/.config}/cycle/config.env` may be read only for
  `LINEAR_API_KEY` compatibility.

Acceptance Criteria:

- Missing config file falls back to safe defaults.
- Valid config YAML loads into typed structs/maps.
- Invalid config returns structured errors with setting path and reason.
- Env interpolation works for documented `${CYCLE_HOME}` style paths.
- `CYCLE_HOME`, `XDG_CONFIG_HOME`, `CYCLE_STATUS_URL`,
  `CYCLE_SYMPHONY_REPO`, and `CYCLE_SYMPHONY_REF` are honored where
  documented.
- Secrets are never printed in full.

Implementation Notes:

- Implement `Cycle.Config`, `Cycle.Config.Paths`, and
  `Cycle.Config.Validation`.
- Normalize paths early.
- Keep validation messages user-readable and machine-testable.
- Store redacted values for display.

Architecture Review:

- Boundaries affected: all commands and daemon startup.
- Data flow: env/config/flags to normalized config.
- Security/privacy: secret redaction is mandatory.
- Migration/rollout: keep legacy `config.env` read support until a later
  deprecation issue.

Simplification Notes:

- Do not implement policy drift here. Only parse global policy fields.

Test Plan:

- Unit: default config.
- Unit: config file override.
- Unit: env override.
- Unit: CLI override, where implemented.
- Unit: invalid YAML and invalid values.
- Unit: redaction of Linear API key.

Multi-Agent Suggestion:

Single implementer recommended because config touches many future boundaries.

Handoff Notes:

- Later commands should accept a config struct instead of reading env directly.

### TODO CYCLE-M1-002: Implement atomic YAML registry storage

Status: Todo
Suggested Linear milestone: M1 - Config, Registries, And Project Metadata
Suggested issue title: Implement local registry persistence

Goal:

Provide a safe, reusable registry store for projects, engines, locks, and runs.

Background:

Cycle must persist discovered projects, installed engines, engine locks, and run
records in operator-inspectable state files.

Decisions:

- Registry files are YAML.
- Writes are atomic: write temp file, fsync where practical, then rename.
- Missing registry files load as empty collections.
- Invalid registry files fail with clear errors and do not overwrite data.

Acceptance Criteria:

- `Cycle.Registry.Store.read/2` and `write/3` or equivalent exist.
- Store creates parent directories with safe permissions.
- Missing file returns an empty default.
- Invalid YAML returns an error with file path and parse reason.
- Atomic write leaves either old valid content or new valid content.
- Tests prove write does not target repo paths by default.

Implementation Notes:

- Keep store generic, but provide typed wrappers later.
- Use lock files only if concurrent daemon writes become real. Do not overbuild
  locking before one daemon process exists.

Architecture Review:

- Boundaries affected: persistence, daemon status, CLI commands.
- Data flow: structs/maps to YAML files.
- Security/privacy: registries must not include secrets.
- Migration/rollout: registry schema versioning starts in CYCLE-M1-003.

Simplification Notes:

- Do not use a database for v1. YAML is enough and operator-inspectable.

Test Plan:

- Unit: read missing file.
- Unit: write and read round trip.
- Unit: invalid YAML.
- Unit: parent directory creation.
- Unit: atomic rewrite.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- All later persistence should use this store. Do not open-code file writes.

### TODO CYCLE-M1-003: Define versioned registry schemas

Status: Todo
Suggested Linear milestone: M1 - Config, Registries, And Project Metadata
Suggested issue title: Add versioned schemas for Cycle registries

Goal:

Make project, engine, engine lock, and run registry records explicit and
versioned.

Background:

The docs describe record shapes, but implementation needs stable structs,
schema versions, and migration behavior before agents start writing records.

Decisions:

- Each registry file includes `schema_version`.
- Initial schema version is `1`.
- Unknown future schema versions fail read-only with a clear upgrade error.
- Same-version unknown keys are preserved where practical or ignored safely.

Acceptance Criteria:

- Project registry schema includes Linear project id/name/slug/url, namespace,
  repo URL/full name, workflow path/resolved path, allowed engines, policy
  profile, capacity, last discovery time, status, error, and policy drift.
- Engine registry schema includes engine id/name/source/ref/install path,
  capabilities, health, and capacity.
- Engine lock schema includes engine name/ref/resolved revision/install time.
- Run registry schema includes run id, issue, project, engine, workflow hash,
  workspace path, state, timestamps, retry info, last event, and evidence
  pointers.
- Schema validation returns path-level errors.

Implementation Notes:

- Implement structs under `Cycle.ProjectRegistry`, `Cycle.EngineRegistry`, and
  `Cycle.RunStore` or equivalent.
- Keep validation separate from raw YAML parsing.
- Use ISO 8601 timestamps in UTC.

Architecture Review:

- Boundaries affected: registry persistence, status, scheduler.
- Data flow: raw registry YAML to typed records to command/status output.
- Security/privacy: exclude tokens and raw secrets from all schemas.
- Migration/rollout: no old registry migration needed yet.

Simplification Notes:

- Do not design every future field. Add explicit extension maps only where
  needed for unknown engine capabilities.

Test Plan:

- Unit: valid schema round trips.
- Unit: missing required field.
- Unit: invalid enum.
- Unit: future schema version.
- Unit: no secret fields allowed in sample records.

Multi-Agent Suggestion:

Suitable for parallel work with CYCLE-M1-004 only after CYCLE-M1-002 exists.

Handoff Notes:

- These schemas become the contract for Linear issue creation later.

### TODO CYCLE-M1-004: Implement metadata parser and validator

Status: Todo
Suggested Linear milestone: M1 - Config, Registries, And Project Metadata
Suggested issue title: Parse and validate Cycle Linear project metadata

Goal:

Parse Linear project description/content blocks into validated project metadata.

Background:

Cycle discovers projects through Linear project metadata. The only supported
Cycle opt-in namespace is `cycle:`.

Decisions:

- Parse the first valid `cycle:` block.
- Do not parse `symphony:` metadata as a Cycle project opt-in.
- When both `cycle:` and `symphony:` blocks are present, only `cycle:` affects
  Cycle discovery.
- Only `enabled: true` opts a project in.
- First public version supports HTTPS GitHub repo URLs only.
- Repo URLs may omit `.git`; normalize internally.
- Workflow defaults to `WORKFLOW.md`.

Acceptance Criteria:

- Valid minimal `cycle:` metadata parses.
- Valid recommended `cycle:` metadata parses.
- A project with only `symphony:` metadata is not opted in.
- `symphony:` metadata does not override or supplement `cycle:` metadata.
- Disabled projects are not treated as valid opted-in projects.
- Invalid repo URL is reported with a clear error.
- Non-positive capacity values are rejected.
- Unknown fields are preserved or ignored safely, but do not fail valid
  metadata unless they conflict with known fields.

Implementation Notes:

- Implement `Cycle.ProjectMetadata`.
- Use structured YAML parsing, not regex-only parsing.
- The current Bash regex approach is not sufficient for nested metadata.
- Preserve the source field location for status output.

Architecture Review:

- Boundaries affected: Linear discovery, registry validation, CLI opt-in.
- Data flow: Linear description/content to metadata struct.
- Security/privacy: metadata must not include secrets. Warn or reject likely
  token-looking fields if encountered.
- Migration/rollout: existing `symphony:` metadata does not opt a project into
  Cycle; operators must add `cycle:` metadata.

Simplification Notes:

- Do not fetch Linear in this issue. Use fixture strings.

Test Plan:

- Unit: minimal/recommended examples.
- Unit: `symphony:` only is ignored.
- Unit: `cycle:` is authoritative when both namespaces are present.
- Unit: invalid YAML.
- Unit: invalid repo URL.
- Unit: capacity validation.
- Unit: workflow path validation.

Multi-Agent Suggestion:

Single implementer recommended because parser decisions affect discovery and
docs.

Handoff Notes:

- After this lands, update `project opt-in` to output `cycle:` metadata.

## Milestone M2 - Linear Discovery And Workflow Policy

Goal: connect to Linear, persist project discovery state, resolve workflows, and
record validation and drift without dispatching work yet.

### TODO CYCLE-M2-001: Implement the Linear GraphQL client

Status: Todo
Suggested Linear milestone: M2 - Linear Discovery And Workflow Policy
Suggested issue title: Implement Cycle Linear GraphQL client

Goal:

Provide a Cycle-owned Linear client for project discovery, issue fetch, comments,
and state updates.

Background:

The adapted Symphony reference has Linear modules, but Cycle needs its own
client boundary so scheduler and review judge do not depend on Symphony app
sessions.

Decisions:

- Use Linear GraphQL endpoint `https://api.linear.app/graphql` by default.
- Auth token comes from config-defined env var, default `LINEAR_API_KEY`.
- Client returns typed success/error tuples, not process exits.
- Client never logs full GraphQL variables when they may contain secrets.

Acceptance Criteria:

- Client can list projects with id, name, slugId, url, description, and content.
- Client can fetch issues by project and state names.
- Client can refresh an issue by id.
- Client can fetch issue comments.
- Client can create comments.
- Client can update issue state by state name.
- HTTP, auth, GraphQL, decode, and rate-limit errors are distinguishable.

Implementation Notes:

- Implement `Cycle.Linear.Client`.
- Keep query documents in module functions or separate `.graphql` files if that
  improves testability.
- Use pagination for projects and issues.
- Preserve raw Linear ids for all writes.

Architecture Review:

- Boundaries affected: external Linear API, discovery, scheduler, review judge.
- Data flow: Cycle config token to GraphQL request to typed records.
- Security/privacy: redact token and avoid logging comment bodies by default.
- Migration/rollout: no writes should happen until commands call write methods.

Simplification Notes:

- Do not implement every Linear field. Fetch only fields required by docs and
  scheduler gates.

Test Plan:

- Unit: request shape using fake HTTP.
- Unit: pagination.
- Unit: GraphQL error.
- Unit: auth missing.
- Unit: state update mutation shape.
- Optional manual: with real `LINEAR_API_KEY`, `cycle project discover --limit 5`.

Multi-Agent Suggestion:

Single implementer recommended. External API shape should be consistent.

Handoff Notes:

- If Linear schema has changed, update docs and tests with concrete field names.

### TODO CYCLE-M2-002: Implement project discovery and registry updates

Status: Todo
Suggested Linear milestone: M2 - Linear Discovery And Workflow Policy
Suggested issue title: Discover opted-in Linear projects into the Cycle registry

Goal:

Make `cycle project discover` list and persist valid and invalid opted-in
projects.

Background:

Project discovery is the first concrete Cycle control-plane behavior. It should
be useful before scheduling exists.

Decisions:

- Discovery is project-first.
- Valid and invalid opted-in projects both appear in status.
- Invalid projects do not block other projects.
- `--raw` prints raw Linear response or raw normalized records, but must be
  documented.
- Default human output is tabular and stable enough for operators.

Acceptance Criteria:

- `cycle project discover` reads Linear projects visible to the configured
  token.
- It parses `cycle:` project metadata using CYCLE-M1-004.
- It writes `${CYCLE_HOME}/projects.yaml`.
- It shows namespace, project name, slug, repo, workflow path, status, and last
  error.
- It exits non-zero only for discovery-wide failures, not per-project invalid
  metadata.
- `cycle project opt-in --repo URL` prints minimal `cycle:` metadata.

Implementation Notes:

- Implement `Cycle.ProjectDiscovery`.
- Persist `metadata_namespace: cycle` for opted-in projects.
- Store `last_discovered_at` in UTC.
- Include invalid records with `status: invalid` and machine-readable errors.

Architecture Review:

- Boundaries affected: Linear API, project registry, CLI.
- Data flow: Linear projects to metadata parser to registry.
- Security/privacy: descriptions may contain sensitive text. Registry should
  store only metadata-derived fields, not full descriptions.
- Migration/rollout: existing `symphony:` metadata is ignored until operators
  add `cycle:` metadata.

Simplification Notes:

- Do not resolve workflows in this issue unless CYCLE-M2-003 is included.
- Do not fetch issues yet.

Test Plan:

- Unit: discovery with mixed valid/invalid projects.
- Unit: registry write after discovery.
- Unit: per-project invalid does not fail command.
- CLI: opt-in output.
- CLI: discover output with fake Linear.

Multi-Agent Suggestion:

Suitable for parallelization with workflow resolver only after metadata parser
and registry store are merged.

Handoff Notes:

- This is a natural first milestone for Linear conversion because it provides
  visible operator value.

### TODO CYCLE-M2-003: Implement repo workflow resolver and cache

Status: Todo
Suggested Linear milestone: M2 - Linear Discovery And Workflow Policy
Suggested issue title: Resolve repo-owned WORKFLOW.md for discovered projects

Goal:

Resolve each discovered project's repo-owned workflow file and cache it under
Cycle state.

Background:

Cycle must read project workflow policy from each repository, but must not
mutate project repos during discovery.

Decisions:

- Workflow lookup order is metadata `cycle.workflow`, default `WORKFLOW.md`,
  local checkout compatibility, then cached clone under Cycle state.
- Cached clones live under `${CYCLE_HOME}/workflow-cache`.
- Discovery may clone or fetch when configured to do so.
- Cycle never commits, pushes, or edits workflows during discovery.

Acceptance Criteria:

- Resolver finds workflow in a local repo path when metadata repo is local.
- Resolver finds workflow in an existing local checkout for development
  compatibility.
- Resolver clones HTTPS GitHub repos into Cycle cache when needed.
- Resolver fetches existing cache safely.
- Missing workflow marks project invalid with clear error.
- Registry stores configured workflow path and resolved/cache path.

Implementation Notes:

- Implement `Cycle.WorkflowResolver`.
- Port carefully from `reference/adapted-symphony/lib/.../project_workflow.ex`
  but keep Cycle names and boundaries.
- Use `git` via safe argument lists, not shell string interpolation.
- Sanitize cache path using repo full name, for example `OWNER-REPO`.

Architecture Review:

- Boundaries affected: filesystem, git, project registry, workflow policy.
- Data flow: project repo metadata to local cache path to workflow content.
- Security/privacy: do not clone non-HTTPS URLs; do not log credentials in URLs.
- Migration/rollout: local checkout compatibility helps development.

Simplification Notes:

- Do not parse policy in this issue. Return workflow path/content/hash.

Test Plan:

- Unit: path normalization.
- Unit: missing workflow.
- Integration: local temp git repo with workflow.
- Integration: existing cache fetch behavior using local bare repo fixture.
- CLI: discovery shows workflow error.

Multi-Agent Suggestion:

Single implementer recommended due to git/path safety concerns.

Handoff Notes:

- If network is unavailable, tests must still pass using local git fixtures.

### TODO CYCLE-M2-004: Implement workflow parser and Cycle-readable extraction

Status: Todo
Suggested Linear milestone: M2 - Linear Discovery And Workflow Policy
Suggested issue title: Extract Cycle scheduling policy from repo workflows

Goal:

Parse repo `WORKFLOW.md` front matter and extract only the fields Cycle needs
for orchestration and policy.

Background:

Project workflows may contain engine prompts and unknown fields. Cycle must not
rewrite or drop unknown content.

Decisions:

- Cycle reads only fields documented in `docs/workflow-contract.md`.
- Unknown workflow fields are passed through or ignored safely.
- YAML front matter must parse as a map.
- Workflow hash should include the relevant workflow content used for policy
  and dispatch provenance.

Acceptance Criteria:

- Valid workflow front matter parses.
- Missing front matter or non-map front matter returns invalid workflow error.
- Extracted policy includes agent capacity, active states, terminal states,
  review judge settings, worker host settings, and hooks metadata.
- Invalid field types return path-level validation errors.
- Unknown fields do not fail parsing.

Implementation Notes:

- Implement `Cycle.WorkflowPolicy`.
- Port ideas from `reference/adapted-symphony/lib/.../workflow.ex` and
  `config/schema.ex`, but keep only Cycle-readable fields.
- Use normalized issue state names for capacity map keys.

Architecture Review:

- Boundaries affected: workflow resolver, scheduler, policy drift.
- Data flow: workflow content to extracted policy struct and hash.
- Security/privacy: do not persist prompt body unnecessarily.
- Migration/rollout: current Symphony workflow fields remain accepted.

Simplification Notes:

- Do not attempt full Symphony workflow validation. Validate only Cycle-owned
  fields plus minimal pass-through requirements.

Test Plan:

- Unit: valid workflow.
- Unit: no front matter.
- Unit: invalid YAML.
- Unit: bad capacity values.
- Unit: unknown fields accepted.
- Unit: state limit normalization.

Multi-Agent Suggestion:

Can run in parallel with global policy evaluator if interfaces are agreed.

Handoff Notes:

- Keep fixture workflows small and public-safe.

### TODO CYCLE-M2-005: Implement global policy validation and drift records

Status: Todo
Suggested Linear milestone: M2 - Linear Discovery And Workflow Policy
Suggested issue title: Validate project workflows against Cycle global policy

Goal:

Compare extracted workflow policy against operator-owned global policy and
persist `valid`, `drift`, or `invalid` status.

Background:

The adapted Symphony global workflow merge can provide defaults, but it is not
a fleet policy enforcement system. Cycle must own policy validation and drift
reporting.

Decisions:

- Default enforcement mode is `report`.
- `drift` is visible but does not block dispatch in `report` mode.
- `block` mode prevents dispatch for required-policy drift.
- `invalid` always prevents dispatch for that project.
- Drift records are machine-readable and status-friendly.

Acceptance Criteria:

- Global policy config parses required Codex, review judge, capacity, and engine
  settings.
- Project workflow can be classified as `valid`, `drift`, or `invalid`.
- Drift records include setting path, desired value, observed value, severity,
  and propagation availability.
- Project registry persists policy validation and drift.
- `cycle status` can summarize drift count even before scheduler exists.

Implementation Notes:

- Implement `Cycle.GlobalPolicy` and `Cycle.PolicyDrift`.
- Use path strings like `review_judge.model` and
  `agent.max_concurrent_agents`.
- Keep propagation eligibility as data only. Do not implement propagation here.

Architecture Review:

- Boundaries affected: config, workflow policy, project registry, scheduler.
- Data flow: global policy plus workflow policy to drift records.
- Security/privacy: no secrets involved.
- Migration/rollout: only projects opted in with `cycle:` metadata are eligible
  for policy validation and dispatch.

Simplification Notes:

- Do not create branches or PRs for drift. That is a later TODO.

Test Plan:

- Unit: valid exact match.
- Unit: missing defaultable setting.
- Unit: report-mode drift.
- Unit: block-mode drift.
- Unit: invalid workflow.
- Unit: drift record shape.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Scheduler should consume the normalized policy result, not recompute drift.

## Milestone M3 - Engine Registry And Symphony Adapter

Goal: install, pin, health-check, and supervise upstream Symphony engines
without making Cycle a Symphony fork.

### TODO CYCLE-M3-001: Implement engine id parsing, registry, and lock file

Status: Todo
Suggested Linear milestone: M3 - Engine Registry And Symphony Adapter
Suggested issue title: Add Cycle engine registry and version lock

Goal:

Track installed Symphony engines and locked revisions.

Background:

Cycle must select and pin engine versions so control-plane upgrades do not
accidentally change execution behavior.

Decisions:

- Engine ids use `name@ref`, for example `openai-symphony@main`.
- Default engine is `openai-symphony@main`.
- Engine install root is `${CYCLE_HOME}/engines`.
- Lock file stores resolved git revision and install timestamp.

Acceptance Criteria:

- Engine id parser validates name/ref and rejects invalid ids.
- Engine registry stores source repo, ref, install path, capabilities, health,
  and capacity.
- Engine lock stores resolved revision.
- `cycle symphony path [--version REF]` reads config and prints install path.
- Status reports missing versus installed engine.

Implementation Notes:

- Implement `Cycle.EngineRegistry` and `Cycle.EngineId`.
- Treat lock file as separate from registry so health can change without
  changing version lock.

Architecture Review:

- Boundaries affected: engine install, scheduler engine selection, status.
- Data flow: config to engine records and lock file.
- Security/privacy: engine repo URLs must not contain tokens.
- Migration/rollout: current Bash path behavior should remain compatible.

Simplification Notes:

- Only support `openai-symphony` initially.

Test Plan:

- Unit: valid/invalid engine ids.
- Unit: registry round trip.
- Unit: lock round trip.
- CLI: `cycle symphony path`.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Later support for other engines should be additive through capabilities.

### TODO CYCLE-M3-002: Implement Symphony install and update behavior

Status: Todo
Suggested Linear milestone: M3 - Engine Registry And Symphony Adapter
Suggested issue title: Install and pin upstream OpenAI Symphony engines

Goal:

Make `cycle symphony install` clone or update upstream Symphony into Cycle's
engine directory and update the engine lock.

Background:

The current Bash scaffold clones `https://github.com/openai/symphony.git` into
`${CYCLE_HOME}/engines/openai-symphony/<ref>`. The Elixir implementation should
preserve and harden that behavior.

Decisions:

- Default repo is `https://github.com/openai/symphony.git`.
- CLI `--repo` and `--version` override config/env.
- Existing engine checkout is updated with fetch, checkout, and fast-forward
  pull when possible.
- Target path that exists but is not a git checkout is an error.
- Installation does not modify project checkouts.

Acceptance Criteria:

- Fresh install clones the configured repo/ref.
- Existing install updates safely.
- Lock file records resolved revision.
- Missing expected Symphony executable or workflow path is reported clearly.
- Network/git failures return structured external dependency errors.
- No secrets are logged from repo URLs.

Implementation Notes:

- Use `System.cmd/3` with args.
- Validate install path is under Cycle engine root before git operations.
- Consider shallow clone only if it does not break version/revision reporting.

Architecture Review:

- Boundaries affected: filesystem, git, engine registry.
- Data flow: config/CLI to git checkout to registry/lock.
- Security/privacy: URL redaction.
- Migration/rollout: does not replace existing services.

Simplification Notes:

- Do not run Symphony as part of install.

Test Plan:

- Integration: install from local git fixture.
- Unit: target exists not git checkout.
- Unit: lock file updated.
- CLI: path output after install fixture.

Multi-Agent Suggestion:

Single implementer recommended due to path safety.

Handoff Notes:

- Live install against GitHub may need network approval in this environment.

### TODO CYCLE-M3-003: Implement engine health checks

Status: Todo
Suggested Linear milestone: M3 - Engine Registry And Symphony Adapter
Suggested issue title: Health-check managed Symphony engines

Goal:

Determine whether an installed engine can receive work.

Background:

Scheduler and status need a clear engine health result before dispatch.

Decisions:

- Minimum checks are install path, expected executable, readable git revision,
  required runtime commands, optional status API, workflow schema compatibility,
  and policy capability compatibility.
- Health result is persisted in the engine registry.
- Health failures are visible in `cycle status`.

Acceptance Criteria:

- Healthy installed engine reports `healthy`.
- Missing install path reports `missing`.
- Missing executable reports `invalid`.
- Runtime command failure reports `unhealthy` with reason.
- Status API check is attempted only if capability says `status_api: true`.
- Health record includes `checked_at`.

Implementation Notes:

- Implement `Cycle.Engine.Health`.
- Keep health check read-only except registry update.
- Do not start services during health check.

Architecture Review:

- Boundaries affected: scheduler, status, service install preflight.
- Data flow: engine registry to health probe to registry.
- Security/privacy: no tokens required.
- Migration/rollout: safe to run on existing engine checkouts.

Simplification Notes:

- Do not require engine status API for first install if upstream lacks it.
  Report degraded capability instead.

Test Plan:

- Unit: missing path.
- Unit: missing executable.
- Unit: fake executable success.
- Unit: fake status API success/failure.

Multi-Agent Suggestion:

Suitable for parallelization with service preflight after engine registry lands.

Handoff Notes:

- Use this module from `doctor`, `status`, scheduler, and service install.

### TODO CYCLE-M3-004: Define and implement the Symphony adapter boundary

Status: Todo
Suggested Linear milestone: M3 - Engine Registry And Symphony Adapter
Suggested issue title: Implement the Cycle-to-Symphony adapter contract

Goal:

Create the adapter layer that lets Cycle talk to managed Symphony engines
without owning agent execution internals.

Background:

Cycle needs to dispatch and observe work, but upstream Symphony may not yet
expose a stable single-run protocol. The adapter must be explicit about what it
can and cannot do.

Decisions:

- Define `Cycle.Engine.Adapter` behavior with install, health, capabilities,
  start_foreground, dispatch, status, and stop interfaces.
- Implement `Cycle.Engine.Symphony`.
- Current adapter supports process/status supervision first.
- Single-issue dispatch must be capability-gated.
- If dispatch is unsupported, scheduler records the queued run and status shows
  `engine_dispatch_unsupported`.

Acceptance Criteria:

- Adapter capabilities are machine-readable.
- `cycle start --dry-run` shows the exact engine command without executing it.
- `cycle start` can run the managed Symphony process in foreground when config
  is valid.
- Scheduler can ask whether dispatch is supported before creating a running
  record.
- Unsupported dispatch is not treated as success.

Implementation Notes:

- Current command shape should preserve the required no-guardrails flag only
  when operator-approved config says foreground unattended operation is allowed.
- Do not source full shell profile files. Pass explicit environment only.
- If current Symphony supports status endpoint, poll it through adapter.

Architecture Review:

- Boundaries affected: engine process management, scheduler, service lifecycle.
- Data flow: run request to adapter command/status.
- Security/privacy: environment should include only required values.
- Migration/rollout: supports running beside existing Symphony.

Simplification Notes:

- Do not port `Codex.AppServer`, `AgentRunner`, or prompt builder into Cycle.

Test Plan:

- Unit: capability-gated dispatch.
- Unit: dry-run command rendering.
- Unit: missing engine executable.
- Integration: fake engine process emits status.

Multi-Agent Suggestion:

Single implementer recommended because this is a core boundary decision.

Handoff Notes:

- This TODO should explicitly document any upstream Symphony protocol gaps found
  during implementation.

## Milestone M4 - Scheduler, Run Store, And Foreground Daemon

Goal: make Cycle decide which work should run, why work is blocked, and how run
state is persisted.

### TODO CYCLE-M4-001: Implement issue model and candidate fetch

Status: Todo
Suggested Linear milestone: M4 - Scheduler, Run Store, And Foreground Daemon
Suggested issue title: Fetch scheduler candidates from opted-in Linear projects

Goal:

Build normalized issue records for scheduler and review judge candidates.

Background:

The scheduler must fetch issues project-by-project from valid enabled registry
entries and preserve project metadata through refreshes.

Decisions:

- Candidate fetch uses valid enabled project registry entries.
- Active states come from Cycle config and project workflow policy.
- Review judge candidates use the configured review source state.
- Sorting is deterministic by priority, creation time, and identifier.

Acceptance Criteria:

- Issue struct includes id, identifier, title, state, state type, url, branch,
  assignee, labels, blockers, priority, timestamps, and project metadata.
- Candidate fetch queries each valid project.
- Candidate fetch skips invalid/disabled projects with status reason.
- Candidate sorting is deterministic.
- Project metadata is attached to each issue.

Implementation Notes:

- Implement `Cycle.Issue` and `Cycle.Tracker`.
- Port normalized shape from adapted Symphony `linear/issue.ex` but rename and
  trim to Cycle needs.

Architecture Review:

- Boundaries affected: Linear client, project registry, scheduler.
- Data flow: Linear issue nodes to normalized issues.
- Security/privacy: issue descriptions/comments are not needed for scheduler
  candidates by default.
- Migration/rollout: supports existing Linear state names.

Simplification Notes:

- Do not dispatch in this issue.

Test Plan:

- Unit: issue normalization.
- Unit: candidate fetch mixed project states.
- Unit: deterministic sorting.
- Unit: metadata preservation.

Multi-Agent Suggestion:

Can run in parallel with RunStore after interfaces are agreed.

Handoff Notes:

- Review judge may later reuse the issue model.

### TODO CYCLE-M4-002: Implement scheduler gates and capacity evaluation

Status: Todo
Suggested Linear milestone: M4 - Scheduler, Run Store, And Foreground Daemon
Suggested issue title: Apply Cycle scheduler gates and capacity rules

Goal:

Decide which candidates can run and why others are blocked or queued.

Background:

The adapted Symphony scheduler already handles multi-project capacity,
dependency gating, and stale-state refresh. Cycle adds engine-aware and durable
state.

Decisions:

- Gates follow the order documented in `docs/scheduler-design.md`.
- Capacity order is global, engine, worker host, project, state, budget/rate.
- Unresolved Linear blockers prevent dispatch.
- `invalid` workflow blocks dispatch.
- `drift` only blocks in `block` mode.
- Issue is re-fetched immediately before dispatch.

Acceptance Criteria:

- Scheduler returns a decision for every candidate: dispatch, queued, blocked,
  skipped, or retry later.
- Each non-dispatch decision includes a stable reason code and human message.
- Project and state capacity are enforced.
- Engine capacity and health are enforced.
- Stale issue state before dispatch prevents dispatch.
- Unresolved blockers prevent dispatch.

Implementation Notes:

- Implement `Cycle.Scheduler`.
- Use normalized policy result from CYCLE-M2-005.
- Preserve project metadata after issue refresh if Linear refresh lacks it.
- Stable reason codes should power status and tests.

Architecture Review:

- Boundaries affected: scheduler, Linear client, engine registry, run store.
- Data flow: candidates plus registries plus run state to scheduler decisions.
- Security/privacy: no new secret path.
- Migration/rollout: dispatch can be dry-run until adapter supports execution.

Simplification Notes:

- Budget/rate-limit can be warning or disabled gate in first pass, but the
  reason code must exist.

Test Plan:

- Unit: blocker skip.
- Unit: active/terminal state filtering.
- Unit: global capacity.
- Unit: engine capacity.
- Unit: project capacity.
- Unit: state capacity.
- Unit: drift report/block behavior.
- Unit: stale-state revalidation.

Multi-Agent Suggestion:

Single implementer recommended because gates interact heavily.

Handoff Notes:

- This is a high-risk core module. Keep tests dense and behavior explicit.

### TODO CYCLE-M4-003: Implement durable RunStore

Status: Todo
Suggested Linear milestone: M4 - Scheduler, Run Store, And Foreground Daemon
Suggested issue title: Persist Cycle run records and lifecycle transitions

Goal:

Persist run records and transitions for queued, running, retrying, judging,
blocked, completed, failed, cancelled, and stale runs.

Background:

Cycle status, retries, review judge evidence, and service recovery depend on a
durable run store.

Decisions:

- Run records live in `${CYCLE_HOME}/runs.yaml`.
- Run ids are Cycle-generated and stable.
- Run states are explicit and finite.
- RunStore owns transition validation.

Acceptance Criteria:

- RunStore can create queued run records.
- RunStore can transition through valid states.
- Invalid transitions are rejected.
- Records include issue, project, engine, workflow path/hash, timestamps, retry
  info, last event, and evidence pointers.
- RunStore survives process restart through registry persistence.

Implementation Notes:

- Implement `Cycle.RunStore`.
- Use monotonic or UUID-style ids with no external service dependency.
- Keep event history small in v1; store last event summary and pointers.

Architecture Review:

- Boundaries affected: scheduler, reconciler, status, review judge.
- Data flow: scheduler decisions to persisted run records.
- Security/privacy: evidence pointers only, not raw secrets or full logs.
- Migration/rollout: deleting runs file loses history but not project config.

Simplification Notes:

- Do not implement a database or event-sourcing system in v1.

Test Plan:

- Unit: create run.
- Unit: valid transitions.
- Unit: invalid transitions.
- Unit: retry fields.
- Unit: persistence round trip.

Multi-Agent Suggestion:

Can run in parallel with candidate fetch after registry store exists.

Handoff Notes:

- The status API should consume RunStore, not re-derive run history from logs.

### TODO CYCLE-M4-004: Implement reconciler loop and foreground `cycle start`

Status: Todo
Suggested Linear milestone: M4 - Scheduler, Run Store, And Foreground Daemon
Suggested issue title: Run Cycle discovery and scheduling in foreground

Goal:

Make `cycle start` run the Cycle control loop in the foreground for operator
testing.

Background:

Service install should come later. Foreground start proves discovery,
validation, scheduling, status, and adapter integration without mutating
services.

Decisions:

- `cycle start` reads config, registries, validates workflows, reports drift,
  starts polling, and prints logs to stdout/stderr.
- `--dry-run` prints planned actions and exits.
- `--no-dispatch` runs discovery and scheduling decisions without engine
  dispatch.
- `--once` runs one discovery/scheduler cycle and exits.
- Foreground start does not install services.

Acceptance Criteria:

- Invalid config fails fast.
- Missing Linear auth fails clearly before polling.
- Missing engine reports engine health and does not crash.
- One-shot mode updates discovery and scheduler decisions once.
- No-dispatch mode records queued/blocked decisions without engine launch.
- Foreground mode can be interrupted cleanly.

Implementation Notes:

- Implement `Cycle.Reconciler`.
- The OTP supervision tree should start only needed processes for CLI mode.
- Keep polling interval configurable.

Architecture Review:

- Boundaries affected: application runtime, scheduler, discovery, engine
  adapter.
- Data flow: periodic reconcile to registries and status.
- Security/privacy: logs are redacted.
- Migration/rollout: safe beside existing Symphony service.

Simplification Notes:

- Do not implement systemd/launchd here.

Test Plan:

- Unit: one reconcile cycle with fakes.
- Integration: `cycle start --once --no-dispatch` with fake Linear.
- Manual: interrupt foreground process.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- This is the transition point where several previous milestones integrate.

### TODO CYCLE-M4-005: Implement retry and stale-state handling

Status: Todo
Suggested Linear milestone: M4 - Scheduler, Run Store, And Foreground Daemon
Suggested issue title: Add retry and stale-state handling to the Cycle reconciler

Goal:

Handle transient failures without repeating stale or unsafe work.

Background:

Adapted Symphony retries failed runs with backoff and suppresses retries when
issue state or project state no longer permits work.

Decisions:

- Retry transient engine startup and external service failures with capped
  backoff.
- Do not retry terminal issue state, inactive issue state, invalid workflow,
  disabled project, or removed engine without replacement.
- Refresh Linear state and blockers before every retry.

Acceptance Criteria:

- Retry attempts increment and persist.
- Next retry time is stored.
- Terminal issue suppresses retry.
- Disabled project suppresses retry.
- Invalid workflow suppresses retry.
- Retry reasons appear in status.

Implementation Notes:

- Reuse scheduler gates for retry decisions where possible.
- Keep retry delay deterministic in tests.

Architecture Review:

- Boundaries affected: RunStore, scheduler, Linear client, status.
- Data flow: failed run to retry decision to run state update.
- Security/privacy: no new secret path.
- Migration/rollout: retries should be conservative.

Simplification Notes:

- Do not implement advanced priority queues in v1.

Test Plan:

- Unit: transient retry.
- Unit: capped backoff.
- Unit: terminal suppression.
- Unit: inactive suppression.
- Unit: disabled project suppression.
- Unit: invalid workflow suppression.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Retry behavior must be reflected in `cycle status`.

## Milestone M5 - Observability, Status API, And Console

Goal: make Cycle's operating picture visible through CLI, API, logs, and
registry state.

### TODO CYCLE-M5-001: Implement structured StatusSnapshot

Status: Todo
Suggested Linear milestone: M5 - Observability, Status API, And Console
Suggested issue title: Build Cycle status snapshot model

Goal:

Create one structured status model consumed by CLI, API, and tests.

Background:

Status must report projects, engines, runs, drift, review queue, capacity, and
service/API health without duplicating logic in each output surface.

Decisions:

- `Cycle.StatusSnapshot` is the single read model for status.
- Snapshot includes counts and details.
- JSON output uses stable keys.
- Human CLI output may be concise but must not hide blockers.

Acceptance Criteria:

- Snapshot includes config/state paths.
- Snapshot includes Linear auth configured/missing without token.
- Snapshot includes watched and invalid project counts.
- Snapshot includes engine health.
- Snapshot includes running, queued, retrying, blocked, judging, completed, and
  failed run counts.
- Snapshot includes capacity used/available by global, project, state, and
  engine where available.
- Snapshot includes drift count and top drift details.
- Snapshot includes last discovery errors.

Implementation Notes:

- Build from registry files and in-memory reconciler state.
- Keep snapshot serializable to JSON.

Architecture Review:

- Boundaries affected: CLI status, API, service status, tests.
- Data flow: registries to status read model.
- Security/privacy: redact secrets and avoid raw comments/log bodies.
- Migration/rollout: can work before daemon exists.

Simplification Notes:

- Do not build a terminal dashboard UI in v1. Plain CLI plus API is enough.

Test Plan:

- Unit: empty state snapshot.
- Unit: populated state snapshot.
- Unit: redaction.
- Unit: stable JSON keys.

Multi-Agent Suggestion:

Suitable for parallel work with local API after schema is agreed.

Handoff Notes:

- All status output should go through this model.

### TODO CYCLE-M5-002: Implement `cycle status`

Status: Todo
Suggested Linear milestone: M5 - Observability, Status API, And Console
Suggested issue title: Implement Cycle status command

Goal:

Expose the current Cycle operating state to operators.

Background:

The current Bash `status` reports config path, state path, Linear config, engine
path, and maybe a Symphony status URL. The Elixir version must report the full
Cycle status model.

Decisions:

- Default output is human-readable.
- `--json` returns machine-readable JSON.
- Status is read-only.
- Status should not trigger discovery or scheduling.

Acceptance Criteria:

- `cycle status` works without config file.
- It reports missing Linear auth clearly.
- It reports missing engine clearly.
- It reports registry counts and errors.
- It reports drift summary.
- It reports service/API health if available.
- `cycle status --json` is valid JSON and contains stable keys.

Implementation Notes:

- Use `Cycle.StatusSnapshot`.
- Keep output compact but complete enough for operator triage.

Architecture Review:

- Boundaries affected: CLI, registries, engine health, API health.
- Data flow: read-only state to output.
- Security/privacy: no token output.
- Migration/rollout: can be used during migration beside Symphony.

Simplification Notes:

- Do not start the daemon from status.

Test Plan:

- CLI: no config.
- CLI: missing engine.
- CLI: invalid registry.
- CLI: JSON output.
- Unit: output redaction.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- This command is the main acceptance surface for many earlier TODOs.

### TODO CYCLE-M5-003: Implement localhost API

Status: Todo
Suggested Linear milestone: M5 - Observability, Status API, And Console
Suggested issue title: Expose Cycle status over a local API

Goal:

Expose daemon health and status to local tools and future dashboards.

Background:

Docs call for a local API that reports health, status, projects, engines, runs,
and log pointers.

Decisions:

- Bind to `127.0.0.1:4765` by default.
- Non-local binding requires explicit config.
- First version has read-only endpoints only.
- API uses JSON.

Acceptance Criteria:

- `GET /health` returns status and version.
- `GET /api/v1/status` returns `StatusSnapshot`.
- `GET /api/v1/projects` returns registry projects without secrets.
- `GET /api/v1/engines` returns engine registry and health.
- `GET /api/v1/runs` returns run records.
- `GET /api/v1/runs/:id` returns one run or 404.
- `GET /api/v1/logs` returns log file path/pointers, not full sensitive logs
  by default.

Implementation Notes:

- Implement with Plug and Bandit.
- Keep API modules small and serialization explicit.
- Add config for enabled/bind/port.

Architecture Review:

- Boundaries affected: daemon, API, status, registries.
- Data flow: read-only state to JSON.
- Security/privacy: localhost by default, no secrets in responses.
- Migration/rollout: no external network exposure by default.

Simplification Notes:

- Do not add auth for localhost-only v1. Require auth only if non-local bind is
  introduced later.

Test Plan:

- Unit/integration: each endpoint.
- Unit: non-local bind requires explicit config.
- Unit: no secrets in responses.

Multi-Agent Suggestion:

Can be parallelized with CLI status after StatusSnapshot is merged.

Handoff Notes:

- Future dashboards should consume this API instead of reading registry files
  directly.

### TODO CYCLE-M5-004: Implement logging and event summaries

Status: Todo
Suggested Linear milestone: M5 - Observability, Status API, And Console
Suggested issue title: Add Cycle logs and run event summaries

Goal:

Provide useful logs and last-event summaries without leaking secrets.

Background:

Cycle needs enough observability to debug discovery, workflow validation,
scheduling, engine health, and review judge decisions.

Decisions:

- Log path defaults to `${CYCLE_HOME}/logs/cycle.log`.
- Logs are redacted.
- Run records store last event summary and pointers, not full raw logs.
- CLI status shows log path and important last errors.

Acceptance Criteria:

- Log directory is created safely.
- Discovery errors are logged with project identifiers.
- Engine health failures are logged.
- Scheduler gate decisions can be traced.
- Review judge route failures are logged.
- Secrets are redacted in tests.

Implementation Notes:

- Use Elixir Logger with configured backend/path.
- Add a small redaction helper for tokens, Authorization headers, and token-like
  values.

Architecture Review:

- Boundaries affected: all runtime modules.
- Data flow: events to logs and run summaries.
- Security/privacy: redaction is mandatory.
- Migration/rollout: no service dependency.

Simplification Notes:

- Do not build log streaming in v1.

Test Plan:

- Unit: redaction helper.
- Unit: log path config.
- Unit: run last event update.
- Manual: inspect log output from `cycle start --once --no-dispatch`.

Multi-Agent Suggestion:

Suitable as a parallel hardening task after core modules exist.

Handoff Notes:

- Every external failure should have an operator-actionable message.

## Milestone M6 - Review Judge Policy And Routing

Goal: port review judgement policy into Cycle with conservative evidence,
idempotency, and Linear write safety.

### TODO CYCLE-M6-001: Implement review evidence collection

Status: Todo
Suggested Linear milestone: M6 - Review Judge Policy And Routing
Suggested issue title: Build Cycle review judge evidence collection

Goal:

Collect stable evidence needed to decide whether an issue can move from Human
Review to Merging.

Background:

Adapted Symphony review judge gathers issue details, labels, comments, workpad,
workspace, and git state. Cycle should own this policy while using Symphony
evidence where available.

Decisions:

- Evidence includes issue id, identifier, title, state, labels, comments,
  workpad, run evidence, git changed files, workflow/policy version, and global
  policy version.
- Missing git/run evidence for code-changing issues is a hard human-review
  reason.
- Workpad evidence is useful but missing workpad alone should not crash judge.

Acceptance Criteria:

- Evidence builder fetches Linear comments.
- Evidence builder finds latest `## Codex Workpad` comment when present.
- Evidence builder attaches run evidence from RunStore when present.
- Evidence builder can inspect workspace git state when workspace exists.
- Evidence builder returns structured missing-evidence reasons.
- Evidence excludes volatile timestamps unless meaningful.

Implementation Notes:

- Implement `Cycle.Policy.ReviewEvidence`.
- Port from adapted `review_judge.ex` where useful, but split evidence from
  decision/routing.
- Use safe git args and path checks.

Architecture Review:

- Boundaries affected: Linear client, RunStore, filesystem/git, review judge.
- Data flow: issue/run/workspace/comments to evidence struct.
- Security/privacy: comments may include sensitive content. Persist hashes and
  summaries, not full evidence, unless required.
- Migration/rollout: evidence failure should require human review.

Simplification Notes:

- Do not run model judgement here.

Test Plan:

- Unit: latest workpad detection.
- Unit: no workpad.
- Unit: git changed file extraction.
- Unit: missing workspace.
- Unit: evidence stable hash inputs.

Multi-Agent Suggestion:

Can be parallelized with judge decision parser if evidence struct is agreed.

Handoff Notes:

- Evidence shape becomes part of the idempotency hash.

### TODO CYCLE-M6-002: Implement evidence hash and duplicate judgement skip

Status: Todo
Suggested Linear milestone: M6 - Review Judge Policy And Routing
Suggested issue title: Add review judge evidence hashing and duplicate skip

Goal:

Prevent repeated identical review judge decisions.

Background:

Adapted Symphony computes an evidence hash and includes it in judge comments.
Cycle should preserve that safety behavior.

Decisions:

- Hash stable evidence inputs only.
- Hash includes issue data, labels, relevant comments/workpad, git summary,
  workflow or policy version, judge profile, and global policy version.
- Hash excludes volatile timestamps.
- Duplicate existing judge comment with same hash skips new judgement.

Acceptance Criteria:

- Same evidence produces same hash.
- Meaningful evidence change produces different hash.
- Existing comment with same hash skips model call and Linear writes.
- Hash is included in new judge comments.

Implementation Notes:

- Implement `Cycle.Policy.EvidenceHash`.
- Use SHA-256.
- Keep canonical JSON encoding for hash input.

Architecture Review:

- Boundaries affected: review judge, Linear comments.
- Data flow: evidence to hash to comment.
- Security/privacy: hash input may contain sensitive text but hash output does
  not. Do not log raw hash input.
- Migration/rollout: idempotent reruns are safe.

Simplification Notes:

- Do not implement decision logic here.

Test Plan:

- Unit: stable hash.
- Unit: changed label changes hash.
- Unit: timestamp ignored.
- Unit: duplicate comment detection.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Document hash comment marker format in test fixtures.

### TODO CYCLE-M6-003: Implement review judge decision model and hard stops

Status: Todo
Suggested Linear milestone: M6 - Review Judge Policy And Routing
Suggested issue title: Implement Cycle review judge decisions and hard stops

Goal:

Decide whether an issue should remain in Human Review or proceed to Merging.

Background:

Cycle must optimize for human review value, not generic code perfection, while
conservatively handling risky surfaces and weak evidence.

Decisions:

- Allowed decisions are `proceed_to_merging` and `require_human_review`.
- Unknown or malformed model output is `require_human_review`.
- Confidence order is `low < medium < high`.
- `proceed_to_merging` requires confidence at or above configured minimum.
- Hard stops override model output.
- Hard stops include configured paths/labels, missing validation evidence,
  unavailable git evidence for code changes, workflow/security/data/public API
  surfaces, and judge failure.

Acceptance Criteria:

- Hard path stop returns `require_human_review`.
- Hard label stop returns `require_human_review`.
- Missing validation evidence returns `require_human_review`.
- Malformed model output returns `require_human_review`.
- Low confidence below threshold returns `require_human_review`.
- Valid proceed output at threshold returns `proceed_to_merging`.

Implementation Notes:

- Implement `Cycle.Policy.ReviewJudge`.
- Keep model runner behind a behavior so tests do not call external models.
- Include policy profile and model config in decision provenance.

Architecture Review:

- Boundaries affected: review judge policy, model runner, config.
- Data flow: evidence plus policy to decision.
- Security/privacy: prompts may include issue/comment evidence. Do not log full
  prompts by default.
- Migration/rollout: conservative fallback is human review.

Simplification Notes:

- Do not implement Linear writes here. Return decisions only.

Test Plan:

- Unit: every hard stop.
- Unit: malformed output.
- Unit: confidence ordering.
- Unit: successful proceed.
- Unit: model failure.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Keep prompt text in one module and snapshot-test core policy wording.

### TODO CYCLE-M6-004: Implement review judge Linear write safety and routing

Status: Todo
Suggested Linear milestone: M6 - Review Judge Policy And Routing
Suggested issue title: Safely post and route Cycle review judge decisions in Linear

Goal:

Write review judge decisions to Linear and move issues only when state is still
safe.

Background:

Stale judge results must not move an issue after it has left the source state.

Decisions:

- Before any write, refresh issue by Linear id.
- Confirm issue is still in `source_state`.
- Confirm project is still enabled.
- Confirm no newer judge comment with same evidence hash exists.
- Post decision comment first.
- Move state only for allowed `proceed_to_merging` decisions.

Acceptance Criteria:

- Stale issue state skips comment and state update.
- Disabled project skips writes.
- Duplicate hash skips writes.
- Human review decision posts comment and leaves/moves issue to review state.
- Proceed decision posts comment and moves to proceed state.
- Write failures are visible in status and logs.

Implementation Notes:

- Implement `Cycle.Policy.ReviewRouter`.
- Use `Cycle.Linear.Client` write methods.
- Keep comments structured and concise.

Architecture Review:

- Boundaries affected: Linear writes, review judge, status.
- Data flow: decision to Linear comment and optional state mutation.
- Security/privacy: comment should include evidence summary, not secrets.
- Migration/rollout: safe idempotency required before enabling by default.

Simplification Notes:

- Do not auto-merge PRs. Moving to Merging is the limit.

Test Plan:

- Unit: stale state skip.
- Unit: duplicate skip.
- Unit: disabled project skip.
- Unit: comment then move order.
- Unit: move failure after comment.

Multi-Agent Suggestion:

Single implementer recommended because write safety is critical.

Handoff Notes:

- Review judge should remain disabled by default until this is tested.

### TODO CYCLE-M6-005: Surface review judge status

Status: Todo
Suggested Linear milestone: M6 - Review Judge Policy And Routing
Suggested issue title: Add review judge visibility to Cycle status

Goal:

Make review queue, decisions, duplicates, hard stops, and route failures visible.

Background:

Operators need to trust why issues did or did not move from Human Review to
Merging.

Decisions:

- Review judge status is part of `StatusSnapshot`.
- Status includes issue counts and last decision summaries.
- Status includes hard human-review reasons.
- Status includes drift in judge policy.

Acceptance Criteria:

- `cycle status` shows review source queue count.
- It shows active judge task count.
- It shows last decision per recently judged issue.
- It shows duplicate judgement skips.
- It shows route write failures.
- JSON status includes machine-readable judge records.

Implementation Notes:

- Add review records or summaries to RunStore or a small judge registry if
  needed.
- Do not store full prompt/evidence by default.

Architecture Review:

- Boundaries affected: review judge, status, persistence.
- Data flow: judge results to status snapshot.
- Security/privacy: summarize, do not leak raw evidence.
- Migration/rollout: observability before default enablement.

Simplification Notes:

- Do not build a dashboard UI yet.

Test Plan:

- Unit: status with no judge.
- Unit: active judge.
- Unit: last decision.
- Unit: route failure.

Multi-Agent Suggestion:

Can be parallelized after ReviewRouter exists.

Handoff Notes:

- This should be included before turning review judge on in operator config.

## Milestone M7 - Service Lifecycle And Migration Safety

Goal: install and inspect Cycle as a service without disturbing existing
Symphony deployments.

### TODO CYCLE-M7-001: Add service templates for launchd and systemd

Status: Todo
Suggested Linear milestone: M7 - Service Lifecycle And Migration Safety
Suggested issue title: Add Cycle launchd and systemd service templates

Goal:

Provide platform service templates filled at install time.

Background:

Cycle should support macOS Homebrew with launchd and Linux with systemd.

Decisions:

- Templates live in the repo.
- Install fills executable path, config path, state path, log path, and env
  file path.
- Templates do not embed secrets.
- Templates do not start service by themselves.

Acceptance Criteria:

- launchd plist template exists.
- systemd unit template exists.
- Template rendering validates required fields.
- Rendered templates contain no placeholder tokens.
- Rendered templates contain no secret values.

Implementation Notes:

- Implement `Cycle.Service.Template`.
- Keep templates simple and readable.

Architecture Review:

- Boundaries affected: service install, release packaging.
- Data flow: config paths to rendered service file.
- Security/privacy: no secrets in templates.
- Migration/rollout: install remains explicit.

Simplification Notes:

- Do not support Windows service in v1.

Test Plan:

- Unit: render launchd.
- Unit: render systemd.
- Unit: missing field error.
- Unit: secret not present.

Multi-Agent Suggestion:

Can be parallelized with service status after config interfaces are stable.

Handoff Notes:

- Human review required for service template changes.

### TODO CYCLE-M7-002: Implement conservative `cycle service install`

Status: Todo
Suggested Linear milestone: M7 - Service Lifecycle And Migration Safety
Suggested issue title: Install Cycle service only after explicit operator setup

Goal:

Install the Cycle daemon service safely and explicitly.

Background:

Service install is a high-risk operator action. It must not overwrite unrelated
files or start work before config is valid.

Decisions:

- `cycle service install --dry-run` shows planned paths and rendered service.
- Without `--yes`, install asks for confirmation in interactive shells.
- Non-interactive install requires `--yes`.
- Install refuses to overwrite unrelated existing service files.
- Install verifies config, Linear auth, default engine, and policy mode.
- Install does not stop existing Symphony services.

Acceptance Criteria:

- Dry-run writes no files.
- Missing auth fails clearly.
- Missing engine fails clearly with install guidance.
- Invalid policy fails clearly.
- Existing unrelated service file is not overwritten.
- Successful install writes service file to expected platform path.
- Service is enabled/loaded only when confirmed or `--yes`.

Implementation Notes:

- Implement `Cycle.Service.Install`.
- Platform detection should be explicit and testable.
- Commands requiring system paths may need operator permissions; surface that
  cleanly.

Architecture Review:

- Boundaries affected: OS service manager, filesystem, config, engine health.
- Data flow: config to rendered service file to OS.
- Security/privacy: no secrets in service file.
- Migration/rollout: does not touch existing Symphony service.

Simplification Notes:

- Do not implement service uninstall in this issue.

Test Plan:

- Unit: dry-run.
- Unit: missing auth.
- Unit: missing engine.
- Unit: invalid policy.
- Unit: overwrite refusal.
- Integration/manual: install on Linux systemd test host.

Multi-Agent Suggestion:

Single implementer recommended due to platform safety.

Handoff Notes:

- Human review required before merging.

### TODO CYCLE-M7-003: Implement read-only `cycle service status`

Status: Todo
Suggested Linear milestone: M7 - Service Lifecycle And Migration Safety
Suggested issue title: Report Cycle service status without side effects

Goal:

Report installed/running/failed service state without starting or stopping
anything.

Background:

Operators need to check service state safely. Status must be read-only.

Decisions:

- `service status` never starts, stops, enables, disables, reloads, or restarts
  services.
- It reports service file path, active state, process id, config path, state
  path, logs, API health, engine health, and drift summary.
- JSON output is supported.

Acceptance Criteria:

- Missing service reports missing.
- Installed inactive service reports inactive.
- Running service reports pid if available.
- Failed service reports failed and log pointer.
- Command is read-only in tests.
- `--json` emits stable keys.

Implementation Notes:

- Implement `Cycle.Service.Status`.
- Shell out to `systemctl` or `launchctl` only for status/read operations.
- If platform status command is unavailable, report unknown with guidance.

Architecture Review:

- Boundaries affected: OS service manager, status snapshot.
- Data flow: service manager status to CLI output.
- Security/privacy: logs are pointers, not raw secrets.
- Migration/rollout: safe beside Symphony.

Simplification Notes:

- Do not parse every platform-specific field. Report clear basics first.

Test Plan:

- Unit: missing service fixture.
- Unit: active service fixture.
- Unit: failed service fixture.
- Unit: command list contains no mutating verbs.

Multi-Agent Suggestion:

Can be parallelized with service templates.

Handoff Notes:

- Keep this safe enough to run in production troubleshooting.

### TODO CYCLE-M7-004: Document and implement safe migration from existing Symphony service

Status: Todo
Suggested Linear milestone: M7 - Service Lifecycle And Migration Safety
Suggested issue title: Add safe migration path from existing Symphony services

Goal:

Let operators compare Cycle with existing Symphony before switching.

Background:

Docs require Cycle to run beside existing Symphony until the operator explicitly
switches.

Decisions:

- Migration path is documented and command-supported.
- Cycle can run `start --once --no-dispatch` to inspect projects and drift.
- Cycle can compare its project/runs view with an existing Symphony status URL
  when configured.
- Cycle never stops old service automatically.

Acceptance Criteria:

- Migration guide exists.
- `cycle doctor` reports existing Symphony service hints without mutating them.
- `cycle start --once --no-dispatch` is documented as safe preflight.
- `cycle status` can show configured external Symphony status URL if present.
- Explicit operator steps are listed for final cutover.

Implementation Notes:

- Add docs and small CLI/status support.
- Existing service detection should be best-effort and read-only.

Architecture Review:

- Boundaries affected: docs, doctor, status, service status.
- Data flow: read-only system state and configured URLs to status.
- Security/privacy: no secrets.
- Migration/rollout: primary purpose.

Simplification Notes:

- Do not implement automatic cutover.

Test Plan:

- Unit: doctor output with fake service detection.
- Manual: follow migration guide on a host with existing Symphony service.

Multi-Agent Suggestion:

Suitable for docs plus CLI split if service status interfaces exist.

Handoff Notes:

- Human review recommended because migration mistakes affect live automation.

## Milestone M8 - Release, Homebrew, And Operator Documentation

Goal: ship Cycle through a versioned release artifact and Homebrew without
starting services or leaking machine-local assumptions.

### TODO CYCLE-M8-001: Implement release artifact build

Status: Todo
Suggested Linear milestone: M8 - Release, Homebrew, And Operator Documentation
Suggested issue title: Build versioned Cycle release artifacts

Goal:

Produce a release archive suitable for Homebrew.

Background:

The draft formula currently contains placeholders. The release flow needs a
real archive, checksum, and validation path.

Decisions:

- Release archive includes executable `bin/cycle`, README, docs, license, and
  service templates.
- Release archive excludes secrets, local config, logs, caches, engine
  checkouts, and build scratch.
- Versioning uses semantic tags like `v0.1.0`.

Acceptance Criteria:

- Build command creates versioned tarball.
- Tarball includes required files.
- Tarball excludes ignored/local files.
- SHA-256 checksum is computed.
- Built artifact can run `cycle --version`.

Implementation Notes:

- Add `mix release.artifact` alias or script if helpful.
- Keep generated archives under `dist/`, ignored by git.

Architecture Review:

- Boundaries affected: build system, packaging, docs.
- Data flow: source tree to release archive.
- Security/privacy: archive hygiene.
- Migration/rollout: required before Homebrew update.

Simplification Notes:

- Do not publish GitHub releases in this issue unless release credentials are
  already available.

Test Plan:

- Build artifact.
- Inspect tarball file list.
- Run packaged `cycle --version`.
- Run packaged smoke checks.

Multi-Agent Suggestion:

Single implementer recommended.

Handoff Notes:

- Human review required for release scripts.

### TODO CYCLE-M8-002: Finalize Homebrew formula

Status: Todo
Suggested Linear milestone: M8 - Release, Homebrew, And Operator Documentation
Suggested issue title: Finalize Homebrew formula for Cycle

Goal:

Turn `packaging/homebrew/cycle.rb` into a production-ready formula template and
document the tap update.

Background:

The production formula belongs in the tap repo at `Formula/cycle.rb`.

Decisions:

- Formula points at a versioned release artifact.
- Formula verifies `sha256`.
- Formula installs Cycle CLI and docs.
- Formula depends on required runtime tools.
- Formula does not install or start services.
- Formula does not embed secrets or local paths.

Acceptance Criteria:

- Placeholder homepage/url/sha values are replaced only when release artifact
  exists.
- Formula install path matches release archive layout.
- Formula test runs `cycle --version` and `cycle doctor` or a safe subset.
- Docs explain tap update as a separate commit.

Implementation Notes:

- Decide runtime dependencies after escript packaging is proven.
- If the escript requires Erlang/Elixir runtime, formula must declare it.

Architecture Review:

- Boundaries affected: packaging, release, public install.
- Data flow: release artifact to Homebrew install.
- Security/privacy: no secrets.
- Migration/rollout: service remains explicit.

Simplification Notes:

- Do not add service auto-start to formula.

Test Plan:

- `brew install aeaston1/tap/cycle` on a clean test machine or container.
- `cycle --version`.
- `cycle doctor`.
- Formula audit if available.

Multi-Agent Suggestion:

Suitable for a release-focused agent after artifact exists.

Handoff Notes:

- Human review required.

### TODO CYCLE-M8-003: Update operator documentation

Status: Todo
Suggested Linear milestone: M8 - Release, Homebrew, And Operator Documentation
Suggested issue title: Write Cycle operator documentation for first release

Goal:

Give operators a complete path from install to safe foreground run and service
install.

Background:

The docs currently describe target architecture. First release needs concrete,
validated operator instructions.

Decisions:

- Docs include install, first run, config, project onboarding, policy drift,
  engine install, foreground start, service install, status, troubleshooting,
  and migration.
- Docs distinguish implemented behavior from roadmap behavior.
- Docs use public-safe placeholders.

Acceptance Criteria:

- README first-run path works.
- Config docs match implemented config.
- Metadata docs match parser behavior.
- Service docs match actual safety behavior.
- Release docs match artifact and formula behavior.
- Troubleshooting includes missing auth, missing engine, invalid metadata,
  invalid workflow, drift, and dispatch unsupported.

Implementation Notes:

- Avoid duplicating large command references in many files.
- Link to focused docs.

Architecture Review:

- Boundaries affected: docs and operator UX.
- Data flow: none.
- Security/privacy: examples are placeholder-only.
- Migration/rollout: docs should make safe migration explicit.

Simplification Notes:

- Do not document future commands as available unless they exist.

Test Plan:

- Manual: follow docs on a clean checkout.
- Manual: verify every command example.
- `rg` for private repo names/local paths/secrets.

Multi-Agent Suggestion:

Suitable as a docs agent task after implementation stabilizes.

Handoff Notes:

- Docs-only PR still needs smoke validation for command examples.

### TODO CYCLE-M8-004: Add release validation checklist

Status: Todo
Suggested Linear milestone: M8 - Release, Homebrew, And Operator Documentation
Suggested issue title: Add release validation checklist for Cycle

Goal:

Make releases repeatable and safe.

Background:

Release flow involves tests, artifacts, checksums, tap updates, Homebrew install,
and engine pinning.

Decisions:

- Release checklist lives in docs and optionally a script.
- Checklist requires clean working tree.
- Checklist requires tests and smoke checks.
- Checklist separates Cycle version from Symphony engine lock.

Acceptance Criteria:

- Checklist covers preflight, tests, artifact, checksum, publish, tap update,
  install test, doctor, rollback.
- Commands are exact where possible.
- Rollback path is documented.
- Engine lock separation is explicit.

Implementation Notes:

- Add `scripts/release-check` only if helpful and non-mutating by default.

Architecture Review:

- Boundaries affected: release process.
- Data flow: source to artifact to tap.
- Security/privacy: no secret handling in release artifact.
- Migration/rollout: supports public distribution.

Simplification Notes:

- Do not automate publishing until manual release is proven.

Test Plan:

- Dry-run the checklist.
- Validate archive and formula on test host.

Multi-Agent Suggestion:

Suitable for release/docs agent.

Handoff Notes:

- Human review required for release changes.

## Milestone M9 - Hardening, Scale, And Future Extensions

Goal: strengthen Cycle after the main control plane works, without expanding
scope prematurely.

### TODO CYCLE-M9-001: Add explicit security and secret hygiene tests

Status: Todo
Suggested Linear milestone: M9 - Hardening, Scale, And Future Extensions
Suggested issue title: Harden Cycle secret handling and public repo hygiene

Goal:

Prove Cycle does not leak secrets through config, logs, registries, docs, or
release artifacts.

Background:

Cycle handles Linear auth and may pass environment into engine processes.

Decisions:

- Tokens are redacted in all CLI, logs, API, errors, and tests.
- Registry files never persist token values.
- Release artifacts exclude local config and state.
- Service files do not embed secrets.

Acceptance Criteria:

- Test suite includes redaction cases.
- Artifact validation scans for known fake token values and fails if present.
- Logs redact Authorization headers.
- API responses do not include token values.
- Docs/examples contain no private repo names except allowed Homebrew tap.

Implementation Notes:

- Add fake high-entropy tokens to tests to prove scans work.
- Keep scanner deterministic and not network-dependent.

Architecture Review:

- Boundaries affected: all output and packaging surfaces.
- Data flow: secrets through config to redacted display.
- Security/privacy: primary focus.
- Migration/rollout: release blocker.

Simplification Notes:

- Do not add a general-purpose DLP engine.

Test Plan:

- Unit: redaction helper.
- Integration: CLI output scan.
- Integration: log scan.
- Integration: release artifact scan.

Multi-Agent Suggestion:

Suitable for a security-focused parallel agent after output surfaces exist.

Handoff Notes:

- Treat failures as release blockers.

### TODO CYCLE-M9-002: Add rate-limit and budget pressure gates

Status: Todo
Suggested Linear milestone: M9 - Hardening, Scale, And Future Extensions
Suggested issue title: Add scheduler gates for rate-limit and budget pressure

Goal:

Prevent Cycle from overscheduling when external API limits, token pressure, or
operator budget limits are high.

Background:

Docs mention token, rate-limit, and budget pressure. First public version may
warn only, but full implementation should expose gates.

Decisions:

- Budget mode supports `off`, `warn`, and `block`.
- Rate-limit pressure can delay new dispatch but should not kill running work.
- Status reports budget/rate reasons.

Acceptance Criteria:

- Scheduler reads budget/rate config.
- Warn mode reports pressure without blocking.
- Block mode prevents new dispatch with reason.
- Running work is not stopped solely due to new pressure.
- Status shows pressure state.

Implementation Notes:

- Start with configured static limits and observed Linear/engine rate-limit
  headers where available.
- Do not invent billing integration before requirements exist.

Architecture Review:

- Boundaries affected: scheduler, status, Linear client, engine adapter.
- Data flow: observed/configured pressure to scheduler gate.
- Security/privacy: no billing secrets in v1.
- Migration/rollout: default should not surprise operators.

Simplification Notes:

- Keep advanced weighted scheduling out of scope.

Test Plan:

- Unit: warn mode.
- Unit: block mode.
- Unit: running run unaffected.
- Unit: status reason.

Multi-Agent Suggestion:

Suitable after scheduler core exists.

Handoff Notes:

- This can be deferred if v1 needs to ship earlier.

### TODO CYCLE-M9-003: Add optional workflow policy propagation

Status: Todo
Suggested Linear milestone: M9 - Hardening, Scale, And Future Extensions
Suggested issue title: Prepare explicit workflow policy propagation

Goal:

Let operators prepare narrow workflow updates for projects with policy drift.

Background:

Cycle should report drift first. Propagation is manual and must never silently
rewrite workflows during discovery.

Decisions:

- Propagation requires explicit command.
- First implementation supports dry-run patch generation.
- Applying changes, branch creation, commit, or PR requires explicit flags and
  confirmation.
- Propagation edits only relevant workflow settings.

Acceptance Criteria:

- `cycle policy drift` lists drift by project.
- `cycle policy propagate --project PROJECT --dry-run` prints proposed patch.
- No files are changed in dry-run.
- Apply mode refuses dirty worktrees unless explicitly allowed.
- Generated patch is narrow and public-safe.

Implementation Notes:

- Build on drift records from CYCLE-M2-005.
- Use structured YAML editing where possible.
- If preserving comments is hard, document limitation and keep dry-run first.

Architecture Review:

- Boundaries affected: project repos, git, workflow files, policy.
- Data flow: drift record to patch.
- Security/privacy: no secrets.
- Migration/rollout: high human-review surface.

Simplification Notes:

- Do not auto-push PRs in first propagation issue.

Test Plan:

- Unit: patch for missing review judge setting.
- Unit: patch for capacity setting.
- Unit: dry-run no mutation.
- Integration: temp git repo dirty worktree refusal.

Multi-Agent Suggestion:

Single implementer recommended due to mutation risk.

Handoff Notes:

- Human review required before merge.

### TODO CYCLE-M9-004: Define public Cycle skill pack shape without auto-install

Status: Todo
Suggested Linear milestone: M9 - Hardening, Scale, And Future Extensions
Suggested issue title: Specify optional Cycle Codex skill pack

Goal:

Document and optionally scaffold Cycle-specific Codex skills without making
them part of default install.

Background:

Supporting skills are useful for operators but should not be silently installed
by Homebrew.

Decisions:

- Homebrew installs CLI only.
- Skills require explicit operator command or manual install.
- Candidate skills: `cycle-debug`, `cycle-linear`, `cycle-release`,
  `cycle-judge-review`, `cycle-project-onboarding`.

Acceptance Criteria:

- Docs explain skill policy.
- Optional commands are roadmap-only unless implemented.
- No install path writes to `~/.codex` without explicit confirmation.
- Existing machine-local skills are not redistributed as-is.

Implementation Notes:

- Keep this docs-first unless user asks to build skill installer.

Architecture Review:

- Boundaries affected: docs, optional operator tooling.
- Data flow: none for v1.
- Security/privacy: avoid mutating agent behavior silently.
- Migration/rollout: optional only.

Simplification Notes:

- Do not block core Cycle release on skills.

Test Plan:

- Manual docs review.
- `rg` for auto-install language.

Multi-Agent Suggestion:

Suitable for docs agent.

Handoff Notes:

- This can become its own future milestone after v1.

### TODO CYCLE-M9-005: Define future dashboard and multi-engine protocol roadmap

Status: Todo
Suggested Linear milestone: M9 - Hardening, Scale, And Future Extensions
Suggested issue title: Document future dashboard and explicit engine protocol roadmap

Goal:

Capture the next architecture steps without blocking v1.

Background:

Cycle's long-term shape includes richer observability and explicit run/status
contracts across multiple Symphony versions or engines.

Decisions:

- V1 uses CLI plus localhost API, not a web dashboard.
- Future dashboard consumes the local API.
- Future single-run engine protocol should be explicit and versioned.
- Cycle must not depend on Symphony internals staying stable.

Acceptance Criteria:

- Roadmap doc identifies dashboard scope, API gaps, engine protocol gaps, and
  migration strategy.
- Roadmap separates v1 commitments from future exploration.
- It names what upstream Symphony would need to expose for better dispatch.

Implementation Notes:

- Keep roadmap concise and linked from architecture docs.

Architecture Review:

- Boundaries affected: future API, engine adapter, dashboard.
- Data flow: API to future UI, run request to engine.
- Security/privacy: future non-local API needs auth.
- Migration/rollout: future planning only.

Simplification Notes:

- Do not implement dashboard in this issue.

Test Plan:

- Docs review only.

Multi-Agent Suggestion:

Single docs/planning agent suitable.

Handoff Notes:

- Useful after v1 architecture has been validated in practice.

## Cross-Cutting Acceptance Criteria

Cycle is not complete until these are true:

- `mise exec -- mix test` passes.
- `tests/smoke.sh` passes.
- `./bin/cycle --version` works.
- `./bin/cycle help` lists implemented commands accurately.
- `./bin/cycle doctor` reports prerequisites and redacts secrets.
- `./bin/cycle project opt-in --repo https://github.com/OWNER/REPO.git`
  prints valid `cycle:` metadata.
- `./bin/cycle project discover --limit 5` works with real Linear auth.
- `./bin/cycle status` works without a running daemon.
- `./bin/cycle status --json` emits valid JSON.
- `./bin/cycle start --once --no-dispatch` runs a safe preflight cycle.
- Invalid project metadata appears in status without blocking other projects.
- Invalid workflow blocks only that project.
- Drift is visible in report mode and blocks only in block mode.
- Engine health is visible and scheduler respects it.
- Review judge never routes stale Linear state.
- Service status is read-only.
- Service install requires explicit setup and does not touch existing Symphony
  services.
- Release archive excludes local state, logs, secrets, and engine checkouts.
- Homebrew formula does not install or start services.

## Suggested Implementation Order

1. CYCLE-M0-001
2. CYCLE-M0-002
3. CYCLE-M0-003
4. CYCLE-M1-001
5. CYCLE-M1-002
6. CYCLE-M1-003
7. CYCLE-M1-004
8. CYCLE-M2-001
9. CYCLE-M2-002
10. CYCLE-M2-003
11. CYCLE-M2-004
12. CYCLE-M2-005
13. CYCLE-M3-001
14. CYCLE-M3-002
15. CYCLE-M3-003
16. CYCLE-M3-004
17. CYCLE-M4-001
18. CYCLE-M4-003
19. CYCLE-M4-002
20. CYCLE-M4-004
21. CYCLE-M4-005
22. CYCLE-M5-001
23. CYCLE-M5-002
24. CYCLE-M5-003
25. CYCLE-M5-004
26. CYCLE-M6-001
27. CYCLE-M6-002
28. CYCLE-M6-003
29. CYCLE-M6-004
30. CYCLE-M6-005
31. CYCLE-M7-001
32. CYCLE-M7-003
33. CYCLE-M7-002
34. CYCLE-M7-004
35. CYCLE-M8-001
36. CYCLE-M8-002
37. CYCLE-M8-003
38. CYCLE-M8-004
39. CYCLE-M9-001
40. CYCLE-M9-002
41. CYCLE-M9-003
42. CYCLE-M9-004
43. CYCLE-M9-005

## Multi-Agent Execution Guidance

Use a single implementer for early M0 and M1 foundation work. The app skeleton,
CLI, config, registry, and parser boundaries will otherwise conflict.

Parallelization becomes useful after M1:

- Agent A: Linear client and project discovery.
- Agent B: workflow resolver and workflow policy parser.
- Agent C: engine registry and install/health behavior.
- Agent D: status snapshot and CLI status.

Do not parallelize scheduler gates, RunStore transitions, and reconciler
integration until their interfaces are settled. They interact tightly.

Do not parallelize review judge Linear writes with review evidence/hash work
unless the evidence and decision structs are already merged.

Service install, release packaging, and policy propagation require human review
because they touch infrastructure, installation, or repo mutation behavior.

## Risks And Mitigations

- Risk: Cycle accidentally becomes a Symphony fork.
  Mitigation: keep Codex app-server, prompt building, and run internals inside
  Symphony; Cycle owns control-plane decisions and adapter boundary only.

- Risk: upstream Symphony lacks a stable single-run protocol.
  Mitigation: capability-gate dispatch, expose unsupported dispatch in status,
  and run current engine supervision mode until a protocol exists.

- Risk: local state leaks secrets.
  Mitigation: registry schemas exclude secrets, redaction tests scan CLI/API/log
  output, and release artifacts are scanned.

- Risk: workflow propagation mutates repos unexpectedly.
  Mitigation: discovery is read-only, propagation is a separate explicit command
  with dry-run first and human review.

- Risk: service install disrupts existing Symphony automation.
  Mitigation: install is explicit, status is read-only, migration docs require
  side-by-side validation, and Cycle never stops old services automatically.

- Risk: Linear schema or API behavior changes.
  Mitigation: isolate GraphQL in `Cycle.Linear.Client`, use fixtures, surface
  GraphQL errors clearly, and keep query shapes narrow.

- Risk: registry YAML becomes brittle under concurrent writes.
  Mitigation: use one daemon writer, atomic writes, and schema validation.
  Add locks only if real concurrent writes appear.

- Risk: too much status data overwhelms operators.
  Mitigation: keep CLI concise, provide JSON for full detail, and use stable
  reason codes.

## Future Linear Conversion Notes

When converting this PRD into Linear:

- Use the Suggested Linear Milestones exactly as initial milestone names.
- Convert each `TODO CYCLE-*` heading into one Linear issue unless a TODO is
  intentionally split during grooming.
- Use each TODO's suggested issue title as the Linear issue title.
- Copy Goal, Background, Decisions, Acceptance Criteria, Implementation Notes,
  Architecture Review, Simplification Notes, Test Plan, Multi-Agent Suggestion,
  and Handoff Notes into the issue body.
- Keep M0 and M1 mostly serial.
- Mark service, release, propagation, and security issues with labels such as
  `infrastructure`, `release`, `security`, or `service` when available.
- For Symphony/Codex automation, require the same persistent workpad discipline
  used in this repo's `WORKFLOW.md`.
