# Cycle

Cycle is a Linear-native control plane for running OpenAI Symphony across many repositories, with policy, review judgement, capacity management, and observability built in.

Cycle does not replace Symphony. Symphony remains the engine for an isolated coding-agent workflow. Cycle manages discovery, installation, orchestration policy, and operator UX around one or more Symphony engines.

## Current State

This repository is currently a lightweight Cycle CLI scaffold. It can:

- check local prerequisites with `cycle doctor`
- configure or validate Linear API access
- install or locate a managed upstream Symphony checkout
- print Linear project opt-in metadata
- discover opted-in Linear projects through the Linear API
- report local Cycle state and a reachable Symphony status endpoint
- document the Homebrew packaging path

The broader working implementation currently lives in the adapted Symphony checkout. That implementation already proves the core Cycle behaviors:

- multi-project Linear discovery through `tracker.project_discovery.mode: opt_in_descriptions`
- repo-owned workflow policy from each project's root `WORKFLOW.md`
- per-project workspace cloning and workflow validation
- global, per-project, and per-state concurrency controls
- Linear dependency gating for unresolved blockers
- review judge routing from `Human Review` to `Merging`
- review judge safety through evidence hashes and stale-state checks
- dashboard visibility for per-project capacity and workflow errors

So when this repo says a feature is "missing", that means it is missing from the new Cycle repo scaffold, not necessarily missing from the working adapted Symphony implementation.

## Current Modified Symphony Model

The modified Symphony implementation currently proves the multi-project model Cycle should spin out.

It runs as one Symphony service instance with one discovery workflow. That workflow polls Linear on an interval and uses the Linear API token's visible workspace. In discovery mode, it is project-first:

1. List Linear projects.
2. Parse each project description/content for opt-in metadata.
3. Keep only opted-in projects with `enabled: true` and a valid GitHub repo URL.
4. Fetch issues in target states for each opted-in project.
5. Attach project and repo metadata to each issue.
6. Resolve the target repo's root `WORKFLOW.md`.
7. Create a per-issue workspace by cloning that repo.
8. Dispatch a Codex-backed agent run only after dependency, capacity, and workflow checks pass.

That means the current implementation is not one long-running Symphony process per Linear project. It is one orchestrator polling opted-in projects, then spawning per-issue agent tasks with project metadata attached.

The assumptions Cycle should preserve:

- Linear discovery should be opt-in by project metadata.
- Each repo should own its workflow policy in root `WORKFLOW.md`.
- Issue execution should happen in isolated repo-scoped workspaces.
- Project-specific capacity should come from the repo-owned workflow.
- Unresolved Linear blockers should prevent dispatch or stop active work.
- Review judge routing should use the same project discovery boundary.

The assumptions Cycle should improve:

- Require `cycle:` metadata for Cycle project opt-in.
- Make the discovered project registry durable and inspectable.
- Move scheduling and judge policy into Cycle-owned modules.
- Make global policy, validation, drift reporting, and optional propagation Cycle-owned concerns.
- Add an engine registry so Cycle can choose and pin one or more upstream Symphony versions.
- Keep upstream OpenAI Symphony as an engine, not the public product identity.

## Target Shape

Cycle should be packaged as the control plane above Symphony, not as a rename or fork of Symphony.

The clean product model:

- Cycle Project Registry: discovers Linear projects, reads `cycle:` metadata, and stores repo URL, workflow path, allowed engines, and policy.
- Cycle Engine Registry: tracks Symphony versions/runners, supported workflow schema, Codex defaults, worker pools, sandbox mode, and health.
- Cycle Scheduler: assigns issues across projects and engines with global, per-project, per-state, per-engine, and budget caps.
- Cycle Policy Layer: owns review judge policy, hard-review paths, labels, confidence gates, rejudge/versioning, and merge-lane rules.
- Cycle Drift Layer: validates discovered project workflows against global policy, reports drift from desired fleet settings, and optionally prepares or applies repo workflow updates when the operator asks.
- Cycle Console/API: reports watched projects, active runs, blocked issues, Human Review, Merging, PRs, token/rate-limit pressure, and engine health.

## Spinout Boundary

