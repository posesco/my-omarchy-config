#!/usr/bin/env bash

SAMBA_USER="mordecai"
SAMBA_SHARE_PATH="${SAMBA_SHARE_PATH:-/srv/pandastic}"
SAMBA_LAN_CIDR="192.168.1.0/24"
SAMBA_CONFIG_DIR="/etc/samba"
SAMBA_CONFIG_FILE="${SAMBA_CONFIG_DIR}/smb.conf"
SAMBA_TEMPLATE="${SAMBA_TEMPLATE:-${SCRIPT_DIR}/system/samba/smb.conf.template}"

SAMBA_CONFIG_BACKUP=""
SAMBA_CONFIG_CHANGED=0
SAMBA_CONFIG_HAD_EXISTING=0
declare -Ag SAMBA_SERVICE_ENABLED_BEFORE=()
declare -Ag SAMBA_SERVICE_ACTIVE_BEFORE=()

_samba_require_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "${command_name}" >/dev/null 2>&1; then
            log_error "Samba setup requires '${command_name}', but it is unavailable."
            return 1
        fi
    done
}

_samba_ensure_packages() {
    local -a missing=()
    local package

    _samba_require_commands sudo pacman || return 1
    for package in samba ufw; do
        if ! pacman -Q "${package}" >/dev/null 2>&1; then
            missing+=("${package}")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log_info "Samba and UFW packages are already installed."
        return 0
    fi

    log_info "Installing required Samba module packages."
    if ! sudo pacman -S --needed "${missing[@]}"; then
        log_error "Could not install the required Samba module packages."
        return 1
    fi
}

_samba_ensure_user() {
    local passwd_entry shell_path

    if passwd_entry=$(getent passwd "${SAMBA_USER}"); then
        IFS=: read -r _ _ _ _ _ _ shell_path <<< "${passwd_entry}"
        case "${shell_path}" in
            */nologin|*/false) ;;
            *)
                log_error "Existing account '${SAMBA_USER}' has an interactive shell; refusing to repurpose it."
                return 1
                ;;
        esac
        SAMBA_GROUP=$(id -gn "${SAMBA_USER}") || {
            log_error "Could not determine the primary group for '${SAMBA_USER}'."
            return 1
        }
        log_info "Unix account '${SAMBA_USER}' is already present."
        return 0
    fi

    log_info "Creating the dedicated non-login Unix account '${SAMBA_USER}'."
    if ! sudo useradd --system --user-group --shell /usr/bin/nologin "${SAMBA_USER}"; then
        log_error "Could not create Unix account '${SAMBA_USER}'."
        return 1
    fi
    SAMBA_GROUP="${SAMBA_USER}"
}

_samba_ensure_share_root() {
    local state owner group mode

    if sudo test -L "${SAMBA_SHARE_PATH}"; then
        log_error "Share root ${SAMBA_SHARE_PATH} is a symbolic link; refusing to change it."
        return 1
    fi

    if ! sudo test -d "${SAMBA_SHARE_PATH}"; then
        log_info "Creating Samba share root ${SAMBA_SHARE_PATH}."
        if ! sudo install -d -o "${SAMBA_USER}" -g "${SAMBA_GROUP}" -m 0770 -- "${SAMBA_SHARE_PATH}"; then
            log_error "Could not create Samba share root ${SAMBA_SHARE_PATH}."
            return 1
        fi
        return 0
    fi

    if ! state=$(sudo stat -c '%U:%G:%a' -- "${SAMBA_SHARE_PATH}"); then
        log_error "Could not inspect Samba share root ${SAMBA_SHARE_PATH}."
        return 1
    fi
    IFS=: read -r owner group mode <<< "${state}"

    if [[ "${owner}" != "${SAMBA_USER}" || "${group}" != "${SAMBA_GROUP}" ]]; then
        log_info "Correcting ownership on the Samba share root only."
        if ! sudo chown "${SAMBA_USER}:${SAMBA_GROUP}" -- "${SAMBA_SHARE_PATH}"; then
            log_error "Could not correct ownership on Samba share root ${SAMBA_SHARE_PATH}."
            return 1
        fi
    fi
    if [[ "${mode}" != "770" ]]; then
        log_info "Correcting mode on the Samba share root only."
        if ! sudo chmod 0770 -- "${SAMBA_SHARE_PATH}"; then
            log_error "Could not correct mode on Samba share root ${SAMBA_SHARE_PATH}."
            return 1
        fi
    fi
}

