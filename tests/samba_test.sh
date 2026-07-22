#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export XDG_STATE_HOME="${TEST_ROOT}/state"
export SAMBA_CONFIG_DIR="${TEST_ROOT}/injected" SAMBA_CONFIG_FILE="${TEST_ROOT}/sudoers"
mkdir -p "${HOME}"

# shellcheck source=../install.sh
source "${REPO_DIR}/install.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

[[ "${SAMBA_CONFIG_DIR}:${SAMBA_CONFIG_FILE}" == "/etc/samba:/etc/samba/smb.conf" ]] || fail "environment replaced the privileged Samba destination"

assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -qF -- "${expected}" "${file}" || fail "${file} does not contain ${expected}"
}

assert_file_excludes() {
    local file="$1"
    local unexpected="$2"
    if grep -qF -- "${unexpected}" "${file}"; then
        fail "${file} unexpectedly contains ${unexpected}"
    fi
}

declare -Ag MOCK_ENABLED=()
declare -Ag MOCK_ACTIVE=()

setup_case() {
    CASE_ROOT=$(mktemp -d "${TEST_ROOT}/case.XXXXXX")
    COMMAND_LOG="${CASE_ROOT}/commands.log"
    EVENT_LOG="${CASE_ROOT}/events.log"
    : > "${COMMAND_LOG}"
    : > "${EVENT_LOG}"

    SAMBA_CONFIG_DIR="${CASE_ROOT}/etc/samba"
    SAMBA_CONFIG_FILE="${SAMBA_CONFIG_DIR}/smb.conf"
    SAMBA_SHARE_PATH="${CASE_ROOT}/srv/pandastic"
    SAMBA_TEMPLATE="${REPO_DIR}/system/samba/smb.conf.template"
    SAMBA_CONFIG_BACKUP=""
    SAMBA_CONFIG_CHANGED=0
    SAMBA_CONFIG_HAD_EXISTING=0

    PACKAGE_SAMBA=1
    PACKAGE_UFW=1
    USER_PRESENT=1
    SHARE_OWNER="mordecai"
    SHARE_GROUP="mordecai"
    PASSDB_PRESENT=0
    SMBPASSWD_CALLS=0
    UFW_ACTIVE=1
    UFW_BROAD_UDP=0
    UFW_BROAD_TCP=0
    UFW_LAN_UDP=0
    UFW_LAN_TCP=0
    FAIL_CANDIDATE_VALIDATION=0
    FAIL_POST_VALIDATION=0
    FAIL_RESTART_SERVICE=""
    MOCK_ENABLED=([smb.service]=0 [nmb.service]=0)
    MOCK_ACTIVE=([smb.service]=0 [nmb.service]=0)

    mkdir -p "${SAMBA_SHARE_PATH}"
    chmod 0770 "${SAMBA_SHARE_PATH}"
}

pacman() {
    if [[ "$1" == "-Q" ]]; then
        case "$2" in
            samba) [ "${PACKAGE_SAMBA}" -eq 1 ] ;;
            ufw) [ "${PACKAGE_UFW}" -eq 1 ] ;;
            *) return 1 ;;
        esac
        return
    fi

    [[ "$1" == "-S" ]] || return 1
    PACKAGE_SAMBA=1
    PACKAGE_UFW=1
}

getent() {
    [[ "$1" == "passwd" && "$2" == "mordecai" ]] || return 1
    [ "${USER_PRESENT}" -eq 1 ] || return 2
    printf 'mordecai:x:988:988::/nonexistent:/usr/bin/nologin\n'
}

id() {
    [[ "$1" == "-gn" && "$2" == "mordecai" ]] || return 1
    printf 'mordecai\n'
}

useradd() {
    USER_PRESENT=1
}

testparm() {
    [[ "$1" == "-s" ]] || return 1
    printf 'validate:%s\n' "$2" >> "${EVENT_LOG}"
    if [[ "$2" == "${SAMBA_CONFIG_FILE}" ]]; then
        [ "${FAIL_POST_VALIDATION}" -eq 0 ]
    else
        [ "${FAIL_CANDIDATE_VALIDATION}" -eq 0 ]
    fi
}

pdbedit() {
    [ "${PASSDB_PRESENT}" -eq 1 ]
}

