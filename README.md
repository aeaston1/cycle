# Cycle

Cycle is a Linear-native control plane for running
[Symphony](https://github.com/openai/symphony) across many repositories.

Symphony runs one isolated coding-agent workflow for one issue and repo.
Cycle discovers opted-in projects, validates policy, schedules work, tracks
status, respects dependencies, and manages Symphony engines.

## Install

```sh
brew install aeaston1/tap/cycle
```

## Quick Start

```sh
cycle doctor
export LINEAR_API_KEY=lin_api_placeholder
cycle linear configure --from-env
cycle linear configure --print
cycle project opt-in --repo https://github.com/OWNER/REPO.git
cycle project discover
cycle symphony install
cycle start --dry-run
cycle start --once --no-dispatch
cycle status
```

This path configures Linear auth from the environment, prints public-safe
Linear project metadata, discovers opted-in projects, installs the default
Symphony engine, performs a foreground dry run, and checks status. See
`docs/operator-guide.md` for the complete install, first-run, service,
troubleshooting, and migration guide.

## Commands

- `cycle doctor`
- `cycle linear configure`
- `cycle symphony install`
- `cycle symphony path`
- `cycle project opt-in --repo <git-repository-url>`
- `cycle project discover [--limit N] [--raw]`
- `cycle policy drift [--json]`
- `cycle policy propagate --project PROJECT --dry-run`
- `cycle policy propagate --project PROJECT --apply [--allow-dirty]`
- `cycle start`
- `cycle status`
- `cycle service install`
- `cycle service status`

`cycle service status` reports a read-only service snapshot without starting,
stopping, enabling, disabling, reloading, or restarting services.

## Project Opt-In

Projects opt in through Linear project metadata using the `cycle:` namespace.
Add this to the Linear project description:

```yaml
cycle:
  enabled: true
  repo: https://github.com/OWNER/REPO.git
```

See `docs/metadata-spec.md`.

`cycle project discover --raw` prints normalized discovery records as JSON.

## Documentation

- Architecture: `docs/architecture.md`
- Operator guide: `docs/operator-guide.md`
- Config: `docs/config.md`
- Metadata: `docs/metadata-spec.md`
- Workflow contract: `docs/workflow-contract.md`
- Scheduler: `docs/scheduler-design.md`
- Review judge: `docs/review-judge-policy.md`
- Service model: `docs/service-model.md`
- Release: `docs/release.md`
