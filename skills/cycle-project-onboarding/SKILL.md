---
name: cycle-project-onboarding
description: Guide agents through explicit Cycle project onboarding after the Cycle CLI is installed, including read-only prerequisite checks, GitHub repository existence, Linear project existence, cycle metadata validation, and safe operator-confirmed GitHub or Linear mutations.
---

# Cycle Project Onboarding

Use this skill when an operator wants an agent to onboard a repository and
Linear project into Cycle after the `cycle` binary is installed.

## Workflow

1. Read `references/INSTALL.md` before taking action.
2. Start with read-only checks for Cycle, GitHub CLI, GitHub auth, Linear auth,
   GitHub repository existence, Linear project existence, and current `cycle:`
   metadata.
3. Do not create or update GitHub repositories, Linear projects, or Linear
   metadata until the operator has confirmed the exact target and write action.
4. Preserve unrelated Linear project text. Add or update only the managed Cycle
   metadata block described in the runbook.
5. Verify onboarding with `cycle project discover --limit 10` and summarize the
   result with any remaining blocker.

## Boundaries

- Do not add Cycle CLI write behavior; this is agent guidance only.
- Do not install skills into `~/.codex`, repo `.codex/skills`, or any other
  agent behavior directory.
- Do not stop, restart, replace, or mutate Symphony services.
- Do not commit secrets, local state, logs, engine checkouts, release archives,
  or machine-local config.
- Use placeholder examples such as `OWNER/REPO` and
  `https://github.com/OWNER/REPO.git`.
