# Agent Instructions

These instructions apply to agents working in the Cycle repository.

## Product Boundary

Cycle is the control plane. Symphony is the execution engine.

Do not turn Cycle into a renamed Symphony fork. Cycle should own discovery,
registries, scheduling, global policy, validation, drift reporting, optional
propagation, service lifecycle, status, release packaging, and operator CLI.
Symphony should remain the engine that runs an isolated coding-agent lifecycle
for one issue, repo/workspace, and workflow.

## Public Repository Rules

- Do not hardcode private owner/repo names in docs, tests, examples, generated
  config, or code.
- The Homebrew tap command may stay hardcoded as `brew install aeaston1/tap/cycle`.
- Use placeholder examples such as `OWNER/REPO` and
  `https://github.com/OWNER/REPO.git`.
- Do not commit secrets, local state, logs, engine checkouts, release archives,
  or machine-local config.
- Keep `.env.example` free of real values.

## Runtime Safety

- Do not stop, restart, replace, or mutate existing Symphony services unless the
  operator explicitly asks for that.
- `cycle service status` must remain read-only.
- `cycle service install` must be explicit and conservative.
- Keep foreground testing separate from service installation.

## Implementation Guidance

- Prefer small, reviewable changes.
- Keep docs and CLI behavior aligned.
- Use structured parsers for YAML, JSON, and config data.
- Use `cycle:` Linear project metadata as the only Cycle opt-in namespace.
- Put Cycle-owned state under Cycle config/state paths, not inside project repos.
- Do not silently write to user agent skill directories or repo `.codex/skills`.

## CLI Expectations

The intended command surface is:

```sh
cycle doctor
cycle linear configure
cycle symphony install
cycle symphony path
cycle project opt-in --repo <git-repository-url>
cycle project discover
cycle start
cycle status
cycle service install
cycle service status
```

Service and install commands should fail clearly when prerequisites are missing.

## Validation

For CLI-only changes, run:

```sh
tests/smoke.sh
```

For docs-only changes, verify links and examples manually.

For release-path changes, also review:

- `docs/release.md`
- `packaging/homebrew/cycle.rb`
- `.gitignore`