smbpasswd() {
    local first_entry second_entry
    [[ "$1" == "-a" && "$2" == "mordecai" ]] || return 1
    IFS= read -r first_entry
    IFS= read -r second_entry
    [[ "${first_entry}" == "${second_entry}" ]] || return 1
    PASSDB_PRESENT=1
    SMBPASSWD_CALLS=$((SMBPASSWD_CALLS + 1))
}

ufw() {
    local argument protocol=""

    if [[ "$1" == "status" ]]; then
        if [ "${UFW_ACTIVE}" -eq 1 ]; then
            printf 'Status: active\n'
        else
            printf 'Status: inactive\n'
            return 0
        fi
        [ "${UFW_BROAD_UDP}" -eq 0 ] || printf '137,138/udp ALLOW IN Anywhere\n'
        [ "${UFW_BROAD_TCP}" -eq 0 ] || printf '139,445/tcp ALLOW IN Anywhere\n'
        [ "${UFW_LAN_UDP}" -eq 0 ] || printf '137,138/udp ALLOW IN 192.168.1.0/24\n'
        [ "${UFW_LAN_TCP}" -eq 0 ] || printf '139,445/tcp ALLOW IN 192.168.1.0/24\n'
        return 0
    fi

    if [[ "$1" == "show" && "$2" == "added" ]]; then
        [ "${UFW_BROAD_UDP}" -eq 0 ] || printf 'ufw allow 137,138/udp\n'
        [ "${UFW_BROAD_TCP}" -eq 0 ] || printf 'ufw allow 139,445/tcp\n'
        [ "${UFW_LAN_UDP}" -eq 0 ] || printf 'ufw allow from 192.168.1.0/24 to any port 137,138 proto udp\n'
        [ "${UFW_LAN_TCP}" -eq 0 ] || printf 'ufw allow from 192.168.1.0/24 to any port 139,445 proto tcp\n'
        return 0
    fi

    if [[ "$1" == "--force" && "$2" == "delete" && "$3" == "allow" ]]; then
        case "$4" in
            137,138/udp) UFW_BROAD_UDP=0 ;;
            139,445/tcp) UFW_BROAD_TCP=0 ;;
            *) return 1 ;;
        esac
        return 0
    fi

    [[ "$1" == "allow" ]] || return 1
    for argument in "$@"; do
        case "${argument}" in
            udp|tcp) protocol="${argument}" ;;
        esac
    done
    case "${protocol}" in
        udp) UFW_LAN_UDP=1 ;;
        tcp) UFW_LAN_TCP=1 ;;
        *) return 1 ;;
    esac
}

systemctl() {
    local action="$1"
    local service="${3:-${2:-}}"

    case "${action}" in
        is-enabled)
            [ "${MOCK_ENABLED[${service}]:-0}" -eq 1 ]
            ;;
        is-active)
            [ "${MOCK_ACTIVE[${service}]:-0}" -eq 1 ]
            ;;
        enable)
            service="$2"
            MOCK_ENABLED[${service}]=1
            ;;
        disable)
            service="$2"
            MOCK_ENABLED[${service}]=0
            ;;
        start)
            service="$2"
            MOCK_ACTIVE[${service}]=1
            ;;
        stop)
            service="$2"
            MOCK_ACTIVE[${service}]=0
            ;;
        restart)
            service="$2"
            [[ "${FAIL_RESTART_SERVICE}" != "${service}" ]]
            ;;
        *) return 1 ;;
    esac
}

_mock_sudo_install() {
    local -a arguments=()
    local owner="" group="" argument

    while [ "$#" -gt 0 ]; do
        argument="$1"
        shift
        case "${argument}" in
            -o)
                owner="$1"
                shift
                ;;
            -g)
                group="$1"
                shift
                ;;
            *) arguments+=("${argument}") ;;
        esac
    done

    command install "${arguments[@]}"
    if [[ " ${arguments[*]} " == *" -d "* && "${arguments[-1]}" == "${SAMBA_SHARE_PATH}" ]]; then
        SHARE_OWNER="${owner}"
        SHARE_GROUP="${group}"
    fi
}