render_samba_config() {
    local destination="$1"

    if [ ! -f "${SAMBA_TEMPLATE}" ]; then
        log_error "Samba configuration template is missing: ${SAMBA_TEMPLATE}"
        return 1
    fi
    install -m 0600 -- "${SAMBA_TEMPLATE}" "${destination}"
}

_samba_validate_config() {
    local config_path="$1"

    if ! testparm -s "${config_path}" >/dev/null 2>&1; then
        log_error "Samba configuration validation failed for ${config_path}."
        return 1
    fi
}

_samba_config_is_current() {
    local metadata

    sudo test -f "${SAMBA_CONFIG_FILE}" || return 1
    sudo cmp -s -- "$1" "${SAMBA_CONFIG_FILE}" || return 1
    metadata=$(sudo stat -c '%U:%G:%a' -- "${SAMBA_CONFIG_FILE}") || return 1
    [[ "${metadata}" == "root:root:644" ]]
}

_samba_deploy_config() {
    local candidate="$1"
    local staging

    SAMBA_CONFIG_BACKUP=""
    SAMBA_CONFIG_CHANGED=0
    SAMBA_CONFIG_HAD_EXISTING=0

    if _samba_config_is_current "${candidate}"; then
        log_info "Samba configuration is already current."
        return 0
    fi

    if ! sudo install -d -o root -g root -m 0755 -- "${SAMBA_CONFIG_DIR}"; then
        log_error "Could not prepare ${SAMBA_CONFIG_DIR}."
        return 1
    fi

    if sudo test -e "${SAMBA_CONFIG_FILE}" || sudo test -L "${SAMBA_CONFIG_FILE}"; then
        SAMBA_CONFIG_HAD_EXISTING=1
        if ! SAMBA_CONFIG_BACKUP=$(sudo mktemp "${SAMBA_CONFIG_FILE}.my-omarchy-config.XXXXXX.bak"); then
            log_error "Could not allocate a Samba configuration backup."
            return 1
        fi
        if ! sudo rm -f -- "${SAMBA_CONFIG_BACKUP}" ||
            ! sudo cp -a -- "${SAMBA_CONFIG_FILE}" "${SAMBA_CONFIG_BACKUP}"; then
            log_error "Could not back up ${SAMBA_CONFIG_FILE}."
            return 1
        fi
        log_info "Backed up ${SAMBA_CONFIG_FILE} to ${SAMBA_CONFIG_BACKUP}"
    fi

    if ! staging=$(sudo mktemp "${SAMBA_CONFIG_DIR}/.smb.conf.XXXXXX"); then
        log_error "Could not allocate a Samba configuration staging file."
        return 1
    fi
    if ! sudo install -o root -g root -m 0644 -- "${candidate}" "${staging}" ||
        ! sudo mv -f -- "${staging}" "${SAMBA_CONFIG_FILE}"; then
        sudo rm -f -- "${staging}" >/dev/null 2>&1 || true
        log_error "Could not atomically deploy ${SAMBA_CONFIG_FILE}."
        return 1
    fi

    SAMBA_CONFIG_CHANGED=1
    log_success "Deployed validated Samba configuration."
}

