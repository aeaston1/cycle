# Service Model

Cycle manages its service only after explicit operator setup. It must not stop,
replace, or mutate an existing Symphony service.

## Commands

```sh
cycle service install
cycle service status
cycle start
cycle status
```

## `cycle start`

`cycle start` is for foreground operator testing.

Implemented behavior:

- reads Cycle config
- performs foreground discovery and scheduling
- validates project workflows against global policy during discovery
- records policy drift in the project registry
- prints foreground logs and writes configured log events
- fails fast on invalid config

It does not install a background service.

Foreground modes:

- `cycle start --dry-run` prints planned config, registry, polling, and dispatch behavior and exits.
- `cycle start --once` runs one discovery and scheduler cycle and exits.
- `cycle start --no-dispatch` records scheduler decisions without launching an engine run.

## `cycle service install`

`cycle service install` is explicit and conservative.

Implemented behavior:

- verify required commands are available
- verify Linear auth exists
- verify the default engine is installed or explain how to install it
- verify global policy can be parsed
- write a service file for the current platform
- enable the service only when the operator confirms or passes `--yes`
- print the service file, env file, rendered service, and planned manager
  commands in `--dry-run` mode

It does not:

- stop an existing Symphony service
- overwrite unrelated service files
- start work before config validation passes
- install secrets into the repository

## `cycle service status`

`cycle service status` is read-only.

It reports:

- service installed or missing
- service active/inactive/failed
- process id, if running
- config path
- state path
- log file path
- API health, if enabled
- engine health
- drift summary state

It does not start or stop services. Its implementation checks only non-mutating
service manager commands; mutating verbs are blocked by tests.

## Platform Targets

First supported platforms:

- macOS Homebrew install with `launchd`
- Linux with `systemd`

Cycle should keep service templates in the repo and fill paths at install time.

## Paths

Default paths:

```text
config: ${XDG_CONFIG_HOME:-~/.config}/cycle
state:  ${CYCLE_HOME:-~/.local/share/cycle}
logs:   ${CYCLE_HOME:-~/.local/share/cycle}/logs
engines:${CYCLE_HOME:-~/.local/share/cycle}/engines
```

Secrets should live in config files or environment files outside the repo. The
repo `.gitignore` should exclude local config, env files, state, logs, and build
artifacts.

## Service Environment

The service needs:

- `LINEAR_API_KEY`
- PATH that includes `git`, `curl`, and the selected Symphony engine runtime
- Cycle config path
- Cycle state path
- optional engine-specific environment

Secrets should never be embedded in release artifacts or Homebrew formulae.

## API

The daemon may expose a local API for status:

- bind to localhost by default
- expose health, status snapshot, projects, engines, runs, and logs pointers
- require explicit config for non-local binding

## Migration From Existing Symphony Service

During migration, Cycle should run beside existing Symphony until the operator
switches over.

Safe migration sequence:

1. Install Cycle CLI.
2. Configure Linear auth.
3. Install or pin Symphony engine.
4. Run `cycle project discover`.
5. Run `cycle start` in foreground with dry-run or no-dispatch mode.
6. Review policy drift against existing project workflows.
7. Optionally propagate approved workflow policy updates.
8. Compare status with the existing Symphony service.
9. Install Cycle service.
10. Stop or disable the old Symphony service only when the operator explicitly
   chooses to switch.

## Tests

Service tests should cover:

- status is read-only
- install refuses to overwrite unrelated files
- missing auth is reported clearly
- missing engine is reported clearly
- invalid global policy is reported clearly
- policy drift is reported without mutating project repos
- generated service file contains expected paths
- service commands do not start or stop services unless explicitly requested