sudo() {
    printf '%q ' "$@" >> "${COMMAND_LOG}"
    printf '\n' >> "${COMMAND_LOG}"

    case "$1" in
        install)
            shift
            _mock_sudo_install "$@"
            ;;
        chown)
            SHARE_OWNER="${2%%:*}"
            SHARE_GROUP="${2#*:}"
            ;;
        stat)
            local target="${@: -1}"
            if [[ "${target}" == "${SAMBA_SHARE_PATH}" ]]; then
                printf '%s:%s:%s\n' "${SHARE_OWNER}" "${SHARE_GROUP}" "$(command stat -c '%a' -- "${target}")"
            else
                printf 'root:root:%s\n' "$(command stat -c '%a' -- "${target}")"
            fi
            ;;
        mv)
            printf 'deploy:%s\n' "${@: -1}" >> "${EVENT_LOG}"
            command "$@"
            ;;
        *) command_name="$1"; shift; "${command_name}" "$@" ;;
    esac
}

test_rendering_and_static_security() (
    setup_case
    local rendered="${CASE_ROOT}/rendered.conf"
    render_samba_config "${rendered}"

    assert_file_contains "${rendered}" "[pandastic]"
    assert_file_contains "${rendered}" "path = /srv/pandastic"
    assert_file_contains "${rendered}" "valid users = mordecai"
    assert_file_contains "${rendered}" "hosts allow = 192.168.1.0/24"
    assert_file_contains "${rendered}" "hosts deny = ALL"
    assert_file_contains "${rendered}" "create mask = 0660"
    assert_file_contains "${rendered}" "directory mask = 0770"
    assert_file_contains "${rendered}" "vfs objects = fruit streams_xattr"
    assert_file_excludes "${rendered}" "guest ok = yes"
)

test_candidate_validation_precedes_deployment() (
    setup_case
    FAIL_CANDIDATE_VALIDATION=1

    if install_samba >/dev/null 2>&1; then
        fail "invalid Samba candidate was accepted"
    fi
    [[ ! -e "${SAMBA_CONFIG_FILE}" ]] || fail "configuration was deployed before candidate validation"
    assert_file_contains "${EVENT_LOG}" "validate:"
    assert_file_excludes "${EVENT_LOG}" "deploy:"
)

test_idempotency_firewall_services_and_password_safety() (
    setup_case
    PACKAGE_SAMBA=0
    PACKAGE_UFW=0
    UFW_BROAD_UDP=1
    UFW_BROAD_TCP=1
    UFW_ACTIVE=0
    local password output_file first_mutations
    password='mock-'"enrollment-value"
    output_file="${CASE_ROOT}/output.log"

    runtime_begin "mocked Samba test" >/dev/null
    install_samba <<< "${password}"$'\n'"${password}" >"${output_file}" 2>&1
    runtime_finish >/dev/null

    [[ "${PACKAGE_SAMBA}" -eq 1 && "${PACKAGE_UFW}" -eq 1 ]] || fail "missing packages were not installed"
    [[ "${UFW_BROAD_UDP}" -eq 0 && "${UFW_BROAD_TCP}" -eq 0 ]] || fail "broad UFW rules were retained"
    [[ "${UFW_LAN_UDP}" -eq 1 && "${UFW_LAN_TCP}" -eq 1 ]] || fail "LAN-only UFW rules were not added"
    [[ "${MOCK_ENABLED[smb.service]}" -eq 1 && "${MOCK_ENABLED[nmb.service]}" -eq 1 ]] || fail "Samba services were not enabled"
    [[ "${MOCK_ACTIVE[smb.service]}" -eq 1 && "${MOCK_ACTIVE[nmb.service]}" -eq 1 ]] || fail "Samba services were not started"
    [[ "${SMBPASSWD_CALLS}" -eq 1 ]] || fail "missing passdb account was not enrolled exactly once"
    assert_file_excludes "${COMMAND_LOG}" "ufw allow 137,138/udp"
    assert_file_excludes "${COMMAND_LOG}" "ufw allow 139,445/tcp"
    assert_file_contains "${COMMAND_LOG}" "ufw allow from 192.168.1.0/24"
    assert_file_contains "${output_file}" "UFW is inactive. Rules were prepared"
    assert_file_excludes "${COMMAND_LOG}" "${password}"
    assert_file_excludes "${output_file}" "${password}"
    assert_file_excludes "${RUN_LOG}" "${password}"
    if git -C "${REPO_DIR}" grep -qF -- "${password}"; then
        fail "mock Samba password was persisted in tracked project files"
    fi

    : > "${COMMAND_LOG}"
    install_samba >/dev/null 2>&1
    first_mutations=$(grep -Ec 'pacman -S|useradd|chown|chmod|ufw (allow|--force)|systemctl (enable|start|restart)|smbpasswd' "${COMMAND_LOG}" || true)
    [[ "${first_mutations}" -eq 0 ]] || fail "idempotent rerun repeated state-changing commands"
    [[ "${SMBPASSWD_CALLS}" -eq 1 ]] || fail "idempotent rerun prompted for a Samba password"
)

