---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_discovery:
    mode: opt_in_descriptions
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
  root: ~/.local/share/cycle/workspaces
agent:
  max_concurrent_agents: 5
  max_turns: 12
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=low --config 'service_tier="fast"' app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
review_judge:
  enabled: true
  source_state: Human Review
  review_state: Human Review
  proceed_state: Merging
  model: gpt-5.5
  reasoning_effort: xhigh
  service_tier: fast
  policy: standard
  minimum_skip_confidence: medium
  hard_require_human_review:
    paths:
      - packaging/**
      - Formula/**
      - docs/release.md
      - docs/service-model.md
      - service/**
      - services/**
      - systemd/**
      - launchd/**
      - "*.service"
      - "*.plist"
      - install.sh
      - scripts/install*
    labels:
      - security
      - infrastructure
      - release
      - service
      - homebrew
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
