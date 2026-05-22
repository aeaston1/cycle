# Porting Map

This map translates the current adapted Symphony implementation into Cycle-owned
components. The files under `reference/adapted-symphony/` are a behavioral
reference, not runtime code.

## Porting Rule

Port orchestration and policy into Cycle. Keep execution mechanics inside
Symphony whenever possible.

Cycle should own discovery, registries, scheduling, policy, service lifecycle,
status, global policy validation, drift reporting, and optional propagation.
Symphony should own the isolated agent run once Cycle has selected an issue,
repo, workflow, and engine version.

## Source To Target Map

| Adapted Symphony source | Current behavior | Cycle target |
| --- | --- | --- |
| `WORKFLOW.discovery.md` | Single discovery workflow for the running service. Defines Linear discovery mode, active states, workspace root, global capacity, Codex command, and review judge settings. | `cycle daemon` config defaults and service template. Cycle should store operator config outside project repos, treat it as global policy, and pass per-run workflow context to engines. |
| `linear/client.ex` | Lists Linear projects, parses `symphony:` metadata, fetches issues project-by-project, attaches project repo metadata, reads blockers and labels. | `Cycle.Linear.Client`, `Cycle.ProjectDiscovery`, and `Cycle.ProjectMetadata`. Parse `cycle:` metadata only; do not carry the `symphony:` metadata namespace forward as a Cycle opt-in path. |
| `linear/issue.ex` | Normalized Linear issue struct with project metadata, blockers, labels, state, branch, assignee, and timestamps. | `Cycle.Issue` or registry record used by scheduler and policy. Keep raw Linear IDs for revalidation and writes. |
| `tracker.ex` and `tracker/memory.ex` | Adapter boundary used by the orchestrator to fetch candidate issues and issue state refreshes. | `Cycle.Tracker` behavior plus Linear implementation. Keep a narrow contract: discover projects, fetch candidates, refresh issue state, move/comment issues. |
| `project_workflow.ex` | Resolves each discovered project's root `WORKFLOW.md` from a local path, local checkout, or cached clone; loads project agent settings. | `Cycle.WorkflowResolver`. It should read only the subset Cycle needs for scheduling and policy, validate it against global policy, record drift, then pass the workflow through to Symphony. |
| `workflow.ex` and `workflow_store.ex` | Loads workflow files and tracks global workflow path. The adapted implementation can merge global workflow defaults into project workflows, with project values winning. | `Cycle.WorkflowContract` and cache helpers. Use structured YAML parsing, preserve pass-through content for the engine, and make global policy validation explicit instead of relying on inherited defaults as enforcement. |
| `config.ex` and `config/schema.ex` | Defines tracker, polling, workspace, worker, agent, Codex, hooks, review judge, and observability schema. | Split into `Cycle.Config`, `Cycle.GlobalPolicy`, `Cycle.WorkflowPolicy`, `Cycle.PolicyDrift`, `Cycle.EngineConfig`, and compatibility parser for existing Symphony workflow fields. |
| `workspace.ex` | Creates per-issue workspaces, clones project repos, validates root `WORKFLOW.md`, and runs hooks locally or over SSH. | Short term: keep as engine-adapter behavior. Long term: `Cycle.WorkspaceAllocator` can prepare workspaces only if upstream Symphony exposes a stable handoff contract. |
| `orchestrator.ex` | Poll loop, review judge dispatch, candidate issue dispatch, revalidation, dependency gating, retry/stall handling, capacity checks, worker selection, and status snapshot. | `Cycle.Scheduler`, `Cycle.RunStore`, `Cycle.Reconciler`, `Cycle.EngineSelector`, and `Cycle.StatusSnapshot`. Add engine-aware scheduling and durable registry state. |
| `agent_runner.ex` | Starts one issue run in a workspace, loads repo workflow, runs hooks, and drives Codex turns through the app server. | Prefer to keep inside Symphony engine. Cycle should call an engine adapter rather than duplicate turn execution. |
| `review_judge.ex` | Builds evidence from Linear comments/workpad/workspace/git, applies hard stops, runs a read-only judge turn, posts decision, and routes state. | `Cycle.Policy.ReviewJudge`. Cycle owns policy, idempotency, routing, and stale-state checks. Symphony may provide run evidence. |
| `status_dashboard.ex` | Terminal dashboard over orchestrator snapshot, project capacity, tokens, rate limits, running runs, retries, and worker messages. | `Cycle.Console` and `Cycle.API`. Expand from one runtime to fleet status across projects, engines, invalid workflows, and policy drift. |
| `codex/app_server.ex` | Starts Codex app-server sessions and streams turn events. | Engine-owned detail unless Cycle adds a generic engine protocol. Cycle should consume structured run state from Symphony. |
| `codex/dynamic_tool.ex` | Exposes Linear GraphQL through a Symphony app-server session. | Optional `Cycle.ToolBroker` or keep in engine sessions. Do not make Cycle depend on this for core scheduler operations. |
| `prompt_builder.ex` | Builds the agent prompt for a Linear issue. | Engine-owned unless Cycle creates a generic issue handoff prompt. Repo-owned `WORKFLOW.md` should remain the main policy surface. |

## Files Not Yet Copied Into Reference

The current Cycle reference slice intentionally omits some adapted Symphony files
that may still be useful during porting:

- `agent_runner.ex`
- `cli.ex`
- `http_server.ex`
- `log_file.ex`
- `path_safety.ex`
- `specs_check.ex`
- `ssh.ex`
- tests, release files, web/static assets, and full Mix project config

Before porting any behavior that depends on those modules, copy or inspect the
current adapted Symphony source and add the relevant files to the reference
snapshot.

## Porting Order

1. Metadata parser and validation.
2. Linear project discovery and project registry.
3. Workflow resolver and read-only scheduling policy extraction.
4. Global policy validation and drift reporting.
5. Engine registry and version lock file.
6. Scheduler with issue revalidation, dependency gating, and capacity checks.
7. Engine adapter for upstream OpenAI Symphony.
8. Review judge policy and idempotency.
9. Optional workflow propagation for operator-approved policy updates.
10. Status API and console.
11. Service installer/status implementation.

## Acceptance Criteria For A Ported Feature

- The behavior is Cycle-owned, not only copied under `reference/`.
- The public CLI has a stable command or documented config surface.
- State is inspectable through `cycle status` or a registry file.
- Projects must use `cycle:` metadata to opt in to Cycle discovery.
- Global policy drift is reported and never silently propagated.
- Tests cover parsing, success path, invalid input, and one stale-state case
  when Linear writes are involved.
