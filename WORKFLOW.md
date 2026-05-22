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
    - Closed
polling:
  interval_ms: 30000
workspace:
  root: /home/symphony_workspaces/cycle
hooks:
  before_run: |
    if ! command -v mise >/dev/null 2>&1; then
      echo "mise is required to bootstrap the cupld toolchain" >&2
      exit 1
    fi
    mise trust
    mise install
    mise exec -- cargo --version
    mise exec -- rustc --version
    mise exec -- rustfmt --version
  after_create: |
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh repo clone aeaston1/cupld . -- --depth 1
    else
      git clone --depth 1 https://github.com/aeaston1/cupld.git .
    fi
  before_remove: |
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
    gh pr list --repo aeaston1/cupld --head "$branch" --state open --json number --jq '.[].number' |
      while IFS= read -r pr_number; do
        if [ -n "$pr_number" ]; then
          gh pr close "$pr_number" --repo aeaston1/cupld --comment "Closing because the Linear issue for branch $branch entered a terminal state without merge."
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
  minimum_skip_confidence: medium
  hard_require_human_review:
    paths: []
    labels: []
cycle:
  engines:
    allow:
      - openai-symphony@main
  policy_profile: standard
---

You are working on Cycle, a Linear-native control plane for running upstream
OpenAI Symphony engines across many repositories.

Cycle is the control plane. Symphony is the execution engine. Preserve that
boundary in all implementation work. Cycle owns global policy, validation,
drift reporting, and optional propagation; Symphony should only execute the
selected issue/workflow through the chosen engine.

Issue:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Operating Rules

1. Do not modify existing Symphony checkouts or stop/restart existing Symphony
   services unless the operator explicitly asks for that.
2. Keep public repo content free of private owner/repo names, local paths,
   secrets, and machine-specific assumptions. The Homebrew tap command
   `brew install aeaston1/tap/cycle` is the only allowed hardcoded owner/tap
   reference.
3. Keep Cycle-owned behavior separate from `reference/adapted-symphony/`.
   Reference files are source material, not runtime code.
4. Use `cycle:` metadata as the only Cycle project opt-in namespace.
5. Do not silently rewrite project `WORKFLOW.md` files during discovery. Any
   policy propagation must be explicit, auditable, and narrowly scoped.
6. Do not install or update Codex skills as part of the default Cycle install.
   Skills are optional operator guidance only.
7. For docs-only changes, keep docs consistent with the actual scaffold state.
8. For CLI changes, run `tests/smoke.sh`.
9. For service, Homebrew, release, packaging, installer, security, or
   infrastructure changes, expect human review even when automated review judge
   is enabled.

## Handoff

Final responses should include:

- what changed
- validation performed
- any remaining blocker or human-review reason
