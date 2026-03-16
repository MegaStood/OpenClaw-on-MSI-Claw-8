#!/bin/bash
# ============================================================
# MSI Claw 8 AI+ (Lunar Lake) — Nobara Post-Install Script
# Run this ONCE after first boot and WiFi connection
# Usage: chmod +x claw8-post-install.sh && sudo bash claw8-post-install.sh
# ============================================================

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} MSI Claw 8 AI+ Post-Install Setup${NC}"
echo -e "${GREEN} Nobara Steam-Handheld Edition${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo: sudo bash claw8-post-install.sh${NC}"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~"$REAL_USER")

# ============================================================
# PHASE 1: System Update
# ============================================================
echo -e "${YELLOW}[1/7] Updating system with nobara-sync...${NC}"
echo "This may take a while. Do not interrupt."
echo ""
nobara-sync cli
echo -e "${GREEN}[1/7] System update complete.${NC}"
echo ""

# ============================================================
# PHASE 2: Check and configure GPU driver
# ============================================================
echo -e "${YELLOW}[2/7] Checking GPU driver...${NC}"

GPU_DRIVER=$(lspci -k | grep -A3 'VGA\|3D\|Display' | grep 'Kernel driver' | awk '{print $NF}')
GPU_ID=$(lspci -nnd ::03xx | grep 8086 | grep -oP '8086:\K[0-9a-fA-F]+')

echo "  Current driver: $GPU_DRIVER"
echo "  GPU device ID:  8086:$GPU_ID"

if [ "$GPU_DRIVER" = "i915" ] && [ -n "$GPU_ID" ]; then
    echo ""
    echo -e "${YELLOW}  Your Arc 140V is using the older i915 driver.${NC}"
    echo "  The xe driver is recommended for Xe2 (Lunar Lake) hardware."
    read -p "  Switch to xe driver? (y/n): " SWITCH_XE
    if [ "$SWITCH_XE" = "y" ] || [ "$SWITCH_XE" = "Y" ]; then
        grubby --update-kernel=ALL --args="i915.force_probe=!${GPU_ID} xe.force_probe=${GPU_ID}"
        echo -e "${GREEN}  xe driver will activate after reboot.${NC}"
        echo "  To reverse: sudo grubby --update-kernel=ALL --remove-args='i915.force_probe=!${GPU_ID} xe.force_probe=${GPU_ID}'"
    else
        echo "  Keeping i915 driver."
    fi
elif [ "$GPU_DRIVER" = "xe" ]; then
    echo -e "${GREEN}  Already using xe driver. No changes needed.${NC}"
else
    echo -e "${YELLOW}  Could not determine GPU driver. Check manually with: lspci -k | grep -EA3 'VGA|3D|Display'${NC}"
fi
echo ""

# ============================================================
# PHASE 3: Mask InputPlumber and install HHD
# ============================================================
echo -e "${YELLOW}[3/7] Setting up controller support...${NC}"

echo "  Masking InputPlumber (prevents conflicts with HHD)..."
systemctl mask inputplumber.service 2>/dev/null || echo "  InputPlumber not found, skipping mask."

# Remove system-bundled HHD if present (conflicts with pip version)
if dnf list installed 2>/dev/null | grep -q hhd; then
    echo "  Removing system-bundled HHD to avoid conflicts..."
    dnf remove -y hhd 2>/dev/null
fi

# Check if pip-installed HHD exists (check file path directly, not PATH)
HHD_PATH="$REAL_HOME/.local/bin/hhd"
if [ -f "$HHD_PATH" ]; then
    HHD_VER=$("$HHD_PATH" --version 2>/dev/null || echo "unknown version")
    echo -e "${GREEN}  HHD already installed ($HHD_VER). Skipping.${NC}"
else
    echo "  Installing Handheld Daemon (HHD)..."
    sudo -u "$REAL_USER" bash -c 'curl -L https://github.com/hhd-dev/hhd/raw/master/install.sh | bash'
fi

echo -e "${GREEN}[3/7] Controller support configured. HHD will activate after reboot.${NC}"
echo ""

# ============================================================
# PHASE 4: WiFi sleep fix
# ============================================================
echo -e "${YELLOW}[4/7] Installing WiFi sleep fix...${NC}"

# Find WiFi PCI address
WIFI_PCI=$(lspci -nn | grep -i 'network\|wifi' | head -1 | awk '{print $1}')

