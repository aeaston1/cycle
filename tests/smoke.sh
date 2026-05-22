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

opt_in_output="$("${CYCLE_BIN}" project opt-in --repo https://github.com/OWNER/REPO.git)"
printf '%s\n' "${opt_in_output}" | grep -q 'cycle:' || fail "project opt-in did not print cycle metadata"
printf '%s\n' "${opt_in_output}" | grep -q 'https://github.com/OWNER/REPO.git' || fail "project opt-in did not include repo URL"

"${CYCLE_BIN}" status >/dev/null || true

printf 'smoke: ok\n'
