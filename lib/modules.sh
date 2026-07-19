#!/usr/bin/env bash

declare -Ag MODULE_NAMES=()
declare -Ag MODULE_TARGETS=()
declare -ag MODULES_LIST=("codexbar" "gentle-ai" "voxtype" "waybar" "terraform" "llama.cpp" "bash-aliases" "branding")

MODULE_NAMES[codexbar]="Codexbar CLI (Status bar / menu)"
MODULE_TARGETS[codexbar]="codexbar:.config/codexbar"

MODULE_NAMES[gentle-ai]="Gentle AI (Local assistant)"
MODULE_TARGETS[gentle-ai]="gentle-ai:.config/gentle-ai"

MODULE_NAMES[voxtype]="Voxtype (Voice dictation)"
MODULE_TARGETS[voxtype]="voxtype:.config/voxtype"

MODULE_NAMES[waybar]="Waybar (Custom status bar)"
MODULE_TARGETS[waybar]="waybar:.config/waybar"

MODULE_NAMES[terraform]="Terraform (IaC)"
MODULE_TARGETS[terraform]=""

MODULE_NAMES[llama.cpp]="Llama.cpp + LLM Launcher (Local inference)"
MODULE_TARGETS[llama.cpp]="llama-server.conf:.config/llama-server.conf llm:.local/bin/llm"

MODULE_NAMES[bash-aliases]="Bash Custom Aliases (Terraform workflows, etc.)"
MODULE_TARGETS[bash-aliases]="bash_aliases:.config/omarchy/bash_aliases"

MODULE_NAMES[branding]="Branding (Custom screensaver)"
MODULE_TARGETS[branding]="branding:.config/omarchy/branding"

check_yay() {
    if command -v yay &> /dev/null; then
        return 0
    fi

    log_info "'yay' not found. Do you want to install it now? (y/n)"
    read -r response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        log_error "'yay' is required to install AUR packages. Aborting."
        return 1
    fi

    log_info "Installing yay..."
    if ! sudo pacman -S --needed base-devel git; then
        log_error "Could not install the packages required to build yay."
        return 1
    fi

    local build_dir
    if ! build_dir=$(mktemp -d); then
        log_error "Could not create a temporary yay build directory."
        return 1
    fi
    if ! git clone https://aur.archlinux.org/yay.git "${build_dir}" ||
        ! (cd "${build_dir}" && makepkg -si --noconfirm); then
        rm -rf -- "${build_dir}"
        log_error "Could not build and install yay."
        return 1
    fi
    rm -rf -- "${build_dir}"
}

_install_module() {
    case "$1" in
        codexbar)
            log_info "Running command: yay -S --needed codexbar-cli"
            yay -S --needed codexbar-cli
            ;;
        gentle-ai)
            log_info "Running command: curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh | bash"
            curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh | bash
            ;;
        voxtype|waybar|bash-aliases|branding)
            return 0
            ;;
        terraform)
            log_info "Running command: sudo pacman -S --needed terraform"
            sudo pacman -S --needed terraform
            ;;
        llama.cpp)
            log_info "Running command: yay -S --needed llama-cpp-git"
            yay -S --needed llama-cpp-git
            ;;
        *)
            log_error "Unknown module: $1"
            return 1
            ;;
    esac
}

import_configs() {
    log_info "Starting import of local configurations..."
    setup_environment

    local imported_any=false
    local failures_before=${RUN_FAILURES}
    local -a mappings=()
    local mod targets mapping repo_name home_rel local_path repo_path import_status

    for mod in "${MODULES_LIST[@]}"; do
        targets=${MODULE_TARGETS[$mod]}
        if [ -z "${targets}" ]; then
            continue
        fi

        read -r -a mappings <<< "${targets}"
        for mapping in "${mappings[@]}"; do
            repo_name=${mapping%%:*}
            home_rel=${mapping#*:}
            local_path="${HOME}/${home_rel}"
            repo_path="${DOTFILES_DIR}/${repo_name}"

            if _import_config "${mod}" "${repo_name}" "${local_path}" "${repo_path}"; then
                imported_any=true
            else
                import_status=$?
                if [ "${import_status}" -gt 1 ]; then
                    runtime_add_failure
                fi
            fi
        done
    done

    if [ "${imported_any}" = true ]; then
        printf '\n==============================================\n'
        if [ "${RUN_FAILURES}" -eq "${failures_before}" ]; then
            log_success "Import completed successfully!"
        else
            log_warn "Import completed with failures."
        fi
        log_warn "WATCH OUT FOR SECRETS!"
        log_warn "If imported configs contain passwords or tokens:"
        log_warn "1. Copy the original config file to one ending in '.template'."
        log_warn "   (Example: dotfiles/gentle-ai/config.json -> dotfiles/gentle-ai/config.json.template)"
        log_warn "2. Replace the secret in the .template file with: {{SSM:path/to/secret}}"
        log_warn "3. Commit the .template to Git. The installer will rebuild the original using AWS SSM."
        printf '==============================================\n\n'
    else
        log_warn "No local configurations found to import."
    fi
    report_backup_location
}

run_wizard() {
    setup_environment
    if ! check_yay; then
        runtime_add_failure
        return 0
    fi

    printf '\n==============================================\n'
    printf '       Omarchy Custom Setup Wizard\n'
    printf '==============================================\n\n'
    log_info "Select what you want to install/configure:"

    local -a selections=()
    local -a mappings=()
    local mod opt targets mapping repo_name home_rel
    for mod in "${MODULES_LIST[@]}"; do
        printf '\nDo you want to install/configure %s? (y/n)\n' "${MODULE_NAMES[$mod]}"
        read -r opt
        if [[ "${opt}" =~ ^[Yy]$ ]]; then
            selections+=("${mod}")
        fi
    done

    if [ "${#selections[@]}" -eq 0 ]; then
        log_warn "No modules selected. Exiting."
        return 0
    fi

    printf '\n==============================================\n'
    log_info "Starting installation and configuration..."
    printf '==============================================\n\n'

    for mod in "${selections[@]}"; do
        log_info "Processing: ${MODULE_NAMES[$mod]}..."

        if _install_module "${mod}"; then
            if [[ "${mod}" == codexbar || "${mod}" == gentle-ai || "${mod}" == terraform || "${mod}" == llama.cpp ]]; then
                log_success "${MODULE_NAMES[$mod]} installed successfully."
            fi
        else
            log_error "Failed to install ${MODULE_NAMES[$mod]}."
            runtime_add_failure
            continue
        fi

        targets=${MODULE_TARGETS[$mod]}
        if [ -n "${targets}" ]; then
            read -r -a mappings <<< "${targets}"
            for mapping in "${mappings[@]}"; do
                repo_name=${mapping%%:*}
                home_rel=${mapping#*:}
                log_info "Setting up link: ${repo_name} -> ~/${home_rel}"
                if ! link_dotfile "${repo_name}" "${HOME}/${home_rel}" "${home_rel}"; then
                    log_error "Failed to configure ${MODULE_NAMES[$mod]} target ~/${home_rel}."
                    runtime_add_failure
                fi
            done
        fi
    done

    download_models
    report_backup_location
    printf '==============================================\n\n'
}
