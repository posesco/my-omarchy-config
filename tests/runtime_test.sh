#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -qF -- "${expected}" "${file}" || fail "${file} does not contain ${expected}"
}

export HOME="${TEST_ROOT}/home with spaces"
export XDG_STATE_HOME="${TEST_ROOT}/state with spaces"
mkdir -p "${HOME}"

# shellcheck source=../install.sh
source "${REPO_DIR}/install.sh"

[[ ! -e "${LOG_ROOT}" ]] || fail "source created the log directory"
runtime_begin "logging test"
first_log="${RUN_LOG}"
[[ -f "${first_log}" ]] || fail "runtime did not create a log"
[[ "$(stat -c '%a' "${LOG_ROOT}")" == 700 ]] || fail "log directory mode is not 0700"
[[ "$(stat -c '%a' "${first_log}")" == 600 ]] || fail "log file mode is not 0600"
log_warn "warning record"
log_error "error record"
runtime_finish

assert_file_contains "${first_log}" "INFO  Starting logging test workflow."
assert_file_contains "${first_log}" "WARN  warning record"
assert_file_contains "${first_log}" "ERROR error record"
assert_file_contains "${first_log}" "OK    Workflow completed successfully."
if grep -q $'\033' "${first_log}"; then
    fail "persistent log contains terminal colors"
fi

runtime_begin "second logging test"
second_log="${RUN_LOG}"
runtime_finish
[[ "${first_log}" != "${second_log}" ]] || fail "runtime log names are not unique"

trap_state="${TEST_ROOT}/trap state"
trap_status=0
if HOME="${TEST_ROOT}/trap home" XDG_STATE_HOME="${trap_state}" REPO_DIR="${REPO_DIR}" bash -c '
    set -Eeuo pipefail
    source "${REPO_DIR}/install.sh"
    runtime_begin "trap test"
    fail_with_secret_argument() { false "do-not-log-this-secret"; }
    fail_with_secret_argument
' >/dev/null 2>&1; then
    trap_status=0
else
    trap_status=$?
fi
[[ "${trap_status}" -eq 1 ]] || fail "ERR trap did not preserve exit status 1"

trap_logs=("${trap_state}/my-omarchy-config/logs/"*.log)
[[ "${#trap_logs[@]}" -eq 1 ]] || fail "expected one trap log"
trap_log="${trap_logs[0]}"
[[ "$(grep -c 'Unhandled failure:' "${trap_log}")" -eq 1 ]] || fail "trap error was missing or duplicated"
assert_file_contains "${trap_log}" "command=false"
assert_file_contains "${trap_log}" "function=fail_with_secret_argument"
assert_file_contains "${trap_log}" "source="
assert_file_contains "${trap_log}" "line="
assert_file_contains "${trap_log}" "status=1"
if grep -qF 'do-not-log-this-secret' "${trap_log}"; then
    fail "trap logged command arguments"
fi

handled_state="${TEST_ROOT}/handled state"
HOME="${TEST_ROOT}/handled home" XDG_STATE_HOME="${handled_state}" REPO_DIR="${REPO_DIR}" bash -c '
    set -Eeuo pipefail
    source "${REPO_DIR}/install.sh"
    runtime_begin "handled test"
    if false "handled-secret"; then
        exit 99
    fi
    runtime_finish
' >/dev/null
handled_logs=("${handled_state}/my-omarchy-config/logs/"*.log)
if grep -q 'Unhandled failure:' "${handled_logs[0]}"; then
    fail "handled failure was logged as fatal"
fi

export HOME="${TEST_ROOT}/aggregate home"
export XDG_STATE_HOME="${TEST_ROOT}/aggregate state"
source "${REPO_DIR}/install.sh"
runtime_begin "aggregate test"
aggregate_log="${RUN_LOG}"
runtime_add_failure
if runtime_finish; then
    fail "aggregated failure returned zero"
fi
assert_file_contains "${aggregate_log}" "Workflow completed with 1 failure."
if grep -q 'Unhandled failure:' "${aggregate_log}"; then
    fail "aggregated failure was logged as unhandled"
fi

export HOME="${TEST_ROOT}/main home"
export XDG_STATE_HOME="${TEST_ROOT}/main state"
source "${REPO_DIR}/install.sh"
download_models() { runtime_add_failure; }
trap ':' ERR
expected_err_trap=$(trap -p ERR)
main_status=0
if main --models >/dev/null 2>&1; then
    main_status=0
else
    main_status=$?
fi
[[ "${main_status}" -eq 1 ]] || fail "main did not return the aggregated failure status"
[[ "$(trap -p ERR)" == "${expected_err_trap}" ]] || fail "main did not restore its inherited ERR trap"
trap - ERR

printf 'PASS: persistent logging, ERR trap, and final status\n'
