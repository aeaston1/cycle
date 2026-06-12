# Project Metadata Spec

Cycle discovers projects through `cycle:` metadata in the Linear project
description or content field.

## Discovery Rules

Cycle does:

1. List Linear projects visible to the configured Linear API token.
2. Read each project's description and content.
3. Parse the first `cycle:` YAML block.
4. Keep only projects with `enabled: true`.
5. Normalize and validate the repo URL.
6. Store the result in the project registry with source namespace and validation
   status.
7. Validate the discovered project workflow against Cycle global policy and
   record any drift.

Other metadata namespaces do not opt a project into Cycle.

The first `cycle:` block is authoritative. If it is invalid, Cycle reports the
project as invalid rather than scanning later blocks for a replacement. This
keeps stale or duplicated metadata visible instead of silently choosing between
conflicting project definitions.

## Minimal Metadata

```yaml
cycle:
  enabled: true
  repo: https://github.com/OWNER/REPO.git
```

`repo` may omit `.git`; Cycle normalizes it to the canonical Git URL used
internally.

## Recommended Metadata

```yaml
cycle:
  enabled: true
  repo: https://github.com/OWNER/REPO.git
  workflow: WORKFLOW.md
  engines:
    - openai-symphony@main
  policy:
    review_judge: default
  capacity:
    max_concurrent_agents: 2
```

## Fields

| Field | Required | Type | Meaning |
| --- | --- | --- | --- |
| `enabled` | yes | boolean | Project opt-in switch. Only `true` enables discovery. |
| `repo` | yes | string | HTTPS GitHub repository URL. |
| `workflow` | no | string | Repo-relative workflow path. Defaults to `WORKFLOW.md`. |
| `engines` | no | list | Allowed engine refs, such as `openai-symphony@main`. |
| `policy.review_judge` | no | string | Policy profile name. Defaults to Cycle global policy. |
| `capacity.max_concurrent_agents` | no | integer | Project-level cap override. |
| `capacity.max_concurrent_agents_by_state` | no | map | State-level cap overrides. |

Project metadata may select a policy profile, but it should not redefine the
global policy itself. Global policy belongs in Cycle operator config so it can
be validated consistently across projects.

## Validation

Cycle rejects or marks invalid:

- missing `enabled: true`
- missing `repo`
- non-HTTPS repo URLs
- non-GitHub repo URLs in the first public version
- repo URLs with spaces or extra path components
- blank workflow paths
- non-positive capacity values
- `engines` values that are not non-empty strings
- `policy.review_judge` values that are not non-empty strings
- metadata keys containing token, secret, password, or API key wording

Roadmap validation:

- checking engine refs against installed or allowed engines during metadata
  parsing
- checking policy profile names against operator config during metadata parsing
- blocking workflow settings that violate blocking global policy

Invalid projects should not block discovery for other projects. They should
appear in `cycle project discover` and `cycle status` with a clear error.

## Registry Record

Each valid discovered project persists at least:

```yaml
id: linear-project-id
name: Linear project name
slug_id: linear-project-slug
url: Linear project URL
metadata_namespace: cycle
repo_url: https://github.com/OWNER/REPO.git
repo_full_name: OWNER/REPO
workflow_path: WORKFLOW.md
allowed_engines:
  - openai-symphony@main
policy_profile: default
capacity:
  max_concurrent_agents: 2
last_discovered_at: 2026-05-22T00:00:00Z
status: valid
error: null
policy:
  profile: default
  validation: valid
  drift: []
```

When drift exists, the registry stores machine-readable entries with the
setting path, desired value, observed value, severity, and whether propagation is
available.

## CLI Relationship

`cycle project opt-in --repo <url>` should print minimal valid metadata.

`cycle project discover` shows both valid and invalid opted-in projects,
including:

- Linear project name
- metadata namespace
- repo URL
- workflow path
- validation status
- last error

`cycle project discover --raw` prints normalized JSON records for details such
as selected engines, workflow metadata, and policy drift.