if [ -n "$WIFI_PCI" ]; then
    WIFI_FULL="0000:${WIFI_PCI}"
    WIFI_NAME=$(lspci -nn | grep -i 'network\|wifi' | head -1)
    echo "  Found WiFi device: $WIFI_NAME"
    echo "  PCI address: $WIFI_FULL"

    # Method A: D3Cold fix
    echo "  Installing Method A (D3Cold disable)..."
    cat > /etc/systemd/system/fix-wifi-sleep.service << EOF
[Unit]
Description=Disable D3Cold for WiFi to fix sleep issue
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 0 > /sys/bus/pci/devices/${WIFI_FULL}/d3cold_allowed'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable fix-wifi-sleep.service

    # Method B: Module reload on wake (backup)
    echo "  Installing Method B (module reload on wake) as backup..."
    cat > /etc/systemd/system/wifi-resume.service << EOF
[Unit]
Description=Restart WiFi driver on resume
After=suspend.target hibernate.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/modprobe -r iwlmvm iwlwifi
ExecStart=/usr/sbin/modprobe iwlwifi

[Install]
WantedBy=suspend.target hibernate.target
EOF

    systemctl daemon-reload
    systemctl enable wifi-resume.service

    echo -e "${GREEN}[4/7] WiFi sleep fixes installed (both methods active).${NC}"
else
    echo -e "${RED}  Could not find WiFi device. You may need to set up the fix manually.${NC}"
    echo "  Run: lspci -nn | grep -i network"
fi
echo ""

# ============================================================
# PHASE 5: Disable hibernate in systemd (breaks Quick Resume)
# ============================================================
echo -e "${YELLOW}[5/7] Disabling hibernate (prevents Quick Resume issues)...${NC}"

mkdir -p /etc/systemd/
if ! grep -q "AllowHibernation" /etc/systemd/sleep.conf 2>/dev/null; then
    cat >> /etc/systemd/sleep.conf << EOF

# MSI Claw 8 AI+ — hibernate breaks Quick Resume
[Sleep]
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF
    echo -e "${GREEN}[5/7] Hibernate disabled.${NC}"
else
    echo "  Already configured, skipping."
fi
echo ""

# ============================================================
# PHASE 6: Install llama.cpp (Vulkan) + OpenClaw (optional)
# ============================================================
echo -e "${YELLOW}[6/7] AI tools setup (llama.cpp with Vulkan GPU acceleration)...${NC}"
echo ""
echo "  Ollama does not support Vulkan on Intel iGPU — it runs CPU-only."
echo "  llama.cpp with Vulkan gives ~2-3x faster token generation on Arc 140V."
echo ""

# Create model directory with correct ownership
echo "  Setting up model directories..."
mkdir -p /shared/models/gguf
chown -R "$REAL_USER:$REAL_USER" /shared/models

read -p "  Install llama.cpp + AI tools? (y/n): " INSTALL_AI

