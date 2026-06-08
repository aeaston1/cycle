# Supporting Skills

Cycle may eventually offer optional Codex skills for operators, but skills are
not part of the default Cycle install. The Homebrew package installs the Cycle
CLI and documentation only.

Skills can change how an agent interprets tasks, reads context, and performs
operator workflows. For that reason, Cycle must treat skill installation as an
explicit operator action, separate from CLI installation, foreground testing,
service installation, and Symphony engine management.

## Symphony-Local Skills Found

The current adapted Symphony workflow has local skills under `.codex/skills`.
They are useful design input, but they are not public Cycle deliverables and
must not be redistributed as-is.

| Skill | Purpose | Cycle recommendation |
| --- | --- | --- |
| `commit` | Create a well-formed git commit from current changes. | Useful for issue runs, but should remain operator/agent guidance rather than a required Cycle install. |
| `debug` | Investigate stuck Symphony and Codex runs through logs and session ids. | Port into a Cycle troubleshooting doc or optional skill pack. |
| `land` | Monitor PR conflicts/checks/reviews and squash-merge when ready. | Keep optional. Cycle policy may call this a merge-lane skill, but Homebrew should not install it into user repos by default. |
| `linear` | Use Symphony's `linear_graphql` tool during app-server sessions. | Replace with Cycle-owned Linear APIs for core operations; keep optional for raw operator debugging. |
| `pull` | Merge latest `origin/main` into a branch and resolve conflicts. | Useful optional agent guidance. Not a core Cycle dependency. |
| `push` | Push a branch and create/update a PR. | Useful optional agent guidance. Not a core Cycle dependency. |

The `land` skill also includes `land_watch.py`, a helper for watching PR review
comments, CI, and head updates. A Cycle version would need to be rewritten
around Cycle concepts, public paths, and documented operator consent.

## Global Skills Found

Relevant global skills in the current operator environment include:

| Skill | Purpose | Cycle recommendation |
| --- | --- | --- |
| `cycle-mvp-builder` | Guides product ideation, Cycle-managed Linear/GitHub resource creation, and repo `WORKFLOW.md` setup. | Good candidate for a separate Cycle operator skill, not a default CLI dependency. |
| `linear-decision-issues` | Creates or rewrites Linear issues so they are implementation-ready. | Useful upstream workflow skill. Keep optional and document as recommended for issue authoring. |
| `plan-reviewer` | Reviews implementation plans before coding. | Optional quality gate. |
| `new-once-app` and `once-rails-app` | Host-specific app deployment guidance. | Do not include in public Cycle install; too machine-specific. |

## Install Policy

Homebrew installs the Cycle CLI only. It must not write into `~/.codex`, repo
`.codex/skills`, global skill directories, or any other agent behavior directory.

No Cycle install path may mutate Codex skills unless the operator runs a
dedicated skill command or performs a documented manual install. If Cycle later
adds such a command, it must show the target path and requested changes before
writing files, and it must require explicit confirmation unless the operator
passes a deliberate non-interactive flag.

Reasons:

- Skills are agent/operator guidance, not core Cycle runtime dependencies.
- Some skills are machine-specific or workflow-specific.
- Public install should avoid mutating user agent configuration silently.
- Skill installation may require user consent and may change how agents behave.

## Roadmap Command Shape

Skill commands are roadmap-only in the current release. The public CLI does not
implement them yet, and docs must not imply that they are available today.

Add an explicit optional command later:

```sh
cycle skills list
cycle skills install recommended
cycle skills install cycle-ops
```

That command should:

- show exactly which skills will be installed
- ask for confirmation unless a non-interactive flag is passed
- install into a clear user-owned location
- never overwrite local skill edits without a backup or explicit flag
- distinguish public Cycle skills from machine-local operator skills
- avoid copying private paths, local service names, secrets, logs, or
  machine-specific deployment assumptions into public skill content

## Public Cycle Skill Pack

The first public skill pack should be small and Cycle-owned. Candidate skills:

| Skill | Scope |
| --- | --- |
| `cycle-debug` | Inspect Cycle daemon logs, run registry, engine health, failed dispatch reasons, and policy drift evidence. |
| `cycle-linear` | Perform safe Linear issue/project operations using Cycle auth and `cycle:` metadata rules. |
| `cycle-release` | Prepare release artifacts, checksums, docs checks, and Homebrew tap update steps. |
| `cycle-judge-review` | Inspect judge evidence, hashes, review routing decisions, and reviewer handoff notes. |
| `cycle-project-onboarding` | Guide repo onboarding with `cycle:` Linear metadata and repo `WORKFLOW.md` setup. |

`cycle-project-onboarding` is the first repo-contained optional skill source.
It lives under `skills/cycle-project-onboarding` for source-checkout review and
manual installation. It is not active by default, not installed by Homebrew, and
not installed by any Cycle CLI command in the current release.

The existing Symphony and machine-local skills are prototypes only. Public
Cycle skills should be authored from scratch or heavily rewritten so they use
public examples such as `OWNER/REPO`, avoid private machine assumptions, and
preserve the Cycle/Symphony boundary.

## Manual Install Guidance

Until Cycle implements a skill installer, operators can manually install a
public skill pack by copying reviewed skill directories into their own Codex
skill location. Cycle docs should keep that process manual and explicit:

- review the skill source before installation
- choose the target directory intentionally
- back up any existing skill with the same name
- verify that the skill does not contain local secrets or private repository
  names
- remove the skill manually if it changes agent behavior in an unwanted way
