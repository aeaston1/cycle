# Engine Protocol

Cycle manages Symphony as an engine. The engine protocol defines the boundary
between Cycle's control plane and a managed Symphony runner.

The first implementation can be a pragmatic adapter around the upstream OpenAI
Symphony CLI. The long-term shape should be an explicit request/status contract
that can support multiple Symphony versions. See
[future-roadmap.md](future-roadmap.md) for the dashboard and versioned protocol
roadmap beyond the v1 adapter.

## Responsibilities

Cycle owns:

- Linear project discovery
- project registry
- engine registry and version lock
- issue scheduling
- dependency and capacity gates
- review judge policy
- global policy validation, drift reporting, and optional propagation
- service lifecycle
- status across projects and engines

Symphony owns:

- isolated workspace execution
- agent prompt/run lifecycle
- Codex app-server/session details
- workflow-specific hooks during a run
- run logs and execution evidence

## Engine Identity

An engine id should include name and version/ref:

```text
openai-symphony@main
openai-symphony@v0.1.0
```

Engine registry record:

```yaml
id: openai-symphony@main
name: openai-symphony
source_repo: https://github.com/openai/symphony.git
ref: main
install_path: ${CYCLE_HOME}/engines/openai-symphony/main
capabilities:
  adapter: symphony
  adapter_contract: cycle.engine.adapter.v1
  workflow_schema: symphony.v1
  run_mode: foreground_process
  process_supervision: true
  status_api: false
  dispatch:
    single_issue: false
    unsupported_reason: upstream Symphony does not expose a stable single-run protocol
  stop:
    foreground_process: false
  supports_external_workspace: false
  supports_review_evidence: partial
health:
  status: healthy
  checked_at: 2026-05-22T00:00:00Z
```

## Run Request

Cycle should be able to express a run request like this, even if the first
adapter translates it into CLI arguments:

```yaml
run_id: cycle-run-id
engine: openai-symphony@main
linear:
  issue_id: linear-issue-id
  identifier: AEA-123
project:
  id: linear-project-id
  repo_url: https://github.com/OWNER/REPO.git
  repo_full_name: OWNER/REPO
workflow:
  path: WORKFLOW.md
  resolved_path: ${CYCLE_HOME}/workflow-cache/OWNER-REPO/WORKFLOW.md
workspace:
  mode: engine_allocated
policy:
  approval_policy: never
  sandbox: workspace-write
  global_policy_version: cycle-policy-sha
  drift_status: valid
metadata:
  scheduled_by: cycle
```

## Run Status

Engines should report:

```yaml
run_id: cycle-run-id
state: running
engine: openai-symphony@main
issue_identifier: AEA-123
workspace_path: ${CYCLE_HOME}/runs/cycle-run-id/workspace
session_id: codex-thread-turn
started_at: 2026-05-22T00:00:00Z
last_event_at: 2026-05-22T00:01:00Z
turn_count: 1
tokens:
  input: 0
  output: 0
  total: 0
evidence:
  changed_files: []
  pr_url: null
  summary: null
```

Terminal states:

- `completed`
- `failed`
- `cancelled`
- `stale`

Non-terminal states:

- `queued`
- `starting`
- `running`
- `retrying`
- `judging`

## Health Check

Cycle should health-check an engine before scheduling work to it.

Minimum checks:

- install path exists
- expected executable exists
- version/ref is readable
- required runtime commands are available
- status API responds, if the engine advertises one
- workflow schema compatibility is known
- engine defaults can satisfy required global policy, or Cycle has an explicit
  project override decision

## Error Contract

Engine errors should be structured:

```yaml
code: workflow_missing
message: Repo workflow was not found at WORKFLOW.md
retryable: false
details:
  repo_url: https://github.com/OWNER/REPO.git
```

Cycle should distinguish:

- retryable engine startup failures
- non-retryable workflow/config failures
- Linear stale-state skips
- capacity delays
- operator-action-required failures
- blocking policy drift

## Compatibility With Upstream Symphony

Cycle should not require upstream Symphony to accept Cycle-specific config in
the first version. The adapter may:

- install upstream Symphony into Cycle's engine directory
- run Symphony with a workflow path
- poll Symphony's status endpoint if available
- read logs or status files produced by Symphony

Current protocol gaps are explicit adapter capabilities:

- `dispatch.single_issue: false`: Cycle may record a queued run, but it must not
  create a running record or report dispatch success.
- `status_api: false` unless a configured engine version advertises a stable
  status URL.
- foreground `stop` is process-owned; Cycle does not stop unrelated existing
  Symphony services.

Foreground commands include Symphony's required no-guardrails flag only when
operator config explicitly enables unattended foreground operation for that
managed engine.

Cycle-specific state should remain outside the upstream Symphony checkout.

Cycle should not require upstream Symphony to enforce Cycle global policy. The
adapter should pass effective workflow and run settings to the engine, then
Cycle should validate, report drift, and optionally propagate changes outside
the engine boundary.

## Version Lock

Cycle should maintain an engine lock file:

```yaml
engines:
  openai-symphony:
    ref: main
    resolved_revision: git-sha
    installed_at: 2026-05-22T00:00:00Z
```

The lock lets operators upgrade Cycle without accidentally changing the
underlying Symphony engine behavior.
