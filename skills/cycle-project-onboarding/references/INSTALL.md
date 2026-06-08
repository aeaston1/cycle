# Cycle Project Onboarding Runbook

This runbook guides an agent through onboarding one GitHub repository and one
Linear project into Cycle. It assumes the operator has already installed the
Cycle CLI. All external writes require explicit operator confirmation.

## Inputs To Establish

Before creating or updating anything, identify:

- GitHub owner and repository name, such as `OWNER/REPO`.
- Canonical repository URL, such as `https://github.com/OWNER/REPO.git`.
- Desired GitHub repository visibility.
- Local source path, if an existing local checkout should be connected.
- Desired remote behavior, such as leave unchanged, add `origin`, or update an
  existing remote after confirmation.
- Linear workspace, team, and project name.
- Linear project field that holds project text, usually description or content.
- Whether the operator wants the agent to create missing resources or only
  report exact manual steps.

## Read-Only Checks

Run checks before any write:

```sh
cycle doctor
cycle linear configure --print
gh --version
gh auth status
gh repo view OWNER/REPO
cycle project opt-in --repo https://github.com/OWNER/REPO.git
```

Use the Linear connector or available Linear tools to search for an existing
project by name, team, and URL. Inspect the project description and content for
`cycle:` metadata.

## Stop And Report Matrix

| Condition | Action |
| --- | --- |
| `cycle` is missing or `cycle doctor` fails on required commands | Stop. Report the missing prerequisite and the exact command output. Do not create GitHub or Linear resources. |
| Linear auth is missing | Stop before Linear discovery or writes. Report `cycle linear configure --print` and ask the operator to configure auth. |
| `gh` is missing | Stop before GitHub writes. Report that GitHub repo creation or lookup needs `gh` or another explicit GitHub tool. |
| GitHub auth is missing or insufficient | Stop before GitHub writes. Report `gh auth status` and ask the operator to authenticate or choose manual GitHub creation. |
| GitHub repo is missing | Ask for explicit creation confirmation using the checklist below. Do not create it from inferred defaults. |
| Linear project is missing | Ask for explicit creation confirmation using the checklist below. Do not create it from inferred defaults. |
| GitHub or Linear permission is insufficient | Stop. Report the denied operation and the target owner, repo, workspace, team, or project. |
| Existing Linear metadata has an unmarked `cycle:` block | Do not replace it silently. Show the current block and ask whether to replace it with the managed block. |
| Existing Linear metadata has multiple `cycle:` blocks | Stop. Report the duplicate blocks and ask the operator which block should be authoritative. |
| `cycle project discover --limit 10` reports invalid metadata or workflow | Stop after reporting the exact Cycle error. Do not guess a repo workflow fix unless the operator asks. |

## Pre-Write Confirmation

Before any GitHub or Linear mutation, restate this checklist and wait for clear
operator confirmation:

- GitHub target: `OWNER/REPO`.
- GitHub visibility.
- Local source path or empty repository behavior.
- Remote behavior for the local checkout.
- Linear workspace, team, and project name.
- Linear field to update: description or content.
- Exact action and tool, such as create GitHub repo, create Linear project, or
  update Linear project metadata.
- Exact metadata block that will be written.
- Expected verification command and success result.

If any value is unknown, ask for it instead of choosing a default that creates
or updates an external resource.

## Managed Cycle Metadata

Generate the metadata with:

```sh
cycle project opt-in --repo https://github.com/OWNER/REPO.git
```

When adding new metadata to a Linear project, use one managed block:

````markdown
<!-- cycle metadata start -->
```yaml
cycle:
  enabled: true
  repo: https://github.com/OWNER/REPO.git
```
<!-- cycle metadata end -->
````

Safe update rules:

- Preserve all unrelated Linear project text.
- If the managed markers already exist, replace only the content between them.
- If no `cycle:` metadata exists, append the managed block to the chosen Linear
  project field.
- If one unmarked `cycle:` block exists, show it to the operator and ask before
  replacing it with the managed block.
- If multiple `cycle:` blocks exist, stop and ask which block is authoritative.
- Do not add secrets, local paths, tokens, API keys, or private machine details
  to Linear metadata.

## GitHub Resource Handling

If `gh repo view OWNER/REPO` succeeds, use the returned URL as the canonical
repository identity.

If the repository is missing and the operator confirms creation, create it with
the confirmed owner, name, and visibility. Do not infer visibility from local
git config. After creation, rerun:

```sh
gh repo view OWNER/REPO
```

If a local checkout should be connected, inspect remotes before changing them:

```sh
git remote -v
```

Only add or update remotes after explicit confirmation of the remote name and
URL.

## Linear Resource Handling

Search for an existing Linear project before creating one. Match by workspace,
team, project name, and any existing repository references.

If the project exists, inspect description and content before updating metadata.
If the project is missing and the operator confirms creation, create it in the
confirmed workspace and team with the confirmed project name. After creation,
write the managed metadata block only to the confirmed field.

## Final Verification

Run:

```sh
cycle project discover --limit 10
```

If discovery succeeds, optionally run:

```sh
cycle status
```

Report:

- GitHub repository URL.
- Linear project name and URL.
- Whether managed `cycle:` metadata is present.
- `cycle project discover --limit 10` result.
- Any invalid metadata, invalid workflow, missing auth, or permission blocker.

## Manual Scenario Checklist

Review these scenarios when changing the skill:

- All resources exist: read-only checks find GitHub, Linear, and valid metadata;
  final discovery succeeds.
- GitHub repo missing: the agent stops for pre-write confirmation before
  creating it, then verifies with `gh repo view OWNER/REPO`.
- Linear project missing: the agent stops for pre-write confirmation before
  creating it, then verifies the created project and metadata field.
- Metadata missing: the agent appends one managed block and preserves existing
  Linear text.
- Metadata invalid: the agent reports the exact invalid block or discovery
  error and asks before replacing unmarked metadata.
- GitHub auth missing: the agent stops before GitHub writes and reports
  `gh auth status`.
- Linear auth missing: the agent stops before Linear discovery or writes and
  reports `cycle linear configure --print`.
- Discovery still invalid after metadata update: the agent reports the exact
  `cycle project discover --limit 10` error and does not guess workflow fixes.
