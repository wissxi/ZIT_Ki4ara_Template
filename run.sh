#!/bin/bash
set -e
source /venv/main/bin/activate

WORKSPACE=${WORKSPACE:-/workspace}
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

echo "=== Start provisioning ==="

# ─── Модели ───────────────────────────────────────────────────────────────────

VAE_MODELS=(
    "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/UltraFlux-v1.safetensors"
    "https://huggingface.co/ReubenF10/ComfyUI-Models/resolve/main/vae/ae.safetensors"
)

DIFFUSION_MODELS=(
    "https://huggingface.co/ReubenF10/ComfyUI-Models/resolve/main/diffusion_models/z_image_turbo_bf16.safetensors"
)

TEXT_ENCODER_MODELS=(
    "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/qwen-4b-zimage-hereticV2-q8.gguf"
)

LORA_MODELS=(
    "https://huggingface.co/wissxi/loras/resolve/main/maya07_lora_ZImage_50steps.safetensors"
    "https://huggingface.co/wissxi/loras/resolve/main/RealisticSnapshot-Zimage-Turbov5.safetensors"
    "https://huggingface.co/wissxi/loras/resolve/main/b3tternud3s_v3.safetensors"
)

# ─── Функции ──────────────────────────────────────────────────────────────────

function provisioning_get_files() {
    if [[ $# -lt 2 ]]; then return; fi
    local dir="$1"
    shift
    local files=("$@")

    mkdir -p "$dir"
    echo "Downloading ${#files[@]} file(s) → $dir..."

    for url in "${files[@]}"; do
        echo "→ $url"
        local auth_header=""
        if [[ -n "$HF_TOKEN" && "$url" =~ huggingface\.co ]]; then
            auth_header="--header=Authorization: Bearer $HF_TOKEN"
        elif [[ -n "$CIVITAI_TOKEN" && "$url" =~ civitai\.com ]]; then
            auth_header="--header=Authorization: Bearer $CIVITAI_TOKEN"
        fi
        wget $auth_header -nc --content-disposition --show-progress -e dotbytes=4M -P "$dir" "$url" \
            || echo " [!] Download failed: $url"
    done
}

function provisioning_clone_comfyui() {
    if [[ ! -d "${COMFYUI_DIR}" ]]; then
        echo "Cloning ComfyUI..."
        git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}"
    fi
    cd "${COMFYUI_DIR}"
}

function provisioning_install_base_reqs() {
    if [[ -f requirements.txt ]]; then
        pip install --no-cache-dir -r requirements.txt
    fi
}

function provisioning_install_custom_nodes() {
    echo "=== Installing custom nodes from archive ==="
    cd "${WORKSPACE}"

    wget -q --show-progress \
        ${HF_TOKEN:+--header="Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/custom_nodes.zip" \
        -O custom_nodes.zip

    unzip -o custom_nodes.zip -d "${COMFYUI_DIR}"
    rm -f custom_nodes.zip
    echo "Custom nodes installed."

    echo "=== Downloading upload_to_gofile node ==="
    wget -q --show-progress \
        ${HF_TOKEN:+--header="Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/upload_to_gofile.py" \
        -O "${COMFYUI_DIR}/custom_nodes/upload_to_gofile.py"
    echo "upload_to_gofile node installed."
}

function provisioning_install_pip_requirements() {
    echo "=== Installing pip requirements ==="
    cd "${WORKSPACE}"

    wget -q \
        ${HF_TOKEN:+--header="Authorization: Bearer $HF_TOKEN"} \
        "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/requirements.txt" \
        -O requirements_custom.txt

    pip install --no-cache-dir -r requirements_custom.txt
    rm -f requirements_custom.txt
    echo "Pip requirements installed."
}

function provisioning_start() {
    provisioning_clone_comfyui
    provisioning_install_base_reqs
    provisioning_install_custom_nodes
    provisioning_install_pip_requirements

    provisioning_get_files "${COMFYUI_DIR}/models/vae"               "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models"  "${DIFFUSION_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders"     "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/loras"             "${LORA_MODELS[@]}"

    echo "=== Provisioning complete ==="
}

# ─── Запуск ───────────────────────────────────────────────────────────────────

if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi

echo "Script done!"
cd "${COMFYUI_DIR}"
