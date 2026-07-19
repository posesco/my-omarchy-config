#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT
trap ':' ERR
expected_err_trap=$(trap -p ERR)

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

export HOME="${TEST_ROOT}/first home"
export XDG_STATE_HOME="${TEST_ROOT}/absolute state"

# shellcheck source=../install.sh
source "${REPO_DIR}/install.sh"

[[ "$(trap -p ERR)" == "${expected_err_trap}" ]] || fail "sourcing changed the caller ERR trap"
[[ "${STATE_HOME}" == "${XDG_STATE_HOME}" ]] || fail "absolute XDG_STATE_HOME was not accepted"
[[ ! -e "${HOME}" ]] || fail "sourcing created HOME"
[[ ! -e "${XDG_STATE_HOME}" ]] || fail "sourcing created state directories"
declare -F run_wizard download_models link_dotfile >/dev/null || fail "installer modules were not loaded"

show_help >/dev/null
[[ ! -e "${XDG_STATE_HOME}" ]] || fail "help created state directories"

HOME="${HOME}" XDG_STATE_HOME="${XDG_STATE_HOME}" "${REPO_DIR}/install.sh" --help >/dev/null
[[ ! -e "${XDG_STATE_HOME}" ]] || fail "executable help created state directories"
if HOME="${HOME}" XDG_STATE_HOME="${XDG_STATE_HOME}" "${REPO_DIR}/install.sh" --invalid >/dev/null 2>&1; then
    fail "invalid option returned zero"
fi
[[ ! -e "${XDG_STATE_HOME}" ]] || fail "invalid option created state directories"

export HOME="${TEST_ROOT}/second home"
export XDG_STATE_HOME=""
source "${REPO_DIR}/install.sh"

[[ "${STATE_HOME}" == "${HOME}/.local/state" ]] || fail "re-sourcing did not recompute state paths"
[[ "${BACKUP_ROOT}" == "${HOME}/.local/state/my-omarchy-config/backups" ]] || fail "backup root was not recomputed"
[[ -z "${RUN_LOG}" && -z "${BACKUP_DIR}" ]] || fail "re-sourcing retained run state"
[[ "$(trap -p ERR)" == "${expected_err_trap}" ]] || fail "re-sourcing changed the caller ERR trap"
[[ ! -e "${HOME}" ]] || fail "re-sourcing created HOME"

printf 'PASS: source-safe module loading and state refresh\n'
