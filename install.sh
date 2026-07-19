#!/usr/bin/env bash

# ==============================================================================
# Omarchy Custom Setup Wizard
# ==============================================================================
# Un script modular para instalar paquetes, enlazar dotfiles y gestionar secretos
# de forma segura con AWS SSM Parameter Store.
# ==============================================================================

set -euo pipefail

# Colores para la interfaz
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directorios del proyecto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"
BACKUP_DIR="${HOME}/.omarchy_config_backup_$(date +%s)"

# Logs formateados
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Inicializar entorno
setup_environment() {
    mkdir -p "${DOTFILES_DIR}"
}

# Comprobar e instalar AUR helper (yay)
check_yay() {
    if ! command -v yay &> /dev/null; then
        log_info "No se detectó 'yay'. ¿Querés instalarlo ahora? (s/n)"
        read -r response
        if [[ "$response" =~ ^[Ss]$ ]]; then
            log_info "Instalando yay..."
            sudo pacman -S --needed base-devel git
            git clone https://aur.archlinux.org/yay.git /tmp/yay
            (cd /tmp/yay && makepkg -si --noconfirm)
            rm -rf /tmp/yay
        else
            log_error "Se requiere 'yay' para instalar paquetes de AUR. Abortando."
            exit 1
        fi
    fi
}

# Procesar plantillas y reemplazar secretos de AWS SSM
# Acepta tanto directorios como archivos individuales
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
    log_info "Procesando plantilla: ${template_file} -> ${final_file}"

    cp "${template_file}" "${final_file}"

    local placeholders
    placeholders=$(grep -o '{{SSM:[^}]*}}' "${final_file}" | sort -u || true)

    if [ -z "${placeholders}" ]; then
        return 0
    fi

    if ! command -v aws &> /dev/null; then
        log_error "Se requiere 'aws' CLI configurado para resolver secretos de SSM. Saltando reemplazo."
        return 1
    fi

    for placeholder in ${placeholders}; do
        local key
        key=$(echo "${placeholder}" | sed -e 's/{{SSM://' -e 's/}}//')
        local param_name="/omarchy/${key}"

        log_info "Recuperando secreto de AWS SSM: ${param_name}..."

        local secret_value
        if secret_value=$(aws ssm get-parameter --name "${param_name}" --with-decryption --query "Parameter.Value" --output text 2>/dev/null); then
            if command -v python3 &> /dev/null; then
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
            log_success "Secreto '${key}' inyectado correctamente."
        else
            log_error "No se pudo recuperar el secreto '${param_name}' de AWS SSM."
            log_warn "El archivo quedará con el placeholder. Asegurate de que el secreto existe en AWS y que tu CLI tiene acceso."
        fi
    done
}

# Crear enlace simbólico con backup previo si ya existe.
# Soporta tanto directorios como archivos individuales.
link_dotfile() {
    local source_path="$1"       # Relativo a DOTFILES_DIR (puede ser dir o archivo)
    local target_path="$2"       # Ruta absoluta en el HOME

    local full_source="${DOTFILES_DIR}/${source_path}"

    if [ ! -e "${full_source}" ]; then
        log_warn "El origen ${full_source} no existe en el repositorio. Saltando."
        return 1
    fi

    # Procesar plantillas de secretos antes de enlazar
    process_templates "${full_source}"

    # Si el destino existe y no es un link al origen
    if [ -e "${target_path}" ] || [ -L "${target_path}" ]; then
        if [ "$(readlink -f "${target_path}")" != "${full_source}" ]; then
            log_info "Haciendo backup de ${target_path} en ${BACKUP_DIR}..."
            mkdir -p "${BACKUP_DIR}/$(dirname "${source_path}")"
            mv "${target_path}" "${BACKUP_DIR}/${source_path}"
        else
            log_info "El enlace para ${target_path} ya está configurado correctamente."
            return 0
        fi
    fi

    # Crear el directorio padre del destino si no existe
    mkdir -p "$(dirname "${target_path}")"

    # Crear el symlink
    ln -sf "${full_source}" "${target_path}"
    log_success "Enlazado: ${target_path} -> ${full_source}"
}

# ==============================================================================
# Declaración de Módulos
# ==============================================================================
#
# Cada módulo define:
#   MODULE_NAMES    - Nombre descriptivo para el wizard
#   MODULE_METHODS  - Comando de instalación del paquete
#   MODULE_TARGETS  - Lista de mapeos "repo_path:home_path" separados por espacios
#                     repo_path es relativo a dotfiles/
#                     home_path es relativo a $HOME
#                     Si está vacío, el módulo solo instala el paquete sin config.

declare -A MODULE_NAMES
declare -A MODULE_METHODS
declare -A MODULE_TARGETS

# --- Codexbar CLI ---
MODULE_NAMES[codexbar]="Codexbar CLI (Barra de estado/menú)"
MODULE_METHODS[codexbar]="yay -S --needed codexbar-cli"
MODULE_TARGETS[codexbar]="codexbar:.config/codexbar"

# --- Gentle AI ---
MODULE_NAMES[gentle-ai]="Gentle AI (Asistente local)"
MODULE_METHODS[gentle-ai]="curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh | bash"
MODULE_TARGETS[gentle-ai]="gentle-ai:.config/gentle-ai"

# --- Voxtype ---
MODULE_NAMES[voxtype]="Voxtype (Dictado por voz)"
MODULE_METHODS[voxtype]=":" # Sin instalador; se asume ya instalado
MODULE_TARGETS[voxtype]="voxtype:.config/voxtype"

