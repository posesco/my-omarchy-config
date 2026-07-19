#!/usr/bin/env bash

declare -ag MODEL_IDS=()
declare -Ag MODEL_NAMES=()
declare -Ag MODEL_SIZES=()
declare -Ag MODEL_CATEGORIES=()
declare -Ag MODEL_DESTPATHS=()

load_model_registry() {
    MODEL_IDS=()
    MODEL_NAMES=()
    MODEL_SIZES=()
    MODEL_CATEGORIES=()
    MODEL_DESTPATHS=()

    # shellcheck source=../models.conf
    source "${MODELS_CONF}"
}

_model_uses_huggingface() {
    case "$1" in
        parakeet-tdt-0.6b|vosk-small-es) return 1 ;;
        *) return 0 ;;
    esac
}

_download_model_by_id() {
    local model_id="$1"
    local archive

    case "${model_id}" in
        qwen2.5-3b-instruct)
            huggingface-cli download Qwen/Qwen2.5-3B-Instruct-GGUF --include 'qwen2.5-3b-instruct-q4_k_m.gguf' --local-dir "${MODELS_DIR}" --local-dir-use-symlinks false
            ;;
        qwen3.5-4b-super-coder)
            huggingface-cli download jica98/qwen3.5-4B-super-coder --include '*.gguf' --local-dir "${MODELS_DIR}" --local-dir-use-symlinks false
            ;;
        gemma-4-e2b-opus)
            huggingface-cli download filipwx/gemma-4-E2B-it-Opus-4.6-Reasoning-GGUF --include '*Q4_K_M*' --local-dir "${MODELS_DIR}" --local-dir-use-symlinks false
            ;;
        whisper-large-v3-turbo-q5)
            huggingface-cli download ggerganov/whisper.cpp --include 'ggml-large-v3-turbo-q5_0.bin' --local-dir "${MODELS_DIR}/voice/whisper-large-v3-turbo-q5" --local-dir-use-symlinks false
            ;;
        parakeet-tdt-0.6b)
            wget -qO- 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2' |
                tar xjf - -C "${MODELS_DIR}/voice/"
            ;;
        nemotron-3.5-asr)
            huggingface-cli download csukuangfj/sherpa-onnx-nemo-fast-conformer-transducer-es-1424-cpu-int8 --local-dir "${MODELS_DIR}/voice/nemotron-3.5-asr-streaming-0.6b-generic-cpu-3-v3" --local-dir-use-symlinks false
            ;;
        zipformer-es-kroko)
            huggingface-cli download csukuangfj/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06 --local-dir "${MODELS_DIR}/voice/sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06" --local-dir-use-symlinks false
            ;;
        vosk-small-es)
            if ! archive=$(mktemp); then
                return 1
            fi
            if wget -qO "${archive}" 'https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip' &&
                unzip -qo "${archive}" -d "${MODELS_DIR}/voice/"; then
                rm -f -- "${archive}"
                return 0
            fi
            rm -f -- "${archive}"
            return 1
            ;;
        *)
            log_error "No download implementation exists for model '${model_id}'."
            return 1
            ;;
    esac
}

download_models() {
    if [ ! -f "${MODELS_CONF}" ]; then
        log_warn "Model registry not found at ${MODELS_CONF}. Skipping model downloads."
        return 0
    fi

    if ! load_model_registry; then
        log_error "Could not load model registry: ${MODELS_CONF}"
        runtime_add_failure
        return 0
    fi

    if [ "${#MODEL_IDS[@]}" -eq 0 ]; then
        log_warn "No models defined in registry. Skipping."
        return 0
    fi

    printf '\n==============================================\n'
    printf '       Model Download Wizard\n'
    printf '==============================================\n\n'
    printf 'Do you want to download local AI models? (a = all, s = select, n = none)\n'
    read -r model_choice

    local -a selected_models=()
    local mid
    case "${model_choice}" in
        [Aa])
            selected_models=("${MODEL_IDS[@]}")
            ;;
        [Ss])
            printf '\n--- LLM Models ---\n'
            for mid in "${MODEL_IDS[@]}"; do
                if [ "${MODEL_CATEGORIES[$mid]}" = "llm" ]; then
                    _prompt_model "${mid}" && selected_models+=("${mid}")
                fi
            done

            printf '\n--- Voice / ASR Models ---\n'
            for mid in "${MODEL_IDS[@]}"; do
                if [ "${MODEL_CATEGORIES[$mid]}" = "voice" ]; then
                    _prompt_model "${mid}" && selected_models+=("${mid}")
                fi
            done
            ;;
        [Nn]|"")
            log_info "Skipping model downloads."
            return 0
            ;;
        *)
            log_info "Skipping model downloads."
            return 0
            ;;
    esac

    if [ "${#selected_models[@]}" -eq 0 ]; then
        log_info "No models selected."
        return 0
    fi

    printf '\n==============================================\n'
    log_info "Downloading ${#selected_models[@]} model(s)..."
    printf '==============================================\n\n'

    local huggingface_available=true
    local needs_huggingface=false
    for mid in "${selected_models[@]}"; do
        if _model_uses_huggingface "${mid}"; then
            needs_huggingface=true
            break
        fi
    done

    if [ "${needs_huggingface}" = true ] && ! command -v huggingface-cli &> /dev/null; then
        log_info "Installing huggingface-cli (required for selected model downloads)..."
        if ! pip install -q --user 'huggingface_hub[cli]' 2>/dev/null || ! command -v huggingface-cli &> /dev/null; then
            log_error "huggingface-cli is unavailable; affected model downloads will be skipped."
            huggingface_available=false
        fi
    fi

    if ! mkdir -p -- "${MODELS_DIR}" "${MODELS_DIR}/voice"; then
        log_error "Could not create model directories under ${MODELS_DIR}."
        runtime_add_failure
        return 0
    fi

    local dest
    for mid in "${selected_models[@]}"; do
        dest="${HOME}/${MODEL_DESTPATHS[$mid]}"

        if [ -e "${dest}" ]; then
            log_info "${MODEL_NAMES[$mid]} already exists at ${dest}. Skipping."
            continue
        fi

        if _model_uses_huggingface "${mid}" && [ "${huggingface_available}" = false ]; then
            log_error "Failed to download ${MODEL_NAMES[$mid]} because huggingface-cli is unavailable."
            runtime_add_failure
            continue
        fi

        log_info "Downloading ${MODEL_NAMES[$mid]} (${MODEL_SIZES[$mid]})..."
        if _download_model_by_id "${mid}"; then
            log_success "${MODEL_NAMES[$mid]} downloaded successfully."
        else
            log_error "Failed to download ${MODEL_NAMES[$mid]}."
            runtime_add_failure
        fi
    done
}

_prompt_model() {
    local mid="$1"
    local dest="${HOME}/${MODEL_DESTPATHS[$mid]}"
    local status=""
    if [ -e "${dest}" ]; then
        status=" ${GREEN}[installed]${NC}"
    fi
    printf '  %s (%s)%b (y/n) ' "${MODEL_NAMES[$mid]}" "${MODEL_SIZES[$mid]}" "${status}"
    read -r ans
    [[ "${ans}" =~ ^[Yy]$ ]]
}
