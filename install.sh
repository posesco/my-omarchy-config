#!/usr/bin/env bash

# Omarchy custom setup entry point.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"
MODELS_CONF="${SCRIPT_DIR}/models.conf"

# shellcheck source=lib/runtime.sh
source "${SCRIPT_DIR}/lib/runtime.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/models.sh
source "${SCRIPT_DIR}/lib/models.sh"
# shellcheck source=lib/samba.sh
source "${SCRIPT_DIR}/lib/samba.sh"
# shellcheck source=lib/modules.sh
source "${SCRIPT_DIR}/lib/modules.sh"

runtime_refresh_state

show_help() {
    printf 'Usage: %s [option]\n\n' "$0"
    printf '%s\n' 'Options:'
    printf '%s\n' '  --import    Import current local configurations into the repository'
    printf '%s\n' '  --install   Run the interactive installation wizard (default)'
    printf '%s\n' '  --models    Download local AI models only (skip package install)'
    printf '%s\n' '  --help      Show this help message'
}

main() {
    local workflow
    local final_status=0

    case "${1:-}" in
        --import)
            workflow="import"
            ;;
        --install|"")
            workflow="install"
            ;;
        --models)
            workflow="models"
            ;;
        --help)
            show_help
            return 0
            ;;
        *)
            log_error "Invalid option: ${1:-}"
            show_help
            return 1
            ;;
    esac

    if ! runtime_begin "${workflow}"; then
        return 1
    fi

    case "${workflow}" in
        import) import_configs ;;
        install) run_wizard ;;
        models) download_models ;;
    esac

    runtime_finish || final_status=$?
    trap - ERR
    return "${final_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    main "$@"
fi