test_non_recursive_share_permissions() (
    setup_case
    printf 'existing data\n' > "${SAMBA_SHARE_PATH}/existing.txt"
    chmod 0600 "${SAMBA_SHARE_PATH}/existing.txt"
    chmod 0755 "${SAMBA_SHARE_PATH}"
    SHARE_OWNER="root"
    SHARE_GROUP="root"
    PASSDB_PRESENT=1

    install_samba >/dev/null 2>&1
    [[ "$(command stat -c '%a' -- "${SAMBA_SHARE_PATH}")" == "770" ]] || fail "share root mode was not corrected"
    [[ "$(command stat -c '%a' -- "${SAMBA_SHARE_PATH}/existing.txt")" == "600" ]] || fail "existing share content was recursively modified"
    if grep -Eq '(chown|chmod).* -R( |$)' "${COMMAND_LOG}"; then
        fail "recursive share permission command was used"
    fi
)

test_post_deploy_validation_rollback() (
    setup_case
    mkdir -p "${SAMBA_CONFIG_DIR}"
    printf 'old configuration\n' > "${SAMBA_CONFIG_FILE}"
    chmod 0644 "${SAMBA_CONFIG_FILE}"
    PASSDB_PRESENT=1
    FAIL_POST_VALIDATION=1

    if install_samba >/dev/null 2>&1; then
        fail "post-deploy validation failure returned success"
    fi
    assert_file_contains "${SAMBA_CONFIG_FILE}" "old configuration"
    backup_files=("${SAMBA_CONFIG_FILE}.my-omarchy-config."*.bak)
    [[ "${#backup_files[@]}" -eq 1 && -f "${backup_files[0]}" ]] || fail "existing Samba configuration was not backed up"
)

test_service_failure_rollback() (
    setup_case
    mkdir -p "${SAMBA_CONFIG_DIR}"
    printf 'service-safe old configuration\n' > "${SAMBA_CONFIG_FILE}"
    chmod 0644 "${SAMBA_CONFIG_FILE}"
    PASSDB_PRESENT=1
    MOCK_ENABLED=([smb.service]=1 [nmb.service]=1)
    MOCK_ACTIVE=([smb.service]=1 [nmb.service]=1)
    FAIL_RESTART_SERVICE="smb.service"

    if install_samba >/dev/null 2>&1; then
        fail "service restart failure returned success"
    fi
    assert_file_contains "${SAMBA_CONFIG_FILE}" "service-safe old configuration"
    [[ "${MOCK_ENABLED[smb.service]}" -eq 1 && "${MOCK_ACTIVE[smb.service]}" -eq 1 ]] || fail "prior service state was not retained"
)

test_module_dispatch() (
    local dispatched=0
    install_samba() { dispatched=1; }
    _install_module samba
    [[ "${dispatched}" -eq 1 ]] || fail "Samba module dispatch did not invoke install_samba"
)

[[ " ${MODULES_LIST[*]} " == *" samba "* ]] || fail "Samba is not registered as an opt-in module"
[[ -z "${MODULE_TARGETS[samba]}" ]] || fail "Samba was incorrectly routed through dotfile linking"
declare -F install_samba >/dev/null || fail "Samba implementation was not loaded"

test_rendering_and_static_security
test_candidate_validation_precedes_deployment
test_idempotency_firewall_services_and_password_safety
test_non_recursive_share_permissions
test_post_deploy_validation_rollback
test_service_failure_rollback
test_module_dispatch

printf 'PASS: mocked Samba rendering, deployment, rollback, firewall, services, and password safety\n'