_samba_restore_config() {
    local staging

    if [ "${SAMBA_CONFIG_CHANGED}" -ne 1 ]; then
        return 0
    fi

    if [ "${SAMBA_CONFIG_HAD_EXISTING}" -eq 0 ]; then
        sudo rm -f -- "${SAMBA_CONFIG_FILE}"
        log_warn "Removed the newly deployed Samba configuration after failure."
        return 0
    fi

    if ! staging=$(sudo mktemp "${SAMBA_CONFIG_DIR}/.smb.conf.restore.XXXXXX"); then
        log_error "Could not allocate a Samba configuration rollback file."
        return 1
    fi
    if ! sudo rm -f -- "${staging}" ||
        ! sudo cp -a -- "${SAMBA_CONFIG_BACKUP}" "${staging}" ||
        ! sudo mv -f -- "${staging}" "${SAMBA_CONFIG_FILE}"; then
        log_error "Could not restore Samba configuration backup ${SAMBA_CONFIG_BACKUP}."
        return 1
    fi
    log_warn "Restored Samba configuration from ${SAMBA_CONFIG_BACKUP}."
}

_samba_ufw_has_rule() {
    local status="$1"
    local destination="$2"
    local source="$3"
    local line rule_destination action direction rule_source remainder

    while IFS= read -r line; do
        if [[ ("${source}" == "Anywhere" && "${line}" == "ufw allow ${destination}") ||
            "${line}" == "ufw allow from ${source} to any port ${destination%/*} proto ${destination#*/}" ]]; then
            return 0
        fi
        read -r rule_destination action direction rule_source remainder <<< "${line}"
        if [[ "${rule_destination}" == "${destination}" && "${action}" == "ALLOW" &&
            "${direction}" == "IN" && "${rule_source}" == "${source}" ]]; then
            return 0
        fi
    done <<< "${status}"
    return 1
}

_samba_ensure_firewall() {
    local active status port_spec ports protocol attempts
    local -a specs=("137,138/udp" "139,445/tcp")

    if ! active=$(LC_ALL=C sudo ufw status 2>/dev/null); then
        log_error "Could not inspect UFW status; refusing to continue without firewall state."
        return 1
    fi
    status=$(LC_ALL=C sudo ufw show added 2>/dev/null) || { log_error "Could not inspect configured UFW rules; refusing to continue."; return 1; }

    for port_spec in "${specs[@]}"; do
        attempts=0
        while _samba_ufw_has_rule "${status}" "${port_spec}" "Anywhere"; do
            log_warn "Removing broad UFW Samba rule '${port_spec} from Anywhere'."
            if ! sudo ufw --force delete allow "${port_spec}"; then
                log_error "Could not remove broad UFW Samba rule ${port_spec}."
                return 1
            fi
            status=$(LC_ALL=C sudo ufw show added 2>/dev/null) || return 1
            attempts=$((attempts + 1))
            if [ "${attempts}" -ge 10 ]; then
                log_error "Too many duplicate broad UFW rules for ${port_spec}; aborting safely."
                return 1
            fi
        done

        if ! _samba_ufw_has_rule "${status}" "${port_spec}" "${SAMBA_LAN_CIDR}"; then
            ports=${port_spec%/*}
            protocol=${port_spec#*/}
            log_info "Adding LAN-only UFW rule for ${port_spec}."
            if ! sudo ufw allow from "${SAMBA_LAN_CIDR}" to any port "${ports}" proto "${protocol}"; then
                log_error "Could not add LAN-only UFW rule for ${port_spec}."
                return 1
            fi
            status=$(LC_ALL=C sudo ufw show added 2>/dev/null) || return 1
            if ! _samba_ufw_has_rule "${status}" "${port_spec}" "${SAMBA_LAN_CIDR}"; then
                log_error "UFW did not report the expected LAN-only rule for ${port_spec}."
                return 1
            fi
        fi
    done

    if [[ "${active}" == *"Status: inactive"* ]]; then
        log_warn "UFW is inactive. Rules were prepared, but this module will not enable the firewall automatically."
    fi
}

