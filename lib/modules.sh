#!/usr/bin/env bash

declare -Ag MODULE_NAMES=()
declare -Ag MODULE_TARGETS=()
declare -ag MODULES_LIST=("codexbar" "gentle-ai" "voxtype" "waybar" "personal-tools" "branding" "samba")

MODULE_NAMES[codexbar]="Codexbar CLI (Status bar / menu)"
MODULE_TARGETS[codexbar]="codexbar:.config/codexbar"

MODULE_NAMES[gentle-ai]="Gentle AI (Local assistant)"
MODULE_TARGETS[gentle-ai]="gentle-ai:.config/gentle-ai"

MODULE_NAMES[voxtype]="Voxtype (Voice dictation)"
MODULE_TARGETS[voxtype]="voxtype:.config/voxtype"

MODULE_NAMES[waybar]="Waybar (Custom status bar)"
MODULE_TARGETS[waybar]="waybar:.config/waybar"

MODULE_NAMES[personal-tools]="Personal Binaries and Llama Server Config"
MODULE_TARGETS[personal-tools]="bin/llm:.local/bin/llm bin/openweb:.local/bin/openweb bin/screen-posesco:.local/bin/screen-posesco llama-server.conf:.config/llama-server.conf"

MODULE_NAMES[branding]="Branding (Custom screensaver)"
MODULE_TARGETS[branding]="branding:.config/omarchy/branding"

MODULE_NAMES[samba]="Samba (LAN-only pandastic share)"
MODULE_TARGETS[samba]=""

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
        voxtype|waybar|personal-tools|branding)
            return 0
            ;;
        samba)
            install_samba
            ;;
        *)
            log_error "Unknown module: $1"
            return 1
            ;;
    esac
}

run_wizard() {
    setup_environment

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

    for mod in "${selections[@]}"; do
        if [[ "${mod}" == codexbar ]]; then
            if ! check_yay; then
                runtime_add_failure
                return 0
            fi
            break
        fi
    done

    printf '\n==============================================\n'
    log_info "Starting installation and configuration..."
    printf '==============================================\n\n'

    for mod in "${selections[@]}"; do
        log_info "Processing: ${MODULE_NAMES[$mod]}..."

        if _install_module "${mod}"; then
            if [[ "${mod}" == codexbar || "${mod}" == gentle-ai || "${mod}" == samba ]]; then
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

    report_backup_location
    printf '==============================================\n\n'
}