if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then

    # ----------------------------------------------------------
    # Step A: Install build dependencies
    # ----------------------------------------------------------
    echo ""
    echo "  Installing build dependencies..."
    # shaderc provides glslc (Vulkan shader compiler) — without it cmake fails with:
    #   "Could NOT find Vulkan (missing: glslc)"
    # nvtop provides GPU monitoring — intel_gpu_top does NOT work on the xe driver:
    #   "No device filter specified and no discrete/integrated i915 devices found"
    dnf install -y cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel shaderc \
        nvtop python3-pip 2>&1 | tail -1

    # Verify glslc is available (most common build failure on Nobara)
    if ! command -v glslc &>/dev/null; then
        echo -e "${RED}  glslc not found after installing shaderc. Trying alternative...${NC}"
        dnf install -y glslc 2>/dev/null || \
            dnf install -y glslang 2>/dev/null || \
            echo -e "${RED}  Could not install glslc. Vulkan build will likely fail.${NC}"
    fi

    # ----------------------------------------------------------
    # Step B: Build llama.cpp with Vulkan
    # ----------------------------------------------------------
    LLAMA_DIR="$REAL_HOME/llama.cpp"
    LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"

    if [ -f "$LLAMA_SERVER" ]; then
        echo -e "${GREEN}  llama.cpp already built at $LLAMA_DIR. Skipping build.${NC}"
        echo "  To rebuild: cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release -j\$(nproc)"
    else
        echo "  Cloning and building llama.cpp with Vulkan support..."
        echo "  (This may take a few minutes...)"
        sudo -u "$REAL_USER" bash -c "
            git clone https://github.com/ggerganov/llama.cpp $LLAMA_DIR 2>/dev/null || \
                (cd $LLAMA_DIR && git pull)
            cd $LLAMA_DIR
            # Clean any previous build to avoid cmake cache issues
            # (e.g., a prior build without Vulkan would cache DGGML_VULKAN=OFF)
            rm -rf build
            cmake -B build -DGGML_VULKAN=ON
            cmake --build build --config Release -j\$(nproc)
        "

        if [ -f "$LLAMA_SERVER" ]; then
            echo -e "${GREEN}  llama.cpp built successfully with Vulkan support.${NC}"

            # Verify Vulkan is actually compiled in (not just a CPU-only build)
            # Without Vulkan you get: "no usable GPU found, --gpu-layers option will be ignored"
            echo "  Verifying Vulkan backend..."
            VULKAN_CHECK=$(sudo -u "$REAL_USER" "$LLAMA_SERVER" --help 2>&1 | head -5)
            if echo "$VULKAN_CHECK" | grep -qi "vulkan"; then
                echo -e "${GREEN}  Vulkan backend confirmed working.${NC}"
            else
                echo -e "${YELLOW}  Warning: Vulkan may not be active. If GPU offload doesn't work,${NC}"
                echo -e "${YELLOW}  rebuild with: cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release -j\$(nproc)${NC}"
            fi
        else
            echo -e "${RED}  llama.cpp build failed. Check errors above.${NC}"
            echo "  You can retry manually:"
            echo "    cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release -j\$(nproc)"
        fi
    fi

    # ----------------------------------------------------------
    # Step C: Install run-model.sh launcher
    # ----------------------------------------------------------
    echo "  Installing model launcher script..."
    cat > "$REAL_HOME/run-model.sh" << 'RUNMODEL'
#!/bin/bash
# run-model.sh — auto-discover and launch GGUF models via llama.cpp
# - Models >= 9B: reasoning ON, 32k context (agentic/tool-calling ready)
# - Models < 9B:  reasoning OFF, 8k context

MODEL_DIR="/shared/models/gguf"
LLAMA_SERVER="$HOME/llama.cpp/build/bin/llama-server"

# Extract parameter count (in billions) from filename
get_param_size() {
    local name=$(basename "$1")
    # Match the largest number followed by 'B' (e.g., 35B-A3B → 35, 24B-A2B → 24)
    local size=$(echo "$name" | grep -oiP '\d+(\.\d+)?(?=B[-._])' | head -1)
    if [ -n "$size" ]; then
        printf "%.0f" "$size"
        return
    fi
    # Fallback: estimate from file size (Q4 ≈ 0.6 GB per 1B params)
    local file_gb=$(du -BG "$1" | grep -oP '\d+')
    echo $(( file_gb * 10 / 6 ))
}

# Collect all .gguf files into an array
mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -name "*.gguf" -not -name ".*" | sort)

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "No .gguf models found in $MODEL_DIR"
    echo "Download models and place .gguf files in $MODEL_DIR"
    exit 1
fi

# If no argument, show menu
if [ -z "$1" ]; then
    echo ""
    echo "Available models:"
    echo "───────────────────────────────────────────────────────────────────────────────"
    for i in "${!MODELS[@]}"; do
        name=$(basename "${MODELS[$i]}")
        size=$(du -h "${MODELS[$i]}" | cut -f1)
        params=$(get_param_size "${MODELS[$i]}")
        if [ "$params" -ge 9 ] 2>/dev/null; then
            mode="reasoning ON  | ctx 32k"
        else
            mode="reasoning OFF | ctx 8k"
        fi
        printf "  %d) %-52s [%5s] %s\n" $((i+1)) "$name" "$size" "$mode"
    done
    echo ""
    read -p "Select model (1-${#MODELS[@]}): " choice
else
    choice="$1"
fi

# Validate selection
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#MODELS[@]} ]; then
    echo "Invalid selection: $choice"
    exit 1
fi

MODEL="${MODELS[$((choice-1))]}"
MODEL_NAME=$(basename "$MODEL")
PARAMS=$(get_param_size "$MODEL")

# Set reasoning and context based on model size
# - Small models (<9B) loop endlessly in thinking mode — disable it
# - Large models benefit from reasoning for agentic/tool-calling tasks
# - 32k context needed for OpenClaw tool calling (schemas + history eat tokens)
# - 8k is sufficient for simple chat with small models
if [ "$PARAMS" -ge 9 ] 2>/dev/null; then
    REASONING_ARGS=""
    CONTEXT=32768
    MODE_LABEL="reasoning ON, context 32k"
