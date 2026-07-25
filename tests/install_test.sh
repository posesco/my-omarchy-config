#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home with spaces"
export XDG_STATE_HOME="${TEST_ROOT}/state with spaces"
mkdir -p "${HOME}" "${XDG_STATE_HOME}"

# shellcheck source=../install.sh
source "${REPO_DIR}/install.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local expected="$2"
    grep -qF -- "${expected}" "${file}" || fail "${file} does not contain ${expected}"
}

expected_personal_targets="bin/llm:.local/bin/llm bin/openweb:.local/bin/openweb bin/screen-posesco:.local/bin/screen-posesco llama-server.conf:.config/llama-server.conf"
[[ "${MODULE_TARGETS[personal-tools]}" == "${expected_personal_targets}" ]] || fail "personal artifact mappings changed"
[[ " ${MODULES_LIST[*]} " == *" personal-tools "* ]] || fail "personal artifacts module is not registered"
[[ " ${MODULES_LIST[*]} " != *" terraform "* && " ${MODULES_LIST[*]} " != *" llama.cpp "* ]] || fail "removed installer modules are still registered"

# Waybar runs exec values through /bin/sh -c; preserve a spaced config path as one word.
waybar_exec=$(python3 - "${REPO_DIR}/dotfiles/waybar/config.jsonc" <<'PY'
import json
import re
import sys

config = open(sys.argv[1], encoding="utf-8").read()
module = re.search(r'"custom/codexbar"\s*:\s*\{(.*?)\n\s*\}', config, re.DOTALL)
if module is None:
    raise SystemExit("custom/codexbar module not found")
command = re.search(r'"exec"\s*:\s*("(?:\\.|[^"\\])*")', module.group(1))
if command is None:
    raise SystemExit("custom/codexbar exec not found")
print(json.loads(command.group(1)))
PY
)
waybar_config_home="${TEST_ROOT}/waybar config with spaces"
mkdir -p "${waybar_config_home}/waybar"
printf '#!/bin/sh\nprintf "waybar spaced path\\n"\n' > "${waybar_config_home}/waybar/codexbar-waybar.py"
chmod +x "${waybar_config_home}/waybar/codexbar-waybar.py"
waybar_output=$(HOME="${HOME}" XDG_CONFIG_HOME="${waybar_config_home}" /bin/sh -c "${waybar_exec}")
[[ "${waybar_output}" == "waybar spaced path" ]] || fail "Waybar exec did not preserve a spaced XDG_CONFIG_HOME"

# Back up and replace a regular file.
mkdir -p "${HOME}/.config"
printf 'old config\n' > "${HOME}/.config/llama-server.conf"
link_dotfile "llama-server.conf" "${HOME}/.config/llama-server.conf" ".config/llama-server.conf"
[[ -L "${HOME}/.config/llama-server.conf" ]] || fail "regular file target was not linked"
[[ "$(readlink "${HOME}/.config/llama-server.conf")" == "${REPO_DIR}/dotfiles/llama-server.conf" ]] || fail "llama-server.conf mapped to the wrong repository source"

# Back up and replace a directory.
mkdir -p "${HOME}/.config/omarchy/branding"
printf 'old branding\n' > "${HOME}/.config/omarchy/branding/old.txt"
link_dotfile "branding" "${HOME}/.config/omarchy/branding" ".config/omarchy/branding"
[[ -L "${HOME}/.config/omarchy/branding" ]] || fail "directory target was not linked"

# Back up and replace a symlink without dereferencing it.
mkdir -p "${HOME}/.local/bin"
printf '#!/usr/bin/env bash\n' > "${HOME}/old-llm"
ln -s "${HOME}/old-llm" "${HOME}/.local/bin/llm"
link_dotfile "bin/llm" "${HOME}/.local/bin/llm" ".local/bin/llm"
[[ -L "${HOME}/.local/bin/llm" ]] || fail "symlink target was not linked"
[[ "$(readlink "${HOME}/.local/bin/llm")" == "${REPO_DIR}/dotfiles/bin/llm" ]] || fail "llm mapped to the wrong repository source"

link_dotfile "bin/openweb" "${HOME}/.local/bin/openweb" ".local/bin/openweb"
link_dotfile "bin/screen-posesco" "${HOME}/.local/bin/screen-posesco" ".local/bin/screen-posesco"
[[ "$(readlink "${HOME}/.local/bin/openweb")" == "${REPO_DIR}/dotfiles/bin/openweb" ]] || fail "openweb mapped to the wrong repository source"
[[ "$(readlink "${HOME}/.local/bin/screen-posesco")" == "${REPO_DIR}/dotfiles/bin/screen-posesco" ]] || fail "screen-posesco mapped to the wrong repository source"

# Back up a broken symlink as a symlink before replacing it.
ln -s "${HOME}/missing-target" "${HOME}/.config/codexbar"
link_dotfile "codexbar" "${HOME}/.config/codexbar" ".config/codexbar"
[[ -L "${HOME}/.config/codexbar" ]] || fail "broken symlink target was not linked"

backup_dirs=("${XDG_STATE_HOME}/my-omarchy-config/backups/"*)
[[ ${#backup_dirs[@]} -eq 1 && -d "${backup_dirs[0]}" ]] || fail "expected one backup directory"
backup_dir="${backup_dirs[0]}"
assert_file_contains "${backup_dir}/home/.config/llama-server.conf" "old config"
assert_file_contains "${backup_dir}/home/.config/omarchy/branding/old.txt" "old branding"
[[ -L "${backup_dir}/home/.local/bin/llm" ]] || fail "symlink backup was not preserved"
[[ -L "${backup_dir}/home/.config/codexbar" ]] || fail "broken symlink backup was not preserved"

# A relative XDG_STATE_HOME is invalid and must fall back under the absolute HOME.
(
    export HOME="${TEST_ROOT}/relative xdg home"
    export XDG_STATE_HOME="relative-state"
    mkdir -p "${HOME}"
    source "${REPO_DIR}/install.sh"

    [[ "${STATE_HOME}" == "${HOME}/.local/state" ]] || fail "relative XDG_STATE_HOME was not ignored"
    printf 'relative xdg backup\n' > "${HOME}/target"
    backup_target "${HOME}/target" "home/target"
    [[ "${BACKUP_DIR}" == /* ]] || fail "relative-XDG backup path is not absolute"
    case "${BACKUP_DIR}" in
        "${HOME}/.local/state/my-omarchy-config/backups/"*) ;;
        *) fail "relative-XDG backup escaped the HOME state directory" ;;
    esac
    assert_file_contains "${BACKUP_DIR}/home/target" "relative xdg backup"
)

machine_home='/ho''me/posesco'
if ! git -C "${REPO_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "machine-specific path check requires a Git checkout"
fi
if git -C "${REPO_DIR}" grep -nF "${machine_home}"; then
    fail "tracked files still contain a machine-specific home path"
fi

printf 'PASS: personal artifact mappings, portable linking, and backups\n'
