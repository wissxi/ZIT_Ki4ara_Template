#!/bin/bash
set -e

WORKSPACE=${WORKSPACE:-/workspace}
COMFYUI_DIR="${WORKSPACE}/ComfyUI"
NODES_DIR="${COMFYUI_DIR}/custom_nodes"
MODELS_DIR="${COMFYUI_DIR}/models"

echo "======================================"
echo "  ComfyUI ZIT/Ki4ra Pod — Provisioning"
echo "======================================"

# ─── Флаг: пропустить provisioning если уже запускались ───────────────────────
if [[ -f "${WORKSPACE}/.provisioned" ]]; then
    echo "✅ Already provisioned — skipping downloads."
    echo "🚀 Starting ComfyUI..."
    cd "${COMFYUI_DIR}"
    python main.py --listen 0.0.0.0 --port 18188 --preview-method auto
    exit 0
fi

# ─── 1. ComfyUI ───────────────────────────────────────────────────────────────
echo ""
echo ">>> [1/5] Installing ComfyUI..."
if [[ ! -d "${COMFYUI_DIR}" ]]; then
    git clone https://github.com/comfyanonymous/ComfyUI "${COMFYUI_DIR}"
fi
cd "${COMFYUI_DIR}"
pip install --no-cache-dir -r requirements.txt

# ─── 2. Python зависимости ────────────────────────────────────────────────────
echo ""
echo ">>> [2/5] Installing Python dependencies..."
pip install --no-cache-dir -r "${WORKSPACE}/requirements.txt"

# ─── 3. Custom Nodes ──────────────────────────────────────────────────────────
echo ""
echo ">>> [3/5] Installing custom nodes..."
mkdir -p "${NODES_DIR}"

echo "  → Downloading custom_nodes.zip..."
wget -q --show-progress \
    ${HF_TOKEN:+--header="Authorization: Bearer ${HF_TOKEN}"} \
    "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/custom_nodes.zip" \
    -O /tmp/custom_nodes.zip
echo "  → Extracting custom_nodes.zip..."
unzip -q -o /tmp/custom_nodes.zip -d "${NODES_DIR}"
rm /tmp/custom_nodes.zip
echo "  ✓ Custom nodes extracted"

# ─── 4. Модели ────────────────────────────────────────────────────────────────
echo ""
echo ">>> [4/5] Downloading models..."

download() {
    local dir="$1"
    local url="$2"
    local filename
    filename=$(basename "$url" | cut -d'?' -f1)
    mkdir -p "$dir"
    if [[ ! -f "${dir}/${filename}" ]]; then
        echo "  → Downloading ${filename}..."
        wget -q --show-progress \
            ${HF_TOKEN:+--header="Authorization: Bearer ${HF_TOKEN}"} \
            --content-disposition \
            -P "$dir" "$url" || echo "  [!] Failed: $url"
    else
        echo "  ✓ ${filename} already exists"
    fi
}

# VAE
download "${MODELS_DIR}/vae" \
    "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/UltraFlux-v1.safetensors"

# Text Encoder (GGUF)
download "${MODELS_DIR}/text_encoders" \
    "https://huggingface.co/wissxi/ZIT_Ki4ra/resolve/main/qwen-4b-zimage-heretic-q8.gguf"

# LoRA
download "${MODELS_DIR}/loras" \
    "https://huggingface.co/wissxi/loras/resolve/main/maya07_lora_ZImage_50steps.safetensors"

# ─── 5. Финал ─────────────────────────────────────────────────────────────────
echo ""
echo ">>> [5/5] Finalizing..."
touch "${WORKSPACE}/.provisioned"
echo "✅ Provisioning complete!"

echo ""
echo "======================================"
echo "  🚀 Starting ComfyUI on port 18188"
echo "======================================"
cd "${COMFYUI_DIR}"
python main.py --listen 0.0.0.0 --port 18188 --preview-method auto
