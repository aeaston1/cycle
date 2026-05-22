# Cycle Architecture

Cycle is the control plane. Symphony is the execution engine.

Symphony answers: given a workflow and issue, run an isolated coding-agent lifecycle.

Cycle answers: discover projects, choose the right Symphony engine/version, enforce policy, schedule capacity, judge review value, and show the whole operating picture.

## Existing Backing Behaviors

The current adapted Symphony implementation already contains the behaviors Cycle should expose and productize:

- Multi-project Linear discovery: Linear projects opt in through description metadata, currently under `symphony:`.
- Repo-owned workflow policy: project-specific behavior stays in each repo's `WORKFLOW.md`.
- Per-project workspace cloning: discovered issues clone into repo-scoped workspaces and validate workflow availability.
- Project-aware concurrency: global capacity is combined with per-project and per-state caps from project workflows.
- Linear dependency gating: unresolved blockers prevent dispatch or stop active runs.
- Review judge routing: the judge reads issue comments, workpad, and git evidence, then routes review decisions.
- Judge safety/idempotency: evidence hashes dedupe decisions and current Linear state is rechecked before writes.
- Dashboard capacity visibility: the current status surface shows project usage and workflow errors.
- Global workflow defaults: the adapted Symphony config path can merge a startup/discovery workflow into per-project workflows, with project values taking precedence.

These are not all implemented as Cycle-owned modules yet. They are the proven backing behaviors to lift behind the Cycle CLI/API.

## Current Discovery Model

The current adapted Symphony system is one running orchestrator with one discovery workflow, not one Symphony instance per project.

The discovery workflow configures `tracker.project_discovery.mode: opt_in_descriptions`, active issue states, workspace root, global agent capacity, and review judge settings. The orchestrator polls Linear on an interval. On each poll it asks the tracker for candidate issues, dispatches review judges for the review state, then dispatches eligible agent work if capacity remains.

The current global workflow merge is useful for defaults, but it is not a fleet policy system. Project `WORKFLOW.md` values override discovery workflow values. Cycle should therefore own global policy, validation, drift reporting, and optional propagation rather than relying on Symphony's merge behavior as enforcement.

Discovery is project-first:

1. Fetch Linear projects visible to the configured Linear API token.
2. Parse project description/content for opt-in YAML.
3. Keep projects whose metadata has `symphony.enabled: true` and a valid GitHub HTTPS repo URL.
4. Fetch issues in configured active states for each opted-in project slug.
5. Attach project metadata to each normalized issue.

The current adapted Symphony implementation treats `symphony:` metadata as authoritative. Cycle should use `cycle:` metadata as its project opt-in boundary instead of carrying that namespace forward.

## Dispatch Model

Once an issue has project metadata, the orchestrator evaluates it against the current scheduling rules:

- issue is in an active state
- issue is routable to the configured worker, if assignee routing is enabled
- unresolved Linear blockers are absent
- the issue is not already claimed, running, or being judged
- global capacity is available
- project and state capacity from the repo workflow is available
- worker capacity is available

Project workflow settings are loaded from the target repo's root `WORKFLOW.md`. The resolver can use a local checkout, a local repo path, or a cached clone. If a usable `WORKFLOW.md` cannot be found, the project is skipped for dispatch.

When dispatch proceeds, Symphony creates a per-issue workspace. For discovered projects, that workspace is a fresh clone of the project repo and must contain a valid root `WORKFLOW.md`. Symphony then starts one Codex-backed agent task for that issue. So the runtime unit is an issue run, while the project supplies routing, repo, workflow, and capacity context.

## Review Judge Model

The review judge follows the same discovery boundary. It fetches issues in the configured review source state from opted-in projects, skips blocked or already-running issues, gathers comments/workpad/git evidence, runs a read-only judge turn, writes a structured decision comment, and routes the issue when allowed.

Cycle should own this as policy, not as engine behavior. Symphony can still provide execution evidence, but Cycle should decide which review states matter, which labels or paths require human review, how confidence thresholds work, and when a previous judgement is stale.

## Product Components

### Project Registry

Discovers opted-in Linear projects, reads `cycle:` metadata, and records:

- Linear project identity
- repo URL
- workflow path
- selected engine
- project policy
- capacity settings
- discovery status and last error

### Engine Registry

Tracks installed Symphony engines and their capabilities:

- source repo and version/ref
- local install path
- supported workflow schema
- Codex defaults
- worker pool and sandbox settings
- health and last verification status

### Scheduler

Assigns eligible Linear issues across projects and engines while respecting:

- global capacity
- per-project capacity
- per-state capacity
- per-engine capacity
- dependency blockers
- budget/rate-limit pressure

The existing adapted Symphony scheduler is the behavioral reference.

Cycle adds the engine dimension that the current adapted Symphony implementation does not truly own yet. The current scheduler is multi-project and capacity-aware, but it is still scheduling work inside one modified Symphony runtime. Cycle's scheduler should decide which installed Symphony engine/version receives a run.

