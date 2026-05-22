# Supporting Skills

This machine has supporting Codex skills that help operate the current adapted
Symphony workflow. They are useful context for Cycle, but they should not all be
installed automatically by Homebrew.

## Symphony-Local Skills Found

These were observed in the local adapted Symphony checkout under
`.codex/skills`:

| Skill | Purpose | Cycle recommendation |
| --- | --- | --- |
| `commit` | Create a well-formed git commit from current changes. | Useful for issue runs, but should remain operator/agent guidance rather than a required Cycle install. |
| `debug` | Investigate stuck Symphony and Codex runs through logs and session ids. | Port into a Cycle troubleshooting doc or optional skill pack. |
| `land` | Monitor PR conflicts/checks/reviews and squash-merge when ready. | Keep optional. Cycle policy may call this a merge-lane skill, but Homebrew should not install it into user repos by default. |
| `linear` | Use Symphony's `linear_graphql` tool during app-server sessions. | Replace with Cycle-owned Linear APIs for core operations; keep optional for raw operator debugging. |
| `pull` | Merge latest `origin/main` into a branch and resolve conflicts. | Useful optional agent guidance. Not a core Cycle dependency. |
| `push` | Push a branch and create/update a PR. | Useful optional agent guidance. Not a core Cycle dependency. |

The `land` skill also includes `land_watch.py`, a helper for watching PR review
comments, CI, and head updates.

## Global Skills Found

Relevant global skills on this machine include:

| Skill | Purpose | Cycle recommendation |
| --- | --- | --- |
| `cycle-mvp-builder` | Guides product ideation, Cycle-managed Linear/GitHub resource creation, and repo `WORKFLOW.md` setup. | Good candidate for a separate Cycle operator skill, not a default CLI dependency. |
| `linear-decision-issues` | Creates or rewrites Linear issues so they are implementation-ready. | Useful upstream workflow skill. Keep optional and document as recommended for issue authoring. |
| `plan-reviewer` | Reviews implementation plans before coding. | Optional quality gate. |
| `new-once-app` and `once-rails-app` | Host-specific app deployment guidance. | Do not include in public Cycle install; too machine-specific. |

## Install Policy

Homebrew should install the Cycle CLI only. It should not write into `~/.codex`,
repo `.codex/skills`, or global skill directories by default.

Reasons:

- Skills are agent/operator guidance, not core Cycle runtime dependencies.
- Some skills are machine-specific or workflow-specific.
- Public install should avoid mutating user agent configuration silently.
- Skill installation may require user consent and may change how agents behave.

## Recommended Product Shape

Add an explicit optional command later:

```sh
cycle skills list
cycle skills install recommended
cycle skills install symphony-ops
```

That command should:

- show exactly which skills will be installed
- ask for confirmation unless a non-interactive flag is passed
- install into a clear user-owned location
- never overwrite local skill edits without a backup or explicit flag
- distinguish public Cycle skills from machine-local operator skills

## Public Cycle Skill Pack

A future public skill pack could include:

- `cycle-debug`: inspect Cycle daemon logs, run registry, engine health, and
  failed dispatch reasons
- `cycle-linear`: safe Linear issue/project operations using Cycle auth
- `cycle-release`: prepare release artifacts and Homebrew tap updates
- `cycle-judge-review`: inspect judge evidence, hashes, and routing decisions
- `cycle-project-onboarding`: create `cycle:` metadata and repo `WORKFLOW.md`

The existing Symphony skills are good prototypes, but they should be rewritten
around Cycle concepts before being distributed as Cycle skills.
