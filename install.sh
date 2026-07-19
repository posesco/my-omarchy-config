#!/usr/bin/env bash

# ==============================================================================
# Omarchy Custom Setup Wizard
# ==============================================================================
# A modular script to install packages, link dotfiles, and manage secrets
# securely via AWS SSM Parameter Store.
# ==============================================================================

set -euo pipefail

# Colors for the UI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"
BACKUP_DIR="${HOME}/.omarchy_config_backup_$(date +%s)"

# Formatted logs
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Initialize environment
setup_environment() {
    mkdir -p "${DOTFILES_DIR}"
}

# Check and install AUR helper (yay)
check_yay() {
    if ! command -v yay &> /dev/null; then
        log_info "'yay' not found. Do you want to install it now? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log_info "Installing yay..."
            sudo pacman -S --needed base-devel git
            git clone https://aur.archlinux.org/yay.git /tmp/yay
            (cd /tmp/yay && makepkg -si --noconfirm)
            rm -rf /tmp/yay
        else
            log_error "'yay' is required to install AUR packages. Aborting."
            exit 1
        fi
    fi
}

# Process templates and replace secrets from AWS SSM.
# Accepts both directories and individual files.
process_templates() {
    local target="$1"

    if [ -d "${target}" ]; then
        find "${target}" -type f -name "*.template" | while read -r template_file; do
            _resolve_template "${template_file}"
        done
    elif [ -f "${target}" ] && [[ "${target}" == *.template ]]; then
        _resolve_template "${target}"
    fi
}

_resolve_template() {
    local template_file="$1"
    local final_file="${template_file%.template}"
    log_info "Processing template: ${template_file} -> ${final_file}"

    cp "${template_file}" "${final_file}"

    local placeholders
    placeholders=$(grep -o '{{SSM:[^}]*}}' "${final_file}" | sort -u || true)

    if [ -z "${placeholders}" ]; then
        return 0
    fi

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is required to resolve SSM secrets. Skipping replacement."
        return 1
    fi

    for placeholder in ${placeholders}; do
        local key
        key=$(echo "${placeholder}" | sed -e 's/{{SSM://' -e 's/}}//')
        local param_name="/omarchy/${key}"

        log_info "Fetching secret from AWS SSM: ${param_name}..."

        local secret_value
        if secret_value=$(aws ssm get-parameter --name "${param_name}" --with-decryption --query "Parameter.Value" --output text 2>/dev/null); then
            if command -v python3 &> /dev/null; then
                # Use python to avoid escaping issues with sed
                python3 -c "
import sys
content = open('${final_file}', 'r').read()
replaced = content.replace('${placeholder}', sys.argv[1])
open('${final_file}', 'w').write(replaced)
" "${secret_value}"
            else
                local escaped_value
                escaped_value=$(echo -n "${secret_value}" | sed -e 's/[\/&]/\\&/g')
                sed -i "s|${placeholder}|${escaped_value}|g" "${final_file}"
            fi
            log_success "Secret '${key}' injected successfully."
        else
            log_error "Could not fetch secret '${param_name}' from AWS SSM."
            log_warn "The file will keep the placeholder. Make sure the secret exists in AWS and your CLI has access."
        fi
    done
}

# Create a symbolic link with a backup of the existing target if present.
# Supports both directories and individual files.
link_dotfile() {
    local source_path="$1"       # Relative to DOTFILES_DIR (can be dir or file)
    local target_path="$2"       # Absolute path in HOME

    local full_source="${DOTFILES_DIR}/${source_path}"

    if [ ! -e "${full_source}" ]; then
        log_warn "Source ${full_source} does not exist in the repository. Skipping."
        return 1
    fi

    # Resolve secret templates before linking
    process_templates "${full_source}"

    # If the target exists and is not already linked to the source
    if [ -e "${target_path}" ] || [ -L "${target_path}" ]; then
        if [ "$(readlink -f "${target_path}")" != "${full_source}" ]; then
            log_info "Backing up ${target_path} to ${BACKUP_DIR}..."
            mkdir -p "${BACKUP_DIR}/$(dirname "${source_path}")"
            mv "${target_path}" "${BACKUP_DIR}/${source_path}"
        else
            log_info "Link for ${target_path} is already configured correctly."
            return 0
        fi
    fi

    # Create the parent directory of the target if it doesn't exist
    mkdir -p "$(dirname "${target_path}")"

    # Create the symlink
    ln -sf "${full_source}" "${target_path}"
    log_success "Linked: ${target_path} -> ${full_source}"
}

# ==============================================================================
# Module Declarations
# ==============================================================================
#
# Each module defines:
#   MODULE_NAMES    - Descriptive name for the wizard
#   MODULE_METHODS  - Package installation command
#   MODULE_TARGETS  - List of "repo_path:home_path" mappings (space-separated)
#                     repo_path is relative to dotfiles/
#                     home_path is relative to $HOME
#                     If empty, the module only installs the package without config.

declare -A MODULE_NAMES
declare -A MODULE_METHODS
declare -A MODULE_TARGETS

# --- Codexbar CLI ---
MODULE_NAMES[codexbar]="Codexbar CLI (Status bar / menu)"
MODULE_METHODS[codexbar]="yay -S --needed codexbar-cli"
MODULE_TARGETS[codexbar]="codexbar:.config/codexbar"

# --- Gentle AI ---
MODULE_NAMES[gentle-ai]="Gentle AI (Local assistant)"
MODULE_METHODS[gentle-ai]="curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh | bash"
MODULE_TARGETS[gentle-ai]="gentle-ai:.config/gentle-ai"

