# Migrating From An Existing Symphony Service

Cycle can be evaluated beside an existing Symphony service. It does not stop,
disable, reload, or replace Symphony automatically.

## Configure A Comparison URL

If the existing Symphony service exposes a status endpoint, add it to Cycle
config:

```yaml
service:
  external_symphony_status_url: http://127.0.0.1:4764/api/v1/status
```

You can also set it for one shell session:

```sh
export CYCLE_EXTERNAL_SYMPHONY_STATUS_URL=http://127.0.0.1:4764/api/v1/status
```

`cycle status` reports the configured external Symphony URL and whether it is
reachable. This is for operator comparison only; Cycle does not write to that
service.

## Safe Preflight

Run Cycle in foreground before installing a background service:

```sh
cycle doctor
cycle project discover
cycle start --once --no-dispatch
cycle status
```

`cycle start --once --no-dispatch` performs one discovery and scheduling pass,
records the scheduler view, and exits without launching engine runs. Use this
to inspect project discovery, policy drift, engine health, and queued decisions
while the existing Symphony service continues to own live automation.

`cycle doctor` may show best-effort hints about an existing Symphony service
when the local service manager can report it. The check is read-only.

## Compare Before Cutover

Before switching, compare:

- opted-in projects in `cycle status` against the existing Symphony dashboard or
  status endpoint
- policy drift count and records
- queued and blocked Cycle decisions
- engine health
- logs under the Cycle state path

If Cycle and Symphony disagree, keep Symphony running and fix Cycle config,
project metadata, or workflow policy first.

## Final Cutover

Only after the operator decides Cycle should take over:

1. Run `cycle service install --dry-run`.
2. Review the service file path, env file path, config path, and planned service
   manager command.
3. Run `cycle service install --yes`.
4. Confirm `cycle service status` reports the Cycle service state.
5. Stop or disable the old Symphony service manually with the service manager
   command appropriate for the host.
6. Re-run `cycle status` and compare it with logs from the old service.

Cycle does not implement automatic cutover.
