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

# Process templates and replace secrets from AWS SSM.
process_templates() {
    local target="$1"
    local status=0

    if [ -d "${target}" ]; then
        while IFS= read -r -d '' template_file; do
            if ! _resolve_template "${template_file}"; then
                status=1
            fi
        done < <(find "${target}" -type f -name '*.template' -print0)
    elif [ -f "${target}" ] && [[ "${target}" == *.template ]]; then
        if ! _resolve_template "${target}"; then
            status=1
        fi
    fi

    return "${status}"
}

_resolve_template() {
    local template_file="$1"
    local final_file="${template_file%.template}"
    local status=0
    log_info "Processing template: ${template_file} -> ${final_file}"

    if [ -e "${final_file}" ] || [ -L "${final_file}" ]; then
        local final_rel="${final_file#"${SCRIPT_DIR}/"}"
        backup_target "${final_file}" "repository/${final_rel}" || return 1
        if [ ! -f "${final_file}" ] || [ -L "${final_file}" ]; then
            rm -rf -- "${final_file}" || return 1
        fi
    fi
    cp -- "${template_file}" "${final_file}" || return 1

    local -a placeholders=()
    mapfile -t placeholders < <(grep -o '{{SSM:[^}]*}}' "${final_file}" | sort -u || true)

    if [ "${#placeholders[@]}" -eq 0 ]; then
        return 0
    fi

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is required to resolve SSM secrets. The generated file retains its placeholders."
        return 1
    fi

    local placeholder key param_name secret_value
    for placeholder in "${placeholders[@]}"; do
        key=${placeholder#'{{SSM:'}
        key=${key%'}}'}
        param_name="/omarchy/${key}"

        log_info "Fetching secret from AWS SSM: ${param_name}..."

        if ! secret_value=$(aws ssm get-parameter --name "${param_name}" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null); then
            log_error "Could not fetch secret '${param_name}' from AWS SSM."
            log_warn "The file will keep the placeholder. Make sure the secret exists in AWS and your CLI has access."
            status=1
            continue
        fi

        if command -v python3 &> /dev/null; then
            if ! python3 - "${final_file}" "${placeholder}" "${secret_value}" <<'PY'
import sys

path, placeholder, secret = sys.argv[1:]
with open(path, "r+", encoding="utf-8") as output:
    content = output.read().replace(placeholder, secret)
    output.seek(0)
    output.write(content)
    output.truncate()
PY
            then
                log_error "Could not inject secret '${key}' into ${final_file}."
                status=1
                continue
            fi
        else
            local escaped_value
            escaped_value=$(printf '%s' "${secret_value}" | sed -e 's/[\/&]/\\&/g')
            if ! sed -i "s|${placeholder}|${escaped_value}|g" "${final_file}"; then
                log_error "Could not inject secret '${key}' into ${final_file}."
                status=1
                continue
            fi
        fi

        log_success "Secret '${key}' injected successfully."
    done

    return "${status}"
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

    if ! process_templates "${full_source}"; then
        log_error "Template processing failed for ${full_source}; the link was not changed."
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
            if [[ "${source_path}" == "bash_aliases" ]]; then
                _ensure_bashrc_sources "${target_path}"
            fi
            return 0
        fi

        backup_target "${target_path}" "home/${target_rel}" || return 1
        rm -rf -- "${target_path}" || return 1
    fi

    mkdir -p -- "$(dirname "${target_path}")" || return 1
    ln -s -- "${full_source}" "${target_path}" || return 1
    log_success "Linked: ${target_path} -> ${full_source}"

    if [[ "${source_path}" == "bash_aliases" ]]; then
        _ensure_bashrc_sources "${target_path}"
    fi
}

_ensure_bashrc_sources() {
    local aliases_path="$1"
    local bashrc="${HOME}/.bashrc"
    local source_line="[[ -f \"${aliases_path}\" ]] && source \"${aliases_path}\""

    if grep -qF "${aliases_path}" "${bashrc}" 2>/dev/null; then
        log_info ".bashrc already sources ${aliases_path}."
        return 0
    fi

    if [ -L "${bashrc}" ]; then
        local resolved_bashrc
        resolved_bashrc=$(readlink -f -- "${bashrc}" 2>/dev/null || true)
        backup_target "${bashrc}" "home/.bashrc" || return 1
        if [ -z "${resolved_bashrc}" ] || [ ! -f "${resolved_bashrc}" ]; then
            log_error "Refusing to append through broken or non-file .bashrc symlink: ${bashrc}"
            return 1
        fi
        backup_target "${resolved_bashrc}" "symlink-targets/bashrc" || return 1
    elif [ -e "${bashrc}" ]; then
        backup_target "${bashrc}" "home/.bashrc" || return 1
    fi

    if ! printf '\n# Custom aliases managed by my-omarchy-config\n%s\n' "${source_line}" >> "${bashrc}"; then
        log_error "Could not add the aliases source line to ${bashrc}."
        return 1
    fi
    log_success "Added source line to .bashrc for ${aliases_path}."
}

# Import one local configuration into the repository.
_import_config() {
    local mod="$1"
    local repo_name="$2"
    local local_path="$3"
    local repo_path="$4"

    if [ ! -e "${local_path}" ]; then
        log_warn "${local_path} not found for ${mod}."
        return 1
    fi

    local local_resolved repo_resolved
    if ! local_resolved=$(readlink -f -- "${local_path}"); then
        log_error "Could not resolve ${local_path} for ${mod}."
        return 2
    fi
    repo_resolved=$(readlink -f -- "${repo_path}" 2>/dev/null || true)
    if [ -n "${repo_resolved}" ] && [ "${local_resolved}" = "${repo_resolved}" ]; then
        log_info "Skipping ${local_path}; it already points to ${repo_path}."
        return 1
    fi

    log_info "Importing ${local_path} -> ${repo_path}..."
    if [ -e "${repo_path}" ] || [ -L "${repo_path}" ]; then
        backup_target "${repo_path}" "repository/dotfiles/${repo_name}" || return 2
        rm -rf -- "${repo_path}" || return 2
    fi
    mkdir -p -- "$(dirname "${repo_path}")" || return 2
    if ! cp -aH -- "${local_path}" "${repo_path}"; then
        log_error "Could not import ${local_path} into ${repo_path}."
        return 2
    fi

    log_success "Imported successfully: ${mod} (${repo_name})"
}