# --- Voxtype ---
MODULE_NAMES[voxtype]="Voxtype (Voice dictation)"
MODULE_METHODS[voxtype]=":" # No installer; assumed already installed
MODULE_TARGETS[voxtype]="voxtype:.config/voxtype"

# --- Waybar ---
MODULE_NAMES[waybar]="Waybar (Custom status bar)"
MODULE_METHODS[waybar]=":" # Ships with Omarchy; only link custom config
MODULE_TARGETS[waybar]="waybar:.config/waybar"

# --- Terraform ---
MODULE_NAMES[terraform]="Terraform (IaC)"
MODULE_METHODS[terraform]="sudo pacman -S --needed terraform"
MODULE_TARGETS[terraform]=""

# --- Llama.cpp + llm launcher ---
MODULE_NAMES[llama.cpp]="Llama.cpp + LLM Launcher (Local inference)"
MODULE_METHODS[llama.cpp]="yay -S --needed llama-cpp-git"
MODULE_TARGETS[llama.cpp]="llama-server.conf:.config/llama-server.conf llm:.local/bin/llm"

# Ordered list of modules
MODULES_LIST=("codexbar" "gentle-ai" "voxtype" "waybar" "terraform" "llama.cpp")

# ==============================================================================
# Main Actions
# ==============================================================================

# Import existing local configurations into the repository
import_configs() {
    log_info "Starting import of local configurations..."
    setup_environment

    local imported_any=false

    for mod in "${MODULES_LIST[@]}"; do
        local targets=${MODULE_TARGETS[$mod]}
        if [ -z "${targets}" ]; then
            continue
        fi

        for mapping in ${targets}; do
            local repo_name="${mapping%%:*}"
            local home_rel="${mapping#*:}"
            local local_path="${HOME}/${home_rel}"
            local repo_path="${DOTFILES_DIR}/${repo_name}"

            if [ -e "${local_path}" ]; then
                log_info "Importing ${local_path} -> ${repo_path}..."
                rm -rf "${repo_path}"
                mkdir -p "$(dirname "${repo_path}")"
                cp -R "${local_path}" "${repo_path}"

                # Preserve executable bit for scripts
                if [ -f "${local_path}" ] && [ -x "${local_path}" ]; then
                    chmod +x "${repo_path}"
                fi

                log_success "Imported successfully: ${mod} (${repo_name})"
                imported_any=true
            else
                log_warn "${local_path} not found for ${mod}."
            fi
        done
    done

    if [ "$imported_any" = true ]; then
        echo -e "\n=============================================="
        log_success "Import completed successfully!"
        log_warn "WATCH OUT FOR SECRETS!"
        log_warn "If imported configs contain passwords or tokens:"
        log_warn "1. Copy the original config file to one ending in '.template'."
        log_warn "   (Example: dotfiles/gentle-ai/config.json -> dotfiles/gentle-ai/config.json.template)"
        log_warn "2. Replace the secret in the .template file with: {{SSM:path/to/secret}}"
        log_warn "3. Commit the .template to Git. The installer will rebuild the original using AWS SSM."
        echo -e "==============================================\n"
    else
        log_warn "No local configurations found to import."
    fi
}

# Run the interactive installation wizard
run_wizard() {
    setup_environment
    check_yay

    echo -e "\n=============================================="
    echo -e "       Omarchy Custom Setup Wizard"
    echo -e "==============================================\n"
    log_info "Select what you want to install/configure:"

    local selections=()

    for mod in "${MODULES_LIST[@]}"; do
        echo -e "\nDo you want to install/configure ${MODULE_NAMES[$mod]}? (y/n)"
        read -r opt
        if [[ "$opt" =~ ^[Yy]$ ]]; then
            selections+=("$mod")
        fi
    done

    if [ ${#selections[@]} -eq 0 ]; then
        log_warn "No modules selected. Exiting."
        exit 0
    fi

    echo -e "\n=============================================="
    log_info "Starting installation and configuration..."
    echo -e "==============================================\n"

    for mod in "${selections[@]}"; do
        log_info "Processing: ${MODULE_NAMES[$mod]}..."

        # 1. Run installation
        local cmd=${MODULE_METHODS[$mod]}
        if [ "${cmd}" != ":" ]; then
            log_info "Running command: $cmd"
            if eval "$cmd"; then
                log_success "${MODULE_NAMES[$mod]} installed successfully."
            else
                log_error "Failed to install ${MODULE_NAMES[$mod]}."
                continue
            fi
        fi

        # 2. Configure dotfiles if targets are defined
        local targets=${MODULE_TARGETS[$mod]}
        if [ -n "${targets}" ]; then
            for mapping in ${targets}; do
                local repo_name="${mapping%%:*}"
                local home_rel="${mapping#*:}"
                log_info "Setting up link: ${repo_name} -> ~/${home_rel}"
                link_dotfile "${repo_name}" "${HOME}/${home_rel}"
            done
        fi
    done

    echo -e "\n=============================================="
    log_success "Process completed successfully!"
    if [ -d "${BACKUP_DIR}" ]; then
        log_info "Backups of previous configurations were saved to: ${BACKUP_DIR}"
    fi
    echo -e "==============================================\n"
}

# ==============================================================================
# Script Entry Point
# ==============================================================================

show_help() {
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  --import    Import current local configurations into the repository"
    echo "  --install   Run the interactive installation wizard (default)"
    echo "  --help      Show this help message"
}

case "${1:-}" in
    --import)
        import_configs
        ;;
    --install|"")
        run_wizard
        ;;
    --help)
        show_help
        ;;
    *)
        log_error "Invalid option: ${1:-}"
        show_help
        exit 1
        ;;
esac
