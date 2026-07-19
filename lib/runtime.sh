#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

runtime_refresh_state() {
    : "${HOME:?HOME must be set}"

    case "${XDG_STATE_HOME:-}" in
        /*) STATE_HOME="${XDG_STATE_HOME}" ;;
        *) STATE_HOME="${HOME}/.local/state" ;;
    esac

    BACKUP_ROOT="${STATE_HOME}/my-omarchy-config/backups"
    LOG_ROOT="${STATE_HOME}/my-omarchy-config/logs"
    BACKUP_DIR=""
    RUN_LOG=""
    RUN_LOG_ACTIVE=0
    RUN_FAILURES=0
    _RUNTIME_TRAP_INSTALLED=0
}

_ensure_run_log() {
    if [ -n "${RUN_LOG}" ]; then
        return 0
    fi

    if ! install -d -m 700 -- "${LOG_ROOT}"; then
        return 1
    fi

    local old_umask
    old_umask=$(umask)
    umask 077
    RUN_LOG=$(mktemp "${LOG_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.log")
    local status=$?
    umask "${old_umask}"

    if [ "${status}" -ne 0 ]; then
        RUN_LOG=""
        return "${status}"
    fi

    chmod 600 -- "${RUN_LOG}"
}

_write_run_log() {
    local level="$1"
    local message="$2"

    if [ "${RUN_LOG_ACTIVE}" -ne 1 ]; then
        return 0
    fi

    if ! _ensure_run_log; then
        printf '[ERROR] Unable to create the persistent installation log under %s.\n' "${LOG_ROOT}" >&2
        return 0
    fi

    message=${message//$'\n'/ }
    if ! printf '%s %-5s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${level}" "${message}" >> "${RUN_LOG}"; then
        printf '[ERROR] Unable to write to installation log %s.\n' "${RUN_LOG}" >&2
    fi
}

_log() {
    local level="$1"
    local color="$2"
    local message="$3"

    printf '%b[%s]%b %s\n' "${color}" "${level}" "${NC}" "${message}"
    _write_run_log "${level}" "${message}"
}

log_info() { _log "INFO" "${BLUE}" "$1"; }
log_success() { _log "OK" "${GREEN}" "$1"; }
log_warn() { _log "WARN" "${YELLOW}" "$1"; }
log_error() { _log "ERROR" "${RED}" "$1" >&2; }

runtime_add_failure() {
    RUN_FAILURES=$((RUN_FAILURES + 1))
}

_runtime_err_trap() {
    local status="$1"
    local command_name="${2:-unknown}"
    local function_name="${3:-main}"
    local source_file="${4:-unknown}"
    local source_line="${5:-unknown}"

    trap - ERR
    _RUNTIME_TRAP_INSTALLED=0

    if [[ ! "${command_name}" =~ ^[[:alnum:]_./:+-]+$ ]]; then
        command_name="shell-command"
    fi

    local context="Unhandled failure: command=${command_name} function=${function_name} source=${source_file} line=${source_line} status=${status}"
    printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "${context}" >&2
    _write_run_log "ERROR" "${context}"
    return "${status}"
}

runtime_install_err_trap() {
    trap '_runtime_err_trap "$?" "${BASH_COMMAND%%[[:space:]]*}" "${FUNCNAME[0]:-main}" "${BASH_SOURCE[0]:-$0}" "${LINENO}"' ERR
    _RUNTIME_TRAP_INSTALLED=1
}

runtime_remove_err_trap() {
    if [ "${_RUNTIME_TRAP_INSTALLED}" -eq 1 ]; then
        # A nested `trap - ERR` restores the inherited workflow trap. Silence it
        # here; main clears it in the caller scope after collecting final status.
        trap '' ERR
        _RUNTIME_TRAP_INSTALLED=0
    fi
}

runtime_begin() {
    local workflow="$1"

    RUN_FAILURES=0
    RUN_LOG=""
    RUN_LOG_ACTIVE=1

    if ! _ensure_run_log; then
        RUN_LOG_ACTIVE=0
        printf '%b[ERROR]%b Unable to create a persistent installation log under %s.\n' "${RED}" "${NC}" "${LOG_ROOT}" >&2
        return 1
    fi

    runtime_install_err_trap
    log_info "Starting ${workflow} workflow."
}

runtime_finish() {
    local status=0
    local failure_label="failures"

    if [ "${RUN_FAILURES}" -eq 1 ]; then
        failure_label="failure"
    fi

    if [ "${RUN_FAILURES}" -gt 0 ]; then
        log_error "Workflow completed with ${RUN_FAILURES} ${failure_label}. Review the messages above."
        status=1
    else
        log_success "Workflow completed successfully."
    fi

    log_info "Installation log: ${RUN_LOG}"
    runtime_remove_err_trap
    RUN_LOG_ACTIVE=0
    return "${status}"
}