### Policy Layer

Owns review and merge-lane policy:

- review judge model and prompt policy
- hard-review paths and labels
- confidence gates
- rejudge/versioning behavior
- Human Review to Merging routing
- global policy defaults that apply across projects
- validation of project workflows against required fleet settings
- drift reporting when project workflows differ from desired policy
- optional propagation that prepares or applies repo workflow updates only after operator intent

The existing adapted Symphony review judge is the behavioral reference.

Symphony may still consume merged defaults for execution, but Cycle should be the authority that decides which defaults are recommended, which settings are required, which projects are out of policy, and whether changes should be proposed back to repositories.

### Console/API

Reports:

- watched projects
- active runs
- blocked issues
- Human Review and Merging queues
- PR/merge status
- token and rate-limit pressure
- engine health

The current adapted Symphony status dashboard already proves per-project usage and workflow-error visibility. Cycle should make that the fleet status surface across projects and engines.

V1 remains CLI plus localhost API rather than a web dashboard. The future
dashboard and versioned multi-engine protocol plan is tracked in
[future-roadmap.md](future-roadmap.md).

## CLI Direction

Cycle includes the intended operator command surface now:

```sh
cycle doctor
cycle linear configure
cycle symphony install
cycle symphony path
cycle project opt-in --repo <git-repository-url>
cycle project discover
cycle start [--dry-run] [--no-dispatch] [--once]
cycle status
cycle service install
cycle service status
```

The backing behavior is intentionally staged:

- `doctor`, `linear configure`, `symphony install/path`, `project opt-in`, `project discover`, `start`, and `status` have useful scaffold behavior now.
- `start` runs the Cycle discovery and scheduling reconciler in the foreground.
- `service install` remains a placeholder until Cycle owns daemon installation.
- `service status` reports a read-only service snapshot and does not start, stop, enable, disable, reload, or restart services.

The intended command responsibilities:

- `cycle doctor`: verify local prerequisites, config paths, engine directory, Linear auth visibility, and service prerequisites.
- `cycle linear configure`: write or validate Linear API configuration for discovery.
- `cycle symphony install`: install or update a pinned upstream OpenAI Symphony engine.
- `cycle symphony path`: print the selected managed engine path.
- `cycle project opt-in`: print project metadata YAML for Linear descriptions.
- `cycle project discover`: list opted-in Linear projects and their repos.
- `cycle start`: run Cycle discovery, workflow validation, drift reporting, scheduling, and optional dispatch decisions in the foreground for operator testing.
- `cycle status`: show local config, engine state, Linear config, watched project count, active runs, judge queue, and service/API health.
- future `cycle status` and `cycle doctor`: report policy drift and invalid project workflows against Cycle's global policy.
- `cycle service install`: install the Cycle daemon only after explicit operator setup.
- `cycle service status`: report daemon status without starting or stopping services.

## Porting Source

The adapted Symphony implementation has been copied into `reference/adapted-symphony/` as source material for the Cycle port.

That directory is not the Cycle runtime. It is a transition aid for moving the proven behavior into Cycle-owned modules while keeping upstream OpenAI Symphony as the engine.

## Non-Goals For The Current Scaffold

This scaffold does not:

- stop or replace existing services
- modify existing Symphony checkouts
- edit Linear projects directly
- install Homebrew formulas into a tap repo
- fork upstream Symphony as the product identity

## Product Direction

Cycle should be a Linear-native control plane for running many Symphony engines across many repositories, with policy, review judgement, capacity management, and observability built in.

The practical migration path is:

1. Keep the adapted Symphony source as the behavioral reference.
2. Move project discovery into Cycle-owned code.
3. Persist discovered projects in a Cycle project registry.
4. Add a Cycle engine registry and version lock file.
5. Port scheduling so Cycle assigns runs across projects and engines.
6. Port review judge policy so Cycle owns judgement and routing.
7. Add global policy validation, drift reporting, and optional workflow propagation.
8. Replace placeholder service commands with real daemon install/status behavior.
9. Add release artifacts and update the Homebrew tap formula.
10. Add tests around metadata parsing, discovery, scheduling, policy drift, service behavior, and CLI contracts.

## Companion Docs

- `porting-map.md`: implementation map from adapted Symphony files to Cycle modules.
- `config.md`: Cycle config files, environment, registries, and precedence.
- `engine-protocol.md`: contract between Cycle and managed Symphony engines.
- [future-roadmap.md](future-roadmap.md): future dashboard and explicit engine
  protocol roadmap.
- `metadata-spec.md`: Linear project metadata schema.
- `workflow-contract.md`: repo-owned workflow boundary.
- `scheduler-design.md`: scheduler and dispatch rules.
- `review-judge-policy.md`: automated review policy and safety.
- `service-model.md`: service lifecycle and migration safety.
- `release.md`: release and Homebrew tap process.
- `supporting-skills.md`: optional Codex skill inventory and install policy.