else
    REASONING_ARGS="--reasoning-budget 0"
    CONTEXT=8192
    MODE_LABEL="reasoning OFF, context 8k"
fi

# Kill existing server
pkill -f llama-server 2>/dev/null && sleep 1

echo ""
echo "Loading: $MODEL_NAME"
echo "Params:  ~${PARAMS}B"
echo "Mode:    $MODE_LABEL"
echo "API:     http://127.0.0.1:8080/v1/chat/completions"
echo "Web UI:  http://127.0.0.1:8080"
echo "───────────────────────────────────────────────────────────────────────────────"
echo ""

# -ngl 99: offload all layers to GPU (Vulkan). Without this, runs CPU-only
# -t 8:    use all 8 threads. Default is 2, which bottlenecks prompt processing
#          (207 t/s with 2 threads vs 652 t/s with 8 threads on Qwen3.5-4B)
# -c:      explicit context size. Without this, defaults to model's training context
#          (e.g., 262k for Qwen3.5) which eats 8GB+ of RAM for KV cache alone
$LLAMA_SERVER \
    -m "$MODEL" \
    -ngl 99 \
    -t 8 \
    -c $CONTEXT \
    $REASONING_ARGS
RUNMODEL
    chown "$REAL_USER:$REAL_USER" "$REAL_HOME/run-model.sh"
    chmod +x "$REAL_HOME/run-model.sh"
    echo -e "${GREEN}  Installed ~/run-model.sh${NC}"

    # ----------------------------------------------------------
    # Step D: Install huggingface-cli for model downloads
    # ----------------------------------------------------------
    echo "  Installing huggingface-cli for model downloads..."
    sudo -u "$REAL_USER" pip install --break-system-packages -q huggingface-hub 2>/dev/null
    echo -e "${GREEN}  huggingface-cli installed.${NC}"

    # ----------------------------------------------------------
    # Step E: Model selection and download
    # ----------------------------------------------------------
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │              Choose a model to download                         │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  LOCAL MODELS (downloaded as GGUF, run with Vulkan GPU)         │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  1) Qwen3.5-35B-A3B Q4_K_M   [~21GB]  ★ RECOMMENDED           │"
    echo "  │     MoE 35B/3B active. Hybrid SSM+Attention architecture.      │"
    echo "  │     Best 32k context scaling. Thinking mode. ~9.5 t/s.         │"
    echo "  │                                                                 │"
    echo "  │  2) LFM2-24B-A2B Q5_K_M      [~17GB]  ⚡ FASTEST              │"
    echo "  │     MoE 24B/2B active. Liquid AI hybrid architecture.          │"
    echo "  │     Fastest on Arc 140V at ~20 t/s. Good tool dispatch.        │"
    echo "  │                                                                 │"
    echo "  │  3) GLM-4.7-Flash Q4_K_M     [~18GB]                           │"
    echo "  │     MoE 30B/3B active. Best thinking mode for reasoning.       │"
    echo "  │     Tool calling + thinking. ~12 t/s on Arc 140V.              │"
    echo "  │                                                                 │"
    echo "  │  4) Qwen3.5-4B Q4_K_M        [~3GB]   ⚡ SMALLEST             │"
    echo "  │     Dense 4B. Lightweight, ~11.5 t/s on Arc 140V.              │"
    echo "  │     Good for quick tasks. Thinking mode not recommended.        │"
    echo "  │                                                                 │"
    echo "  │  5) Crow-4B-Opus-4.6 Q5_K_M  [~3GB]   🧠 DISTILLED           │"
    echo "  │     Dense 4B. Claude Opus 4.6 distilled reasoning.             │"
    echo "  │     Reduced thinking loops vs base Qwen3.5-4B. ~11.5 t/s.     │"
    echo "  │                                                                 │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  CLOUD OPTIONS (configure after install)                        │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  6) Anthropic API     [requires API key from console.anthropic] │"
    echo "  │     Use Claude as cloud backend. Best reasoning quality.        │"
    echo "  │     Configure in OpenClaw settings after install.               │"
    echo "  │                                                                 │"
    echo "  │  7) Remote llama.cpp / vLLM server on local network             │"
    echo "  │     Point OpenClaw to a more powerful machine.                  │"
    echo "  │     Configure baseUrl in OpenClaw settings after install.       │"
    echo "  │                                                                 │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  8) Skip download — I'll add GGUF models manually later.        │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}  Note: Models are downloaded to /shared/models/gguf/${NC}"
    echo -e "${YELLOW}  You can also manually drop .gguf files there anytime.${NC}"
    echo ""
    read -p "  Choose [1-8]: " MODEL_CHOICE

    HF_DL="sudo -u $REAL_USER huggingface-cli download"
    GGUF_DIR="/shared/models/gguf"

    case $MODEL_CHOICE in
        1)
            MODEL_DISPLAY="Qwen3.5-35B-A3B Q4_K_M"
            echo "  Downloading Qwen3.5-35B-A3B Q4_K_M (~21GB, this may take a while)..."
            $HF_DL unsloth/Qwen3.5-35B-A3B-GGUF \
                Qwen3.5-35B-A3B-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        2)
            MODEL_DISPLAY="LFM2-24B-A2B Q5_K_M"
            echo "  Downloading LFM2-24B-A2B Q5_K_M (~17GB, this may take a while)..."
            $HF_DL LiquidAI/LFM2-24B-A2B-GGUF \
                LFM2-24B-A2B-Q5_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        3)
            MODEL_DISPLAY="GLM-4.7-Flash Q4_K_M"
            echo "  Downloading GLM-4.7-Flash Q4_K_M (~18GB, this may take a while)..."
            $HF_DL unsloth/GLM-4.7-Flash-GGUF \
                GLM-4.7-Flash-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        4)
            MODEL_DISPLAY="Qwen3.5-4B Q4_K_M"
            echo "  Downloading Qwen3.5-4B Q4_K_M (~3GB, this may take a while)..."
            $HF_DL unsloth/Qwen3.5-4B-GGUF \
                Qwen3.5-4B-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        5)
            MODEL_DISPLAY="Crow-4B-Opus-4.6 Q5_K_M"
            echo "  Downloading Crow-4B-Opus-4.6-Distill Q5_K_M (~3GB, this may take a while)..."
            $HF_DL crownelius/Crow-4B-Opus-4.6-Distill-Heretic_Qwen3.5 \
                Crow-4B-Opus-4.6-Distill-Heretic_Qwen3.5.Q5_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        6)
            MODEL_DISPLAY="Anthropic API"
            PULLED_MODEL="anthropic-api"
            echo ""
            echo -e "${GREEN}  Anthropic API selected as cloud backend.${NC}"
            echo "  Configure OpenClaw to use Claude:"
            echo ""
            echo "  In ~/.openclaw/openclaw.json, set:"
            echo '    "providers": {'
            echo '      "anthropic": {'
            echo '        "apiKey": "sk-ant-YOUR_KEY_HERE"'
            echo '      }'
            echo '    }'
            echo ""
            echo "  Get your API key from: https://console.anthropic.com"
            ;;
        7)
            MODEL_DISPLAY="Remote server"
            PULLED_MODEL="remote-server"
            echo ""
            echo -e "${GREEN}  Remote server selected.${NC}"
            echo "  Point OpenClaw to your remote llama.cpp or vLLM server:"
            echo ""
            echo "  The remote server must expose an OpenAI-compatible API."
            echo "  In OpenClaw config, set baseUrl to:"
            echo "    http://YOUR_SERVER_IP:8080/v1"
            echo ""
            echo "  Start remote llama.cpp with: --host 0.0.0.0"
            ;;
        8|*)
            MODEL_DISPLAY="none"
            PULLED_MODEL="none"
            ;;
    esac

    # Fix ownership of downloaded files
    chown -R "$REAL_USER:$REAL_USER" /shared/models

    # Clean up huggingface-cli cache symlinks (it downloads to cache, then symlinks)
    # Move actual files to gguf dir if they're symlinks
    for f in "$GGUF_DIR"/*.gguf; do
        if [ -L "$f" ]; then
            real_file=$(readlink -f "$f")
            rm "$f"
            mv "$real_file" "$f"
            chown "$REAL_USER:$REAL_USER" "$f"
        fi
    done

    if [ "$PULLED_MODEL" = "local" ]; then
        echo -e "${GREEN}  Downloaded $MODEL_DISPLAY to $GGUF_DIR${NC}"
    elif [ "$PULLED_MODEL" = "none" ]; then
        echo -e "${GREEN}  llama.cpp installed. No model downloaded.${NC}"
        echo "  Download models later from https://huggingface.co"
        echo "  Place .gguf files in /shared/models/gguf/"
        echo "  Or use: huggingface-cli download <repo> <file> --local-dir /shared/models/gguf/"
    fi

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  Quick Start                                                    │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  Launch a model:    ~/run-model.sh                              │"
    echo "  │  Web UI:            http://127.0.0.1:8080                       │"
    echo "  │  API endpoint:      http://127.0.0.1:8080/v1/chat/completions   │"
    echo "  │  Benchmark:         ~/llama.cpp/build/bin/llama-bench -m <model> │"
    echo "  │                                                                 │"
    echo "  │  Add models:        Drop .gguf files into /shared/models/gguf/  │"
    echo "  │  Download models:   huggingface-cli download <repo> <file>      │"
    echo "  │                     --local-dir /shared/models/gguf/            │"
    echo "  │                                                                 │"
    echo "  │  OpenClaw:          Point to http://127.0.0.1:8080              │"
    echo "  │                     (same OpenAI-compatible API as Ollama)      │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
else
    PULLED_MODEL="skipped"
    echo "  Skipping AI tools. You can install later:"
    echo ""
    echo "  # Install build tools and build llama.cpp"
    echo "  sudo dnf install cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel shaderc"
    echo "  git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp"
    echo "  cd ~/llama.cpp"
    echo "  cmake -B build -DGGML_VULKAN=ON"
    echo "  cmake --build build --config Release -j\$(nproc)"
    echo ""
    echo "  # Download a model"
    echo "  scripts/download_model_fast.sh unsloth/Qwen3.5-35B-A3B-GGUF --gguf Q4_K_M"
    echo ""
    echo "  # Run it"
    echo "  ~/run-model.sh"
fi
echo ""

# ============================================================
# PHASE 7: Summary and reboot prompt
# ============================================================
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Setup Complete! Summary:${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  [✓] System updated via nobara-sync"
echo "  [✓] GPU driver: $GPU_DRIVER (ID: 8086:$GPU_ID)"
echo "  [✓] InputPlumber masked"
echo "  [✓] Handheld Daemon (HHD) installed"
echo "  [✓] WiFi sleep fix installed (D3Cold + module reload)"
echo "  [✓] Hibernate disabled"
if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then
    echo "  [✓] llama.cpp built with Vulkan GPU acceleration"
    echo "  [✓] Model launcher installed: ~/run-model.sh"
    case $PULLED_MODEL in
        local)
            echo "  [✓] Downloaded $MODEL_DISPLAY to /shared/models/gguf/"
            ;;
        anthropic-api)
            echo "  [✓] Anthropic API selected — configure key in OpenClaw settings"
            ;;
        remote-server)
            echo "  [✓] Remote server selected — configure baseUrl in OpenClaw settings"
            ;;
        none)
            echo "  [✓] No model downloaded yet — add .gguf files to /shared/models/gguf/"
            ;;
    esac
    echo ""
    echo "  To start:  ~/run-model.sh"
    echo "  Web UI:    http://127.0.0.1:8080"
    echo "  API:       http://127.0.0.1:8080/v1/chat/completions"
fi
echo ""
echo -e "${YELLOW}After reboot, verify:${NC}"
echo "  1. Controller works in Desktop Mode"
echo "  2. Sleep/wake works and WiFi reconnects"
echo "  3. Sound plays through speakers"
echo "  4. GPU driver: lspci -k | grep -EA3 'VGA|3D|Display'"
echo "  5. Switch to Gaming Mode and test Steam"
if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then
    echo "  6. Run ~/run-model.sh and test AI inference"
    echo "  7. Monitor GPU usage: nvtop (intel_gpu_top does NOT work on xe driver)"
fi
echo ""
echo -e "${YELLOW}If WiFi still dies after sleep:${NC}"
echo "  Method A (D3Cold) is active. If it doesn't help,"
echo "  Method B (module reload) is also active as backup."
echo "  If neither works, check: journalctl -b | grep iwlwifi"
echo ""
echo -e "${YELLOW}To switch to mesa-git drivers (optional):${NC}"
echo "  Open Nobara Driver Manager → switch to mesa-git"
echo ""
read -p "Reboot now? (y/n): " DO_REBOOT
if [ "$DO_REBOOT" = "y" ] || [ "$DO_REBOOT" = "Y" ]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo -e "${YELLOW}Remember to reboot before using HHD or the xe driver!${NC}"
fi
