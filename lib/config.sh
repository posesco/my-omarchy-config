#!/usr/bin/env bash

setup_environment() {
    mkdir -p -- "${DOTFILES_DIR}"
}

_ensure_backup_dir() {
    if [ -n "${BACKUP_DIR}" ]; then
        return 0
    fi

    if ! install -d -m 700 -- "${BACKUP_ROOT}"; then
        log_error "Could not create backup root: ${BACKUP_ROOT}"
        return 1
    fi
    if ! BACKUP_DIR=$(mktemp -d "${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX"); then
        BACKUP_DIR=""
        log_error "Could not create a unique backup directory under ${BACKUP_ROOT}."
        return 1
    fi
    log_info "Backup directory: ${BACKUP_DIR}"
}

# Copy an existing path without following symlinks before it is changed or removed.
backup_target() {
    local target_path="$1"
    local backup_rel="$2"

    if [ ! -e "${target_path}" ] && [ ! -L "${target_path}" ]; then
        return 0
    fi

    case "${backup_rel}" in
        ""|/*|..|../*|*/..|*/../*)
            log_error "Unsafe backup path: ${backup_rel}"
            return 1
            ;;
    esac

    _ensure_backup_dir || return 1

    local backup_path="${BACKUP_DIR}/${backup_rel}"
    if [ -e "${backup_path}" ] || [ -L "${backup_path}" ]; then
        log_error "Refusing to overwrite existing backup: ${backup_path}"
        return 1
    fi

    if ! mkdir -p -- "$(dirname "${backup_path}")"; then
        log_error "Could not create backup parent for ${backup_path}."
        return 1
    fi
    if ! cp -a -- "${target_path}" "${backup_path}"; then
        log_error "Could not back up ${target_path} to ${backup_path}."
        return 1
    fi
    log_info "Backed up ${target_path} to ${backup_path}"
}

report_backup_location() {
    if [ -n "${BACKUP_DIR}" ]; then
        log_info "Backups of previous configurations were saved to: ${BACKUP_DIR}"
    fi
}

# Create a symbolic link with a backup of the existing target if present.
link_dotfile() {
    local source_path="$1"
    local target_path="$2"
    local target_rel="$3"
    local full_source="${DOTFILES_DIR}/${source_path}"

    if [ ! -e "${full_source}" ]; then
        log_warn "Source ${full_source} does not exist in the repository. Skipping."
        return 1
    fi

    local resolved_source
    if ! resolved_source=$(readlink -f -- "${full_source}"); then
        log_error "Could not resolve source path: ${full_source}"
        return 1
    fi

    if [ -e "${target_path}" ] || [ -L "${target_path}" ]; then
        if [ "$(readlink -f -- "${target_path}" 2>/dev/null || true)" = "${resolved_source}" ]; then
            log_info "Link for ${target_path} is already configured correctly."
            return 0
        fi

        backup_target "${target_path}" "home/${target_rel}" || return 1
        rm -rf -- "${target_path}" || return 1
    fi

    mkdir -p -- "$(dirname "${target_path}")" || return 1
    ln -s -- "${full_source}" "${target_path}" || return 1
    log_success "Linked: ${target_path} -> ${full_source}"
}