_samba_capture_service_state() {
    local service

    SAMBA_SERVICE_ENABLED_BEFORE=()
    SAMBA_SERVICE_ACTIVE_BEFORE=()
    for service in smb.service nmb.service; do
        if systemctl is-enabled --quiet "${service}"; then
            SAMBA_SERVICE_ENABLED_BEFORE[${service}]=1
        else
            SAMBA_SERVICE_ENABLED_BEFORE[${service}]=0
        fi
        if systemctl is-active --quiet "${service}"; then
            SAMBA_SERVICE_ACTIVE_BEFORE[${service}]=1
        else
            SAMBA_SERVICE_ACTIVE_BEFORE[${service}]=0
        fi
    done
}

_samba_ensure_services() {
    local service

    for service in smb.service nmb.service; do
        if [ "${SAMBA_SERVICE_ENABLED_BEFORE[${service}]}" -eq 0 ]; then
            log_info "Enabling ${service}."
            if ! sudo systemctl enable "${service}"; then
                log_error "Could not enable ${service}."
                return 1
            fi
        fi

        if [ "${SAMBA_SERVICE_ACTIVE_BEFORE[${service}]}" -eq 0 ]; then
            log_info "Starting ${service}."
            if ! sudo systemctl start "${service}"; then
                log_error "Could not start ${service}."
                return 1
            fi
        elif [ "${SAMBA_CONFIG_CHANGED}" -eq 1 ]; then
            log_info "Restarting ${service} for the updated configuration."
            if ! sudo systemctl restart "${service}"; then
                log_error "Could not restart ${service}."
                return 1
            fi
        fi
    done
}

_samba_rollback_services() {
    local service

    for service in smb.service nmb.service; do
        if [ "${SAMBA_SERVICE_ACTIVE_BEFORE[${service}]}" -eq 1 ]; then
            sudo systemctl restart "${service}" >/dev/null 2>&1 || true
        elif systemctl is-active --quiet "${service}"; then
            sudo systemctl stop "${service}" >/dev/null 2>&1 || true
        fi

        if [ "${SAMBA_SERVICE_ENABLED_BEFORE[${service}]}" -eq 0 ] &&
            systemctl is-enabled --quiet "${service}"; then
            sudo systemctl disable "${service}" >/dev/null 2>&1 || true
        fi
    done
}

_samba_ensure_passdb_enrollment() {
    if sudo pdbedit -L -u "${SAMBA_USER}" >/dev/null 2>&1; then
        log_info "Samba account '${SAMBA_USER}' is already enrolled."
        return 0
    fi

    log_info "Samba account '${SAMBA_USER}' needs interactive password enrollment."
    if ! sudo smbpasswd -a "${SAMBA_USER}"; then
        log_error "Could not enroll Samba account '${SAMBA_USER}'."
        return 1
    fi
}

install_samba() {
    local candidate

    _samba_ensure_packages || return 1
    _samba_require_commands cmp getent id install mktemp pdbedit smbpasswd stat systemctl testparm ufw useradd || return 1
    _samba_ensure_user || return 1
    _samba_ensure_share_root || return 1

    if ! candidate=$(mktemp); then
        log_error "Could not create a temporary Samba configuration candidate."
        return 1
    fi
    if ! render_samba_config "${candidate}" || ! _samba_validate_config "${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi

    if ! _samba_ensure_firewall; then
        rm -f -- "${candidate}"
        return 1
    fi

    _samba_capture_service_state
    if ! _samba_deploy_config "${candidate}" || ! _samba_validate_config "${SAMBA_CONFIG_FILE}"; then
        _samba_restore_config || true
        rm -f -- "${candidate}"
        return 1
    fi

    if ! _samba_ensure_passdb_enrollment || ! _samba_ensure_services; then
        _samba_restore_config || true
        _samba_rollback_services
        rm -f -- "${candidate}"
        return 1
    fi

    rm -f -- "${candidate}"
    log_success "Samba share 'pandastic' is configured for ${SAMBA_LAN_CIDR}."
}
