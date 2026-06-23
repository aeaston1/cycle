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

Cycle-owned runtime paths must stay under the configured state root. Registry
files, workflow caches, engine registries, engine install roots, and service
logs may be customized, but they must resolve under `paths.state_dir`
(`CYCLE_HOME` by default). Relative overrides such as `projects.yaml` are
rejected because they can otherwise write Cycle state into the current project
repository.

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
  lock_path: ${CYCLE_HOME}/engines.lock.yaml
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
  external_review:
    enabled: false
    provider: clawpatch
    execution: local_workspace
    trigger: after_tentative_proceed
    failure_decision: require_human_review
    timeout_ms: 120000
    command: clawpatch
    args:
      - review
      - --json
      - --since
      - origin/main
    artifact_dir: ${CYCLE_HOME}/review-jobs
    route_findings_to_rework: true
    rework_state: Rework
    fix:
      enabled: false

policy:
  enforcement: report
  drift:
    report_in_status: true
    propagation: manual

service:
  api:
    enabled: true
    bind: 127.0.0.1
    port: 4765
  external_symphony_status_url: null
  logs:
    path: ${CYCLE_HOME}/logs/cycle.log
```

`cycle linear configure` writes a minimal `config.yaml`. With `--from-env`, it
stores `linear.api_key_env: LINEAR_API_KEY`; with `--api-key`, it stores the
provided token directly in the operator config file with mode `0600`.
`foreground_unattended` is intentionally false by default. Full dispatch policy
profiles beyond the default global policy fields are roadmap behavior.

External review providers are disabled by default. If
`review_judge.external_review.enabled` is false, Cycle must not call external
review or fix tools. The implemented local provider config is intentionally
structured as `command` plus `args`; shell command strings are rejected. Human
Review remains a review-routing state only: Cycle may post the review judge
summary and route to `Merging`, but it must not apply automated fixes from that
state. `Rework` remains a normal active execution state, and the `fix.enabled`
setting is rejected in v1 because automated fix execution is not implemented.

The local external review fields can be overridden with:

```sh
CYCLE_REVIEW_EXTERNAL_ENABLED=true
CYCLE_CLAWPATCH_COMMAND=clawpatch
CYCLE_CLAWPATCH_ARGS="review --json --since origin/main"
CYCLE_REVIEW_EXTERNAL_ARTIFACT_DIR=${CYCLE_HOME}/review-jobs
CYCLE_CLAWPATCH_CONFIG_PATH=/path/to/clawpatch.json
CYCLE_CRABBOX_CONFIG_PATH=/path/to/crabbox.toml
```

When the local provider runs, Cycle first looks for explicit
`clawpatch_config_path` and `crabbox_config_path` values, then for common
Clawpatch and Crabbox config files in the inspected workspace. If no Crabbox
config exists and an artifact directory is configured, Cycle writes a
Cycle-owned `cycle-crabbox.cloudflare-workers.json` fallback under that review
job artifact directory. The fallback declares Cloudflare Workers as the Crabbox
runtime and expects credentials/provisioning to come from an external plugin;
Cycle does not write Cloudflare secrets into project repos.

Scheduler budget and rate-limit gates accept `mode: off`, `mode: warn`, or
`mode: block`. When `pressure: true`, warn mode reports the pressure in
`cycle status` and scheduler decisions without blocking new work; block mode
prevents new dispatch with the configured `reason`. Existing running work is
not stopped by these gates.

`service.external_symphony_status_url` is an optional read-only comparison URL
for migration from an existing Symphony service. It can also be set with
`CYCLE_EXTERNAL_SYMPHONY_STATUS_URL`. Cycle only reports reachability for this
URL; it does not use it for dispatch or service lifecycle actions.

## Legacy Config Compatibility

The Bash scaffold used:

```text
${XDG_CONFIG_HOME:-~/.config}/cycle/config.env
```

Cycle may read this legacy file for compatibility when `config.yaml` is absent
or does not provide a Linear API key. New commands should write `config.yaml`.

## Registry Files

Registry files:

```text
${CYCLE_HOME}/projects.yaml
${CYCLE_HOME}/engines.yaml
${CYCLE_HOME}/engines.lock.yaml
${CYCLE_HOME}/runs.yaml
```

These files are local state. They are inspectable by operators and safe to
delete after stopping Cycle, though deletion may lose run history, engine
records, discovered projects, and retry state.

## Precedence

Implemented effective precedence, highest to lowest:

1. CLI flags.
2. Environment variables.
3. Cycle config file.
4. Legacy `config.env` Linear auth compatibility.
5. Repo-owned `WORKFLOW.md`.
6. Built-in defaults.

Effective load order is built-in defaults, repo-owned workflow defaults, config
file, environment values, then CLI overrides.

## Global Policy

Cycle global policy is the operator-owned desired state for the fleet. It can
define defaults and requirements for settings such as Codex model, Codex
reasoning effort, service tier, review judge model, judge reasoning effort,
hard-review paths, labels, capacity ceilings, and allowed engines.

Cycle validates discovered project workflows against this policy and records
drift in the project registry. Drift means a project workflow differs from the
desired fleet setting, is missing a required setting, or references an
engine/policy profile that is not allowed by Cycle config.

Policy enforcement modes are documented for operator intent:

- `report`: record drift and show persisted drift through `cycle status` and
  `cycle policy drift`, but do not block dispatch unless the workflow is
  invalid.
- `block`: prevent dispatch for projects with required-policy drift.
- `propagate`: prepare or apply workflow updates only through an explicit
  operator command or confirmation.

The first public version defaults to `report`. Propagation is manual and is
never performed during discovery.

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
