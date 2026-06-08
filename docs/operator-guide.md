# Operator Guide

This guide covers the first public Cycle release from install through safe
foreground testing and explicit service installation.

Cycle is the control plane. It discovers opted-in Linear projects, validates
project metadata and workflows, records policy drift, schedules eligible work,
and manages installed Symphony engines. Symphony remains the execution engine
for one isolated issue, repository, workspace, and workflow.

## Install

Install the CLI with Homebrew:

```sh
brew install aeaston1/tap/cycle
```

From a source checkout during development, use `./bin/cycle` in place of
`cycle` in the examples below.

Run the local health check:

```sh
cycle doctor
```

`cycle doctor` checks required local commands and reports whether Linear auth
is configured. It is read-only.

## Configure Linear Auth

Cycle reads Linear auth from `LINEAR_API_KEY` or from operator-owned config.
Configure from the current environment:

```sh
export LINEAR_API_KEY=lin_api_placeholder
cycle linear configure --from-env
cycle linear configure --print
```

Or write the token directly:

```sh
cycle linear configure --api-key lin_api_placeholder
```

The command writes `${XDG_CONFIG_HOME:-~/.config}/cycle/config.yaml` with mode
`0600`. It does not write secrets into the repository.

## Project Onboarding

Cycle projects opt in through Linear project metadata using the `cycle:`
namespace. Generate the minimal block:

```sh
cycle project opt-in --repo https://github.com/OWNER/REPO.git
```

Paste the output into the Linear project description or content field:

```yaml
cycle:
  enabled: true
  repo: https://github.com/OWNER/REPO.git
```

Then discover opted-in projects:

```sh
cycle project discover --limit 10
cycle project discover --limit 10 --raw
```

Discovery validates metadata and writes the project registry under Cycle state.
Invalid projects are reported without blocking discovery for other projects.
See `docs/metadata-spec.md` for the accepted fields and parser behavior.

For source-checkout users who want agent-assisted onboarding, Cycle also keeps
an optional `skills/cycle-project-onboarding` skill source in this repository.
It is not installed by Homebrew or by any Cycle command; review and install it
manually only if you want an agent to help verify GitHub, Linear, and `cycle:`
metadata setup.

## Engine Install

Install the default Symphony engine:

```sh
cycle symphony install
cycle symphony path
```

By default this installs `openai-symphony@main` under Cycle state. The install
command uses `git`, refuses a non-git target directory, and records the engine
in the local engine registry after verifying the expected Symphony files exist.

Set `CYCLE_SYMPHONY_REPO` or `CYCLE_SYMPHONY_REF`, or pass `--repo` and
`--version`, to use a different public engine source or ref.

## Safe Foreground Run

Start with read-only planning output:

```sh
cycle start --dry-run
```

Run one foreground reconciliation cycle without dispatching work:

```sh
cycle start --once --no-dispatch
```

Run one foreground reconciliation cycle with dispatch enabled:

```sh
cycle start --once
```

Run the foreground loop:

```sh
cycle start
```

Implemented behavior:

- `--dry-run` prints registry paths, polling interval, and whether dispatch
  would be enabled, then exits.
- `--once` performs one discovery, validation, scheduling, and registry update
  cycle, then exits.
- `--no-dispatch` records scheduling decisions without launching engine runs.
- Without `--dry-run` or `--once`, Cycle runs a foreground loop and logs to the
  configured log path.

Dispatch requires valid Linear auth, valid project metadata, a valid workflow,
and a healthy installed engine. Missing or unhealthy prerequisites are reported
instead of installing services or mutating Symphony services.

## Status And Drift

Check operator status:

```sh
cycle status
cycle status --json
```

Check persisted policy drift:

```sh
cycle policy drift
cycle policy drift --json
```

Preview a drift propagation patch:

```sh
cycle policy propagate --project PROJECT --dry-run
```

Apply mode exists, but it is explicit:

```sh
cycle policy propagate --project PROJECT --apply
```

Cycle only uses `cycle:` Linear metadata for opt-in. Global policy remains in
Cycle operator config, and project workflow changes are never silently written
during discovery.

## Service Install

Inspect service status first:

```sh
cycle service status
cycle service status --json
```

`cycle service status` is read-only. It checks the platform service manager and
reports service, config, state, log, API, engine, and drift summary data without
starting, stopping, enabling, disabling, reloading, or restarting services.

Preview installation:

```sh
cycle service install --dry-run
```

Install after reviewing the target service file and planned manager commands:

```sh
cycle service install
```

For non-interactive installation:

```sh
cycle service install --yes
```

Service installation is conservative. It requires Linear auth, parseable policy
config, a healthy default engine, an installed `cycle` executable, and a
supported service manager. It refuses to overwrite an unrelated existing service
file. It writes a service file and Cycle env file outside the repository, then
enables the service. It does not stop, restart, replace, or mutate existing
Symphony services.

## Troubleshooting

Missing Linear auth:

```sh
cycle linear configure --print
cycle linear configure --from-env
```

If `project discover`, `start`, or `service install` says
`LINEAR_API_KEY is not configured`, export `LINEAR_API_KEY` or rerun
`cycle linear configure`.

Missing engine:

```sh
cycle symphony path
cycle symphony install
cycle status
```

If service install reports `default engine ... is missing`, install the engine
before installing the service.

Invalid project metadata:

```sh
cycle project discover --limit 10
cycle project discover --limit 10 --raw
```

Common errors are a missing `enabled: true`, missing `repo`, non-HTTPS GitHub
URLs, absolute or parent-traversing workflow paths, non-string engine refs,
invalid capacity values, or secret-like metadata keys.

Invalid workflow:

```sh
cycle project discover --limit 10
cycle status
```

Cycle records invalid workflows in discovery and status output. Fix the
repo-owned workflow file, then rerun discovery.

Policy drift:

```sh
cycle policy drift
cycle policy propagate --project PROJECT --dry-run
```

Drift means a discovered project workflow differs from Cycle global policy or
is missing a required policy field. Review dry-run patches before using
explicit apply mode.

Dispatch unsupported or suppressed:

```sh
cycle start --once --no-dispatch
cycle start --once
cycle status
```

Cycle suppresses or blocks dispatch when metadata is invalid, the workflow is
invalid, the engine is missing or unhealthy, global policy blocks the project,
capacity is exhausted, budget or rate-limit gates block work, or dependencies
are incomplete. Use `--no-dispatch` to verify discovery and scheduler decisions
without launching an engine run.

Service install refused:

```sh
cycle service install --dry-run
cycle service status
```

The installer refuses missing auth, invalid policy config, missing engine,
unsupported platforms, missing `cycle` executable, unconfirmed non-interactive
installs, and unrelated existing service files.

## Migration From Existing Symphony Service

Cycle can run beside an existing Symphony service while operators validate the
control plane.

1. Install Cycle CLI.
2. Configure Linear auth.
3. Add `cycle:` metadata to one Linear project.
4. Run `cycle project discover`.
5. Install or pin the Symphony engine with `cycle symphony install`.
6. Run `cycle start --dry-run`.
7. Run `cycle start --once --no-dispatch`.
8. Review `cycle status` and `cycle policy drift`.
9. Preview any drift propagation with `cycle policy propagate --dry-run`.
10. Install the Cycle service only after foreground behavior is understood.
11. Stop or disable the old Symphony service only when the operator explicitly
    chooses to switch.

Cycle service commands do not mutate existing Symphony services.
