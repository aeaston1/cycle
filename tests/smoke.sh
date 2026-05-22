#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE_BIN="${ROOT_DIR}/bin/cycle"

fail() {
  printf 'smoke: %s\n' "$*" >&2
  exit 1
}

[ -x "${CYCLE_BIN}" ] || fail "missing executable ${CYCLE_BIN}"

bash -n "${CYCLE_BIN}"

"${CYCLE_BIN}" --version >/dev/null
"${CYCLE_BIN}" help >/dev/null
"${CYCLE_BIN}" symphony path >/dev/null

smoke_config_home="$(mktemp -d)"
trap 'rm -rf "${smoke_config_home}"' EXIT
LINEAR_API_KEY=smoke-token XDG_CONFIG_HOME="${smoke_config_home}" "${CYCLE_BIN}" linear configure --from-env >/dev/null
[ -f "${smoke_config_home}/cycle/config.yaml" ] || fail "linear configure did not write config.yaml"
[ ! -f "${smoke_config_home}/cycle/config.env" ] || fail "linear configure wrote legacy config.env"
grep -q 'api_key_env: LINEAR_API_KEY' "${smoke_config_home}/cycle/config.yaml" || fail "config.yaml did not reference LINEAR_API_KEY"

opt_in_output="$("${CYCLE_BIN}" project opt-in --repo https://github.com/OWNER/REPO.git)"
printf '%s\n' "${opt_in_output}" | grep -q 'cycle:' || fail "project opt-in did not print cycle metadata"
printf '%s\n' "${opt_in_output}" | grep -q 'https://github.com/OWNER/REPO.git' || fail "project opt-in did not include repo URL"

"${CYCLE_BIN}" status >/dev/null || true

printf 'smoke: ok\n'
