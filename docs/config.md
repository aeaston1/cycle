# Configuration

Cycle uses operator-owned config and state paths. Project-specific workflow
instructions stay in each repository's `WORKFLOW.md`, while Cycle owns global
policy, validation, drift reporting, and optional propagation.

## Paths

Defaults:

```text
config: ${XDG_CONFIG_HOME:-~/.config}/cycle
state:  ${CYCLE_HOME:-~/.local/share/cycle}
logs:   ${CYCLE_HOME:-~/.local/share/cycle}/logs
engines:${CYCLE_HOME:-~/.local/share/cycle}/engines
```

The repository should not contain secrets, local config, logs, engine checkouts,
or runtime state.

## Environment

Minimum environment:

```sh
LINEAR_API_KEY=
```

Optional environment:

```sh
CYCLE_HOME=
XDG_CONFIG_HOME=
CYCLE_STATUS_URL=
CYCLE_SYMPHONY_REPO=
CYCLE_SYMPHONY_REF=
```

See `.env.example` for a no-secrets template.

## Main Config File

Primary path:

```text
${XDG_CONFIG_HOME:-~/.config}/cycle/config.yaml
```

Example:

```yaml
linear:
  endpoint: https://api.linear.app/graphql
  api_key_env: LINEAR_API_KEY
  discovery:
    mode: opt_in_descriptions
    preferred_namespace: cycle
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
    - Closed

polling:
  interval_ms: 30000

projects:
  registry_path: ${CYCLE_HOME}/projects.yaml
  workflow_cache_path: ${CYCLE_HOME}/workflow-cache

engines:
  registry_path: ${CYCLE_HOME}/engines.yaml
  lock_path: ${CYCLE_HOME}/engines.lock
  default: openai-symphony@main
  install_root: ${CYCLE_HOME}/engines
  managed:
    openai-symphony:
      repo: https://github.com/openai/symphony.git
      default_ref: main
      foreground_unattended: false

scheduler:
  max_concurrent_runs: 10
  max_retry_backoff_ms: 300000
  stale_run_timeout_ms: 300000
  budget:
    mode: warn
    pressure: false
  rate_limit:
    mode: warn
    pressure: false

review_judge:
  enabled: false
  source_state: Human Review
  review_state: Human Review
  proceed_state: Merging
  policy: standard
  minimum_skip_confidence: medium
  hard_require_human_review:
    paths: []
    labels: []

policy:
  enforcement: report
  required:
    codex:
      model: gpt-5.5
      reasoning_effort: low
      service_tier: fast
    review_judge:
      model: gpt-5.5
      reasoning_effort: xhigh
      service_tier: fast
  drift:
    report_in_status: true
    propagation: manual

service:
  api:
    enabled: true
    bind: 127.0.0.1
    port: 4765
  logs:
    path: ${CYCLE_HOME}/logs/cycle.log
```

The current scaffold writes a minimal `config.yaml` from
`cycle linear configure`. `foreground_unattended` is intentionally false by
default; when true for a managed Symphony engine, `cycle start` may include the
upstream no-guardrails flag for foreground operator testing. Full dispatch
policy loading is planned behavior.

Scheduler budget and rate-limit gates accept `mode: off`, `mode: warn`, or
`mode: block`. When `pressure: true`, warn mode reports the pressure in
`cycle status` and scheduler decisions without blocking new work; block mode
prevents new dispatch with the configured `reason`. Existing running work is
not stopped by these gates.

## Legacy Config Compatibility

The Bash scaffold used:

```text
${XDG_CONFIG_HOME:-~/.config}/cycle/config.env
```

Cycle may read this legacy file for compatibility when `config.yaml` is absent
or does not provide a Linear API key. New commands should write `config.yaml`.

## Registry Files

Planned registry files:

```text
${CYCLE_HOME}/projects.yaml
${CYCLE_HOME}/engines.yaml
${CYCLE_HOME}/engines.lock
${CYCLE_HOME}/runs.yaml
```

These files are local state. They should be inspectable by operators and safe to
delete after stopping Cycle, though deletion may lose run history.

## Precedence

Recommended precedence:

1. CLI flags.
2. Environment variables.
3. Cycle config file.
4. Legacy `config.env` compatibility file.
5. Repo-owned `WORKFLOW.md`.
6. Built-in defaults.

Cycle should document every value that affects dispatch, service behavior, or
Linear writes.

## Global Policy

Cycle global policy is the operator-owned desired state for the fleet. It can
define defaults and requirements for settings such as Codex model, Codex
reasoning effort, service tier, review judge model, judge reasoning effort,
hard-review paths, labels, capacity ceilings, and allowed engines.

Cycle should validate discovered project workflows against this policy and
record drift in the project registry. Drift means a project workflow differs
from the desired fleet setting, is missing a required setting, or references an
engine/policy profile that is not allowed by Cycle config.

Policy enforcement modes:

- `report`: show drift in `cycle status` and `cycle doctor`, but do not block
  dispatch unless the workflow is invalid.
- `block`: prevent dispatch for projects with required-policy drift.
- `propagate`: prepare or apply workflow updates only through an explicit
  operator command or confirmation.

The first public version should default to `report`. Propagation should be
manual and should stage narrow repo changes, never silently rewrite project
workflows during discovery.

`cycle policy drift` lists persisted drift records from the project registry.
`cycle policy propagate --project PROJECT --dry-run` renders a proposed
workflow patch without changing files. Apply mode is explicit and refuses dirty
project worktrees unless the operator passes the dirty-worktree override.
Generated edits are limited to propagation-available workflow policy fields.

## Secrets

Secrets should be read from environment variables or operator-owned config files
outside the repository.

Do not put secrets in:

- Linear project metadata
- repo `WORKFLOW.md`
- Homebrew formulae
- release artifacts
- docs examples
