---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "053608165614"
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
polling:
  interval_ms: 30000
workspace:
  root: /home/symphony_workspaces/cycle
hooks:
  before_run: |
    for cmd in bash git codex mise; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "$cmd is required for Cycle agent runs" >&2
        exit 1
      fi
    done
  after_create: |
    repo="${CYCLE_WORKFLOW_REPOSITORY:-}"
    if [ -z "$repo" ]; then
      echo "CYCLE_WORKFLOW_REPOSITORY must be set to OWNER/REPO for this workflow" >&2
      exit 1
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh repo clone "$repo" . -- --depth 1
    else
      git clone --depth 1 "https://github.com/${repo}.git" .
    fi
  before_remove: |
    repo="${CYCLE_WORKFLOW_REPOSITORY:-}"
    if [ -z "$repo" ]; then
      exit 0
    fi
    branch="$(git branch --show-current 2>/dev/null || true)"
    if [ -z "$branch" ]; then
      exit 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
      exit 0
    fi
    if ! gh auth status >/dev/null 2>&1; then
      exit 0
    fi
    gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[].number' |
      while IFS= read -r pr_number; do
        if [ -n "$pr_number" ]; then
          gh pr close "$pr_number" --repo "$repo" --comment "Closing because the Linear issue for branch $branch entered a terminal state without merge."
        fi
      done
agent:
  max_concurrent_agents: 5
  max_concurrent_agents_by_state:
    Merging: 1
  max_turns: 10
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=low --config 'service_tier="fast"' app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
review_judge:
  enabled: true
  source_state: Human Review
  review_state: Human Review
  proceed_state: Merging
  model: gpt-5.5
  reasoning_effort: xhigh
  service_tier: fast
  policy: very_lenient
  minimum_skip_confidence: low
  hard_require_human_review:
    paths: []
    labels: []
---

You are working on Linear ticket `{{ issue.identifier }}` for the `cycle` repository.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
URL: {{ issue.url }}
Branch: {{ issue.branch_name }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. Work only inside the provided `cycle` workspace copy.
2. Treat `Backlog` as out of scope; wait for a human to move it to `Todo`.
3. Treat `Todo` as queued work; move it to `In Progress` before implementation.
4. Treat `In Progress` as active implementation work.
5. Treat `Human Review` as a waiting state for human review; do not implement new changes while the ticket is there.
6. Treat `Rework` as reviewer-requested changes; inspect feedback before editing.
7. Treat `Merging` as approved work ready to land. Do not create new feature work in `Merging`.
8. Leave `In Review` unused.
9. Keep changes focused on the ticket scope.
10. Do not edit unrelated files or revert existing work unless the ticket explicitly requires it.
11. If blocked by missing credentials, tools, or unclear requirements, stop and report the blocker clearly.
12. Final message must include completed work, validation performed, and any blocker.

## Execution Flow

1. On `Todo`, update the Linear issue state to `In Progress` before making code changes.
2. Run the workflow `before_run` hook. It must validate the Cycle scaffold without installing engines, starting services, or mutating existing Symphony services:
   - required local commands are available
   - `./bin/cycle doctor` passes
   - `tests/smoke.sh` passes
   If any of these fail, stop, add a Linear comment with the exact blocker, and do not continue implementation.
3. Inspect the current repository state:
   - `git status --short`
   - `git branch --show-current`
   - `git rev-parse --short HEAD`
4. Create or reuse a branch for this issue:
   - Prefer the Linear-provided branch name when available.
   - Otherwise use a sanitized branch such as `codex/aea-40-smoke-test-issue`.
   - Start from the current default branch unless there is already useful work in this workspace.
5. Implement the ticket with focused commits.
6. Run relevant validation before publishing:
   - For CLI-only changes, run `tests/smoke.sh`.
   - For docs-only changes, verify links and examples manually.
   - For release-path changes, also review `docs/release.md`, `packaging/homebrew/cycle.rb`, and `.gitignore`.
7. If no code changes are required, update Linear with a concise note and move the issue to `Human Review`.

## PR Creation and Human Review

Before moving an issue to `Human Review`, ensure there is an open PR for the branch when code changed:

1. Confirm the working tree contains only intended changes.
2. Commit all intended changes with a concise message.
3. Push the branch:
   - `git push -u origin HEAD`
   - If the push is rejected because the branch is stale, fetch and merge `origin/main`, resolve conflicts, rerun validation, then push again.
   - Use `--force-with-lease` only after a deliberate local history rewrite.
4. Create or update a PR with `gh`:
   - If no PR exists: `gh pr create --repo "$CYCLE_WORKFLOW_REPOSITORY" --title "<clear title>" --body "<summary, validation, Linear issue>"`
   - If a PR exists: update the title/body if the scope changed.
5. Attach or mention the PR URL in the Linear issue.
6. Move the Linear issue to `Human Review` only after validation passed and the PR is open.

## Rework

When the issue is in `Rework`:

1. Find the existing PR for the branch.
2. Read reviewer feedback before editing:
   - `gh pr view --repo "$CYCLE_WORKFLOW_REPOSITORY" --comments`
   - `gh pr view --repo "$CYCLE_WORKFLOW_REPOSITORY" --json reviews`
   - `gh api repos/${CYCLE_WORKFLOW_REPOSITORY}/pulls/<pr_number>/comments`
3. Address actionable feedback or reply with a clear reason when pushing back.
4. Rerun validation, commit, push, update the PR, and move the issue back to `Human Review`.

## Merging

When the issue is in `Merging`:

1. Find the open PR for the current branch.
2. Confirm the PR is mergeable and has no unresolved actionable review feedback. `Human Review` is the manual approval gate; do not treat an empty GitHub `reviewDecision` as blocking unless branch protection or explicit repo policy requires approval.
3. Confirm required checks are passing:
   - `gh pr checks --repo "$CYCLE_WORKFLOW_REPOSITORY"`
4. If checks fail, inspect logs, fix the issue, rerun validation, commit, and push.
5. If the PR has merge conflicts, merge latest `origin/main` into the branch, resolve conflicts, rerun validation, and push.
6. When checks are green and review feedback is handled, squash-merge:
   - `gh pr merge --repo "$CYCLE_WORKFLOW_REPOSITORY" --squash --delete-branch`
7. Move the Linear issue to `Done` only after the PR is merged.

## Terminal Cleanup

When a ticket enters a terminal state (`Done`, `Canceled`, `Cancelled`, or `Duplicate`), Symphony removes the matching workspace. The `before_remove` hook closes any still-open PR for the workspace branch before deletion. Merged PRs are left alone.