Cycle owns the control plane:

- Linear project discovery across many opted-in projects
- `cycle:` metadata parsing
- project-to-repo registry
- repo-owned `WORKFLOW.md` lookup
- global policy defaults, validation, drift reporting, and optional propagation
- global, per-project, per-state, per-engine, and budget-aware scheduling
- Linear dependency gating
- review judge policy and routing
- dashboard/status across all watched projects
- engine registry and version lock
- installing and pinning upstream OpenAI Symphony
- service lifecycle and operator CLI

Symphony stays the execution engine:

- receive one issue, one repo/workspace, and one workflow
- run the isolated coding-agent lifecycle
- expose execution state, evidence, and logs for Cycle to judge, schedule, and report

## CLI

The scaffold exposes the full intended command surface, but commands are only considered product-ready once backed by real Cycle-owned behavior.

Working or partially backed now:

```sh
cycle doctor
cycle linear configure
cycle symphony install
cycle symphony path
cycle project opt-in --repo <git-repository-url>
cycle project discover
cycle status
```

Included but intentionally conservative until service management is implemented:

```sh
cycle service install
cycle service status
cycle start --workflow <path-to-WORKFLOW.md>
```

`cycle start` runs a managed Symphony engine in the foreground. It does not install a service. Service commands currently explain the planned backing behavior.

## Install

The intended distribution path is a Homebrew tap:

```sh
brew install aeaston1/tap/cycle
```

For local development from this repository:

```sh
./bin/cycle --version
./bin/cycle doctor
```

## First Run

```sh
cycle doctor
cycle linear configure --from-env
cycle symphony install
cycle symphony path
cycle project opt-in --repo <git-repository-url>
cycle project discover
cycle status
```

`cycle symphony install` clones the standard OpenAI Symphony repository into Cycle's local engine directory. It does not modify existing project checkouts.

Default paths:

- config: `${XDG_CONFIG_HOME:-~/.config}/cycle`
- state: `${CYCLE_HOME:-~/.local/share/cycle}`
- engines: `${CYCLE_HOME}/engines/openai-symphony/<ref>`

## Homebrew

A draft formula lives in `packaging/homebrew/cycle.rb`. The production formula should live in the Homebrew tap repository under `Formula/cycle.rb` and point at a versioned release artifact from this repo.

## Documentation

- `docs/architecture.md`: product architecture and current adapted Symphony model.
- `docs/config.md`: concrete daemon/CLI config shape and precedence.
- `docs/engine-protocol.md`: Cycle-to-Symphony engine boundary and run contract.
- `docs/porting-map.md`: map from adapted Symphony source files to Cycle modules.
- `docs/metadata-spec.md`: Linear project `cycle:` metadata schema.
- `docs/workflow-contract.md`: repo-owned `WORKFLOW.md` contract between Cycle and Symphony.
- `docs/scheduler-design.md`: dispatch gates, capacity layers, engine selection, retries, and status.
- `docs/review-judge-policy.md`: judge evidence, policy, idempotency, and Linear write safety.
- `docs/service-model.md`: foreground start, daemon install/status, paths, and migration safety.
- `docs/release.md`: release artifacts, Homebrew tap flow, and validation.
- `docs/supporting-skills.md`: local Symphony/Cycle skill inventory and install policy.

Additional repo files:

- `LICENSE`: MIT license for public use.
- `AGENTS.md`: contributor and agent guidance for Cycle work.
- `WORKFLOW.md`: Cycle's own repo workflow for dogfooding.
- `.env.example`: no-secrets local environment template.
- `tests/smoke.sh`: CLI smoke checks for local and release validation.

## Current Scaffold Gaps

Missing from this Cycle repo scaffold:

- project registry persistence
- engine registry and version lock file
- scheduler ported into Cycle-owned modules
- review judge policy ported into Cycle-owned modules
- global policy validation, drift reporting, and optional workflow propagation
- real service install/start/status daemon behavior
- release workflow and built artifacts
- Homebrew tap update
- automated tests beyond CLI smoke checks
- commit/push of the scaffold

The adapted Symphony source used as the behavioral reference is copied under `reference/adapted-symphony/` for porting.