# --- Waybar ---
MODULE_NAMES[waybar]="Waybar (Barra de estado personalizada)"
MODULE_METHODS[waybar]=":" # Viene con Omarchy; solo enlazar la config custom
MODULE_TARGETS[waybar]="waybar:.config/waybar"

# --- Terraform ---
MODULE_NAMES[terraform]="Terraform (IaC)"
MODULE_METHODS[terraform]="sudo pacman -S --needed terraform"
MODULE_TARGETS[terraform]=""

# --- Llama.cpp + llm launcher ---
MODULE_NAMES[llama.cpp]="Llama.cpp + LLM Launcher (Inferencia local)"
MODULE_METHODS[llama.cpp]="yay -S --needed llama-cpp-git"
MODULE_TARGETS[llama.cpp]="llama-server.conf:.config/llama-server.conf llm:.local/bin/llm"

# Lista ordenada de módulos
MODULES_LIST=("codexbar" "gentle-ai" "voxtype" "waybar" "terraform" "llama.cpp")

# ==============================================================================
# Acciones Principales
# ==============================================================================

# Importar configuraciones locales existentes al repositorio
import_configs() {
    log_info "Iniciando importación de configuraciones locales de la máquina..."
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
                log_info "Importando ${local_path} -> ${repo_path}..."
                rm -rf "${repo_path}"
                mkdir -p "$(dirname "${repo_path}")"
                cp -R "${local_path}" "${repo_path}"

                # Preservar el bit de ejecución para scripts
                if [ -f "${local_path}" ] && [ -x "${local_path}" ]; then
                    chmod +x "${repo_path}"
                fi

                log_success "Importado con éxito: ${mod} (${repo_name})"
                imported_any=true
            else
                log_warn "No se encontró ${local_path} para ${mod}."
            fi
        done
    done

    if [ "$imported_any" = true ]; then
        echo -e "\n=============================================="
        log_success "¡Importación completada con éxito!"
        log_warn "¡ATENCIÓN CON LOS SECRETOS!"
        log_warn "Si las configuraciones importadas contienen contraseñas o tokens:"
        log_warn "1. Copiá el archivo original a uno terminado en '.template'."
        log_warn "   (Ejemplo: dotfiles/gentle-ai/config.json -> dotfiles/gentle-ai/config.json.template)"
        log_warn "2. Reemplazá el secreto en el .template con: {{SSM:ruta/al/secreto}}"
        log_warn "3. Subí el .template a Git. El instalador reconstruirá el original usando AWS SSM."
        echo -e "==============================================\n"
    else
        log_warn "No se encontró ninguna configuración local para importar."
    fi
}

# Ejecutar el asistente de instalación interactivo
run_wizard() {
    setup_environment
    check_yay

    echo -e "\n=============================================="
    echo -e "       Omarchy Custom Setup Wizard"
    echo -e "==============================================\n"
    log_info "Seleccioná qué querés instalar/configurar:"

    local selections=()

    for mod in "${MODULES_LIST[@]}"; do
        echo -e "\n¿Querés instalar/configurar ${MODULE_NAMES[$mod]}? (s/n)"
        read -r opt
        if [[ "$opt" =~ ^[Ss]$ ]]; then
            selections+=("$mod")
        fi
    done

    if [ ${#selections[@]} -eq 0 ]; then
        log_warn "No seleccionaste ningún módulo. Saliendo."
        exit 0
    fi

    echo -e "\n=============================================="
    log_info "Iniciando instalación y configuración..."
    echo -e "==============================================\n"

    for mod in "${selections[@]}"; do
        log_info "Procesando: ${MODULE_NAMES[$mod]}..."

        # 1. Ejecutar instalación
        local cmd=${MODULE_METHODS[$mod]}
        if [ "${cmd}" != ":" ]; then
            log_info "Ejecutando comando: $cmd"
            if eval "$cmd"; then
                log_success "${MODULE_NAMES[$mod]} instalado con éxito."
            else
                log_error "Falló la instalación de ${MODULE_NAMES[$mod]}."
                continue
            fi
        fi

        # 2. Configurar dotfiles si tiene targets definidos
        local targets=${MODULE_TARGETS[$mod]}
        if [ -n "${targets}" ]; then
            for mapping in ${targets}; do
                local repo_name="${mapping%%:*}"
                local home_rel="${mapping#*:}"
                log_info "Configurando enlace: ${repo_name} -> ~/${home_rel}"
                link_dotfile "${repo_name}" "${HOME}/${home_rel}"
            done
        fi
    done

    echo -e "\n=============================================="
    log_success "¡Proceso finalizado con éxito!"
    if [ -d "${BACKUP_DIR}" ]; then
        log_info "Los backups de configuraciones anteriores se guardaron en: ${BACKUP_DIR}"
    fi
    echo -e "==============================================\n"
}

# ==============================================================================
# Entrada Principal del Script
# ==============================================================================

show_help() {
    echo "Uso: $0 [opción]"
    echo ""
    echo "Opciones:"
    echo "  --import    Importa las configuraciones locales actuales al repositorio"
    echo "  --install   Ejecuta el asistente de instalación interactivo (por defecto)"
    echo "  --help      Muestra esta ayuda"
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
        log_error "Opción no válida: ${1:-}"
        show_help
        exit 1
        ;;
esac
