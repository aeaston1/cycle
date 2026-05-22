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
cycle linear configure
cycle symphony install
cycle project opt-in --repo https://github.com/OWNER/REPO.git
cycle project discover
cycle status
```

## Commands

- `cycle doctor`
- `cycle linear configure`
- `cycle symphony install`
- `cycle symphony path`
- `cycle project opt-in --repo <git-repository-url>`
- `cycle project discover [--limit N] [--raw]`
- `cycle policy drift [--json]`
- `cycle policy propagate --project PROJECT --dry-run`
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
- Config: `docs/config.md`
- Metadata: `docs/metadata-spec.md`
- Workflow contract: `docs/workflow-contract.md`
- Scheduler: `docs/scheduler-design.md`
- Review judge: `docs/review-judge-policy.md`
- Service model: `docs/service-model.md`
- Release: `docs/release.md`
