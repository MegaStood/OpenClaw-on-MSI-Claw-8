#!/bin/bash
# ============================================================
# MSI Claw Post-Install Script (Claw 8 AI+ / Claw A1M)
# Auto-detects hardware and adapts configuration accordingly
# Run this ONCE after first boot and WiFi connection
# Usage: chmod +x claw-post-install-llama.sh && sudo bash claw-post-install-llama.sh
# ============================================================

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ============================================================
# Hardware Detection
# ============================================================
GPU_ID=$(lspci -nnd ::0300 | grep 8086 | grep -oP '8086:\K[0-9a-fA-F]+' | head -1)
GPU_DRIVER=$(lspci -k | grep -A3 'VGA\|3D\|Display' | grep 'Kernel driver' | awk '{print $NF}')
CPU_MODEL=$(lscpu | grep 'Model name' | sed 's/.*: *//')
CPU_THREADS=$(nproc)

# Detect platform: Lunar Lake (Claw 8 AI+) vs Meteor Lake (Claw A1M) vs unknown
if echo "$CPU_MODEL" | grep -qi "lunar\|288V\|288H\|268V\|268H\|256V\|258V"; then
    PLATFORM="lunar_lake"
    PLATFORM_NAME="Claw 8 AI+ (Lunar Lake)"
    GPU_NAME="Arc 140V"
    XE_RECOMMENDED=true
elif echo "$CPU_MODEL" | grep -qi "meteor\|155H\|155U\|125H\|125U\|135H\|135U\|145H\|145U"; then
    PLATFORM="meteor_lake"
    PLATFORM_NAME="Claw A1M (Meteor Lake)"
    GPU_NAME="Intel Arc Graphics"
    # xe driver supported on Meteor Lake with kernel >= 6.17
    KERN_MAJOR=$(uname -r | cut -d. -f1)
    KERN_MINOR=$(uname -r | cut -d. -f2)
    if [ "$KERN_MAJOR" -gt 6 ] || ([ "$KERN_MAJOR" -eq 6 ] && [ "$KERN_MINOR" -ge 17 ]); then
        XE_RECOMMENDED=true
    else
        XE_RECOMMENDED=false
    fi
else
    PLATFORM="unknown"
    PLATFORM_NAME="Unknown MSI Claw"
    GPU_NAME="Intel Arc Graphics"
    XE_RECOMMENDED=false
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} MSI Claw Post-Install Setup${NC}"
echo -e "${GREEN} Nobara Steam-Handheld Edition${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Detected: ${GREEN}${PLATFORM_NAME}${NC}"
echo "  CPU:      $CPU_MODEL ($CPU_THREADS threads)"
echo "  GPU:      $GPU_NAME (8086:$GPU_ID, driver: $GPU_DRIVER)"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo: sudo bash claw-post-install-llama.sh${NC}"
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

echo "  Current driver: $GPU_DRIVER"
echo "  GPU device ID:  8086:$GPU_ID"

if [ "$GPU_DRIVER" = "i915" ] && [ -n "$GPU_ID" ]; then
    if [ "$XE_RECOMMENDED" = true ]; then
        echo ""
        echo -e "${YELLOW}  Your $GPU_NAME is using the older i915 driver.${NC}"
        echo "  The xe driver is recommended for better performance."
        read -p "  Switch to xe driver? (y/n): " SWITCH_XE
        if [ "$SWITCH_XE" = "y" ] || [ "$SWITCH_XE" = "Y" ]; then
            grubby --update-kernel=ALL --args="i915.force_probe=!${GPU_ID} xe.force_probe=${GPU_ID}"
            echo -e "${GREEN}  xe driver will activate after reboot.${NC}"
            echo "  To reverse: sudo grubby --update-kernel=ALL --remove-args='i915.force_probe=!${GPU_ID} xe.force_probe=${GPU_ID}'"
        else
            echo "  Keeping i915 driver."
        fi
    else
        echo ""
        echo -e "${YELLOW}  xe driver is not recommended for your hardware/kernel.${NC}"
        echo "  Keeping i915 driver. Upgrade to kernel >= 6.17 to enable xe."
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
WIFI_PCI=$(lspci -nn | grep -i 'network\|wifi' | grep -iv 'system\|gaussian' | head -1 | awk '{print $1}')

if [ -n "$WIFI_PCI" ]; then
    WIFI_FULL="0000:${WIFI_PCI}"
    WIFI_NAME=$(lspci -nn | grep -i 'network\|wifi' | grep -iv 'system\|gaussian' | head -1)
    echo "  Found WiFi device: $WIFI_NAME"
    echo "  PCI address: $WIFI_FULL"

    # Verify d3cold sysfs path exists before creating the service
    if [ -e "/sys/bus/pci/devices/${WIFI_FULL}/d3cold_allowed" ]; then
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
    else
        echo -e "${YELLOW}  D3Cold sysfs path not found for ${WIFI_FULL}, skipping Method A.${NC}"
    fi

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

    echo -e "${GREEN}[4/7] WiFi sleep fixes installed.${NC}"
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

# MSI Claw — hibernate breaks Quick Resume
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
# PHASE 6: Install llama.cpp (Vulkan + SYCL) + OpenClaw (optional)
# ============================================================
echo -e "${YELLOW}[6/7] AI tools setup (llama.cpp with SYCL + Vulkan GPU acceleration)...${NC}"
echo ""
echo "  Ollama does not support Vulkan on Intel iGPU — it runs CPU-only."
echo "  llama.cpp with SYCL (FP16) gives ~49% faster prefill than Vulkan on $GPU_NAME."
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
    # glslc provides the Vulkan shader compiler — without it cmake fails with:
    #   "Could NOT find Vulkan (missing: glslc)"
    # On Nobara 43+, the package is 'glslc' (not 'shaderc').
    # nvtop provides GPU monitoring — intel_gpu_top does NOT work on the xe driver.
    dnf install -y cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel nvtop python3-pip 2>&1 | tail -1

    # Set up Intel oneAPI repository (provides DPC++ compiler + oneMKL for SYCL backend)
    if [ ! -f /etc/yum.repos.d/oneAPI.repo ]; then
        echo "  Adding Intel oneAPI repository..."
        tee /etc/yum.repos.d/oneAPI.repo > /dev/null << 'ONEAPI_REPO'
[oneAPI]
name=Intel oneAPI
baseurl=https://yum.repos.intel.com/oneapi
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
ONEAPI_REPO
    fi

    # intel-oneapi-mkl-devel: provides oneMKL (optimized BLAS/LAPACK) + DPC++ compiler (icx/icpx)
    # Required for the SYCL backend — oneMKL provides hand-tuned GEMM kernels for Intel GPUs
    echo "  Installing Intel oneAPI MKL (this may take a while on first run)..."
    dnf install -y intel-oneapi-mkl-devel 2>&1 | tail -1

    # Install glslc: try 'glslc' first (Nobara 43+), fall back to 'shaderc' (older Fedora)
    if ! command -v glslc &>/dev/null; then
        echo "  Installing Vulkan shader compiler (glslc)..."
        dnf install -y glslc 2>/dev/null || \
            dnf install -y shaderc 2>/dev/null || \
            dnf install -y glslang 2>/dev/null || \
            echo -e "${RED}  Could not install glslc. Vulkan build will likely fail.${NC}"
    fi

    if ! command -v glslc &>/dev/null; then
        echo -e "${RED}  glslc still not found. Vulkan build will likely fail.${NC}"
        echo "  Try: sudo dnf install glslc"
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
            rm -rf build
            cmake -B build -DGGML_VULKAN=ON
            cmake --build build --config Release -j\$(nproc)
        "

        if [ -f "$LLAMA_SERVER" ]; then
            echo -e "${GREEN}  llama.cpp built successfully with Vulkan support.${NC}"

            # Verify Vulkan shared library was built
            if [ -f "$LLAMA_DIR/build/bin/libggml-vulkan.so" ]; then
                echo -e "${GREEN}  Vulkan backend library confirmed (libggml-vulkan.so).${NC}"
            else
                echo -e "${YELLOW}  Warning: libggml-vulkan.so not found. GPU offload may not work.${NC}"
                echo -e "${YELLOW}  Rebuild with: cd ~/llama.cpp && rm -rf build && cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release -j\$(nproc)${NC}"
            fi
        else
            echo -e "${RED}  llama.cpp build failed. Check errors above.${NC}"
            echo "  You can retry manually:"
            echo "    cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release -j\$(nproc)"
        fi
    fi

    # ----------------------------------------------------------
    # Step B2: Build llama.cpp with SYCL (into build-sycl/)
    # ----------------------------------------------------------
    # SYCL backend uses Intel DPC++ compiler (icx/icpx) and oneMKL for
    # optimized GEMM on Intel iGPU. Scales much better at long contexts
    # than Vulkan (~1.8x faster at 32K context).
    # Both builds coexist: build/ (Vulkan) and build-sycl/ (SYCL).
    #
    # GGML_SYCL_F16=ON: use FP16 intermediate accumulation in GEMM.
    # Benchmarked +49% faster prefill (311→463 tok/s at pp512) with
    # negligible quality impact on quantized models. TG unchanged
    # (memory-bandwidth bound, not compute-bound).
    #
    # Note: llama.cpp release binaries include a Windows SYCL build, but
    # NO Linux SYCL build. Linux users must compile from source.
    LLAMA_SYCL_SERVER="$LLAMA_DIR/build-sycl/bin/llama-server"

    if [ -f "$LLAMA_SYCL_SERVER" ]; then
        echo -e "${GREEN}  llama.cpp SYCL backend already built. Skipping.${NC}"
        echo "  To rebuild: source /opt/intel/oneapi/setvars.sh && cd ~/llama.cpp && rm -rf build-sycl && cmake -B build-sycl -DGGML_SYCL=ON -DGGML_SYCL_F16=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=Release && cmake --build build-sycl -j\$(nproc)"
    else
        echo "  Building llama.cpp with SYCL backend (FP16 accumulation)..."
        echo "  (Uses oneMKL for optimized matrix ops — +49% faster prefill than FP32)"

        # SYCL requires Intel's DPC++ compiler (icx/icpx) from oneAPI
        sudo -u "$REAL_USER" bash -c "
            source /opt/intel/oneapi/setvars.sh --force 2>/dev/null
            cd $LLAMA_DIR
            rm -rf build-sycl
            cmake -B build-sycl \
                -DGGML_SYCL=ON \
                -DGGML_SYCL_F16=ON \
                -DCMAKE_C_COMPILER=icx \
                -DCMAKE_CXX_COMPILER=icpx \
                -DCMAKE_BUILD_TYPE=Release
            cmake --build build-sycl --config Release -j\$(nproc)
        "

        if [ -f "$LLAMA_SYCL_SERVER" ]; then
            echo -e "${GREEN}  llama.cpp SYCL backend built successfully (build-sycl/, FP16).${NC}"
        else
            echo -e "${YELLOW}  SYCL build failed. Vulkan backend is still available.${NC}"
            echo "  You can retry manually:"
            echo "    source /opt/intel/oneapi/setvars.sh"
            echo "    cd ~/llama.cpp && rm -rf build-sycl"
            echo "    cmake -B build-sycl -DGGML_SYCL=ON -DGGML_SYCL_F16=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=Release"
            echo "    cmake --build build-sycl --config Release -j\$(nproc)"
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
# - Supports two backends: SYCL (default, fastest) and Vulkan (fallback)
#
# Usage:
#   ~/run-model.sh                    # SYCL backend (default, +49% faster prefill)
#   ~/run-model.sh --vulkan           # Vulkan backend (no oneAPI needed)
#   ~/run-model.sh --bench            # Run llama-bench instead of server

MODEL_DIR="/shared/models/gguf"

# Parse flags
BACKEND="sycl"
BENCH_MODE=false
POSITIONAL=()
for arg in "$@"; do
    case $arg in
        --sycl)           BACKEND="sycl" ;;
        --vulkan|--vk)    BACKEND="vulkan" ;;
        --bench)          BENCH_MODE=true ;;
        *)                POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

# Select backend binary directory
if [ "$BACKEND" = "sycl" ]; then
    BUILD_DIR="$HOME/llama.cpp/build-sycl"
    BACKEND_LABEL="SYCL"
    # SYCL needs oneAPI environment for runtime libraries (oneMKL, Level Zero)
    source /opt/intel/oneapi/setvars.sh --force 2>/dev/null
    # Enable Intel System Management so SYCL can query actual free GPU memory
    export ZES_ENABLE_SYSMAN=1
else
    BUILD_DIR="$HOME/llama.cpp/build"
    BACKEND_LABEL="Vulkan"
fi

LLAMA_SERVER="$BUILD_DIR/bin/llama-server"
LLAMA_BENCH="$BUILD_DIR/bin/llama-bench"

if [ ! -f "$LLAMA_SERVER" ]; then
    echo "Error: $BACKEND_LABEL backend not found at $BUILD_DIR"
    echo "Build it first, or use --vulkan / --sycl to switch."
    exit 1
fi

# Auto-detect thread count: physical cores (hyperthreads hurt matrix math throughput)
THREADS=$(lscpu | awk '/^Core\(s\) per socket/ {print $NF}')
THREADS=${THREADS:-$(nproc)}

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

# Bench mode: run llama-bench and exit
if [ "$BENCH_MODE" = true ]; then
    echo ""
    echo "Benchmarking: $MODEL_NAME ($BACKEND_LABEL backend)"
    echo "───────────────────────────────────────────────────────────────────────────────"
    BENCH_ARGS="-m $MODEL -p 512,1024,2048,4096 -n 128 -ngl 99"
    $LLAMA_BENCH $BENCH_ARGS
    exit 0
fi

# Kill existing server
pkill -f llama-server 2>/dev/null && sleep 1

echo ""
echo "Loading: $MODEL_NAME"
echo "Backend: $BACKEND_LABEL"
echo "Params:  ~${PARAMS}B"
echo "Mode:    $MODE_LABEL"
echo "Threads: $THREADS"
echo "API:     http://127.0.0.1:8080/v1/chat/completions"
echo "Web UI:  http://127.0.0.1:8080"
echo "───────────────────────────────────────────────────────────────────────────────"
echo ""

# -ngl 99: offload all layers to GPU. Without this, runs CPU-only
# -t N:    auto-detected physical core count for best throughput
# -c:      explicit context size. Without this, defaults to model's training context
#          which can eat all RAM for KV cache alone
$LLAMA_SERVER \
    -m "$MODEL" \
    -ngl 99 \
    -t $THREADS \
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
    echo "  │  LOCAL MODELS (downloaded as GGUF, run with SYCL/Vulkan GPU)    │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  1) Gemma 4 E4B Q4_K_M          [~5GB]   ★ RECOMMENDED        │"
    echo "  │     Dense 7.5B (4B active MoE). Google's latest multimodal.    │"
    echo "  │     Fastest prefill (467 tok/s SYCL FP16). 14.5 t/s TG.       │"
    echo "  │                                                                 │"
    echo "  │  2) Qwen3.5-35B-A3B Q4_K_M      [~21GB]  🧠 BEST AGENT       │"
    echo "  │     MoE 35B/3B active. Hybrid SSM+Attention architecture.      │"
    echo "  │     Best 32k context scaling. Thinking mode. ~9.5 t/s.         │"
    echo "  │                                                                 │"
    echo "  │  3) LFM2-24B-A2B Q5_K_M         [~17GB]  ⚡ FASTEST TG       │"
    echo "  │     MoE 24B/2B active. Liquid AI hybrid architecture.          │"
    echo "  │     Fastest on Arc 140V at ~20 t/s. Good tool dispatch.        │"
    echo "  │                                                                 │"
    echo "  │  4) GLM-4.7-Flash Q4_K_M        [~18GB]                        │"
    echo "  │     MoE 30B/3B active. Best thinking mode for reasoning.       │"
    echo "  │     Tool calling + thinking. ~12 t/s on Arc 140V.              │"
    echo "  │                                                                 │"
    echo "  │  5) Qwen3.5-4B Q4_K_M           [~3GB]   ⚡ SMALLEST          │"
    echo "  │     Dense 4B. Lightweight, ~11.5 t/s on Arc 140V.              │"
    echo "  │     Good for quick tasks. Thinking mode not recommended.        │"
    echo "  │                                                                 │"
    echo "  │  6) Crow-4B-Opus-4.6 Q5_K_M     [~3GB]   🧠 DISTILLED        │"
    echo "  │     Dense 4B. Claude Opus 4.6 distilled reasoning.             │"
    echo "  │     Reduced thinking loops vs base Qwen3.5-4B. ~11.5 t/s.     │"
    echo "  │                                                                 │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  CLOUD OPTIONS (configure after install)                        │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  7) Anthropic API     [requires API key from console.anthropic] │"
    echo "  │     Use Claude as cloud backend. Best reasoning quality.        │"
    echo "  │     Configure in OpenClaw settings after install.               │"
    echo "  │                                                                 │"
    echo "  │  8) Remote llama.cpp / vLLM server on local network             │"
    echo "  │     Point OpenClaw to a more powerful machine.                  │"
    echo "  │     Configure baseUrl in OpenClaw settings after install.       │"
    echo "  │                                                                 │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  9) Skip download — I'll add GGUF models manually later.        │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}  Note: Models are downloaded to /shared/models/gguf/${NC}"
    echo -e "${YELLOW}  You can also manually drop .gguf files there anytime.${NC}"
    echo ""
    read -p "  Choose [1-9]: " MODEL_CHOICE

    HF_DL="sudo -u $REAL_USER huggingface-cli download"
    GGUF_DIR="/shared/models/gguf"

    case $MODEL_CHOICE in
        1)
            MODEL_DISPLAY="Gemma 4 E4B Q4_K_M"
            echo "  Downloading Gemma 4 E4B Q4_K_M (~5GB)..."
            $HF_DL unsloth/gemma-4-E4B-it-GGUF \
                gemma-4-E4B-it-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        2)
            MODEL_DISPLAY="Qwen3.5-35B-A3B Q4_K_M"
            echo "  Downloading Qwen3.5-35B-A3B Q4_K_M (~21GB, this may take a while)..."
            $HF_DL unsloth/Qwen3.5-35B-A3B-GGUF \
                Qwen3.5-35B-A3B-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        3)
            MODEL_DISPLAY="LFM2-24B-A2B Q5_K_M"
            echo "  Downloading LFM2-24B-A2B Q5_K_M (~17GB, this may take a while)..."
            $HF_DL LiquidAI/LFM2-24B-A2B-GGUF \
                LFM2-24B-A2B-Q5_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        4)
            MODEL_DISPLAY="GLM-4.7-Flash Q4_K_M"
            echo "  Downloading GLM-4.7-Flash Q4_K_M (~18GB, this may take a while)..."
            $HF_DL unsloth/GLM-4.7-Flash-GGUF \
                GLM-4.7-Flash-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        5)
            MODEL_DISPLAY="Qwen3.5-4B Q4_K_M"
            echo "  Downloading Qwen3.5-4B Q4_K_M (~3GB, this may take a while)..."
            $HF_DL unsloth/Qwen3.5-4B-GGUF \
                Qwen3.5-4B-Q4_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        6)
            MODEL_DISPLAY="Crow-4B-Opus-4.6 Q5_K_M"
            echo "  Downloading Crow-4B-Opus-4.6-Distill Q5_K_M (~3GB, this may take a while)..."
            $HF_DL crownelius/Crow-4B-Opus-4.6-Distill-Heretic_Qwen3.5 \
                Crow-4B-Opus-4.6-Distill-Heretic_Qwen3.5.Q5_K_M.gguf \
                --local-dir "$GGUF_DIR"
            PULLED_MODEL="local"
            ;;
        7)
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
        8)
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
        9|*)
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
    echo "  │  Launch (SYCL):     ~/run-model.sh              ★ default       │"
    echo "  │  Launch (Vulkan):   ~/run-model.sh --vulkan                     │"
    echo "  │  Benchmark:         ~/run-model.sh --bench                      │"
    echo "  │  Benchmark (Vulkan):~/run-model.sh --vulkan --bench             │"
    echo "  │                                                                 │"
    echo "  │  Web UI:            http://127.0.0.1:8080                       │"
    echo "  │  API endpoint:      http://127.0.0.1:8080/v1/chat/completions   │"
    echo "  │                                                                 │"
    echo "  │  Add models:        Drop .gguf files into /shared/models/gguf/  │"
    echo "  │  Download models:   huggingface-cli download <repo> <file>      │"
    echo "  │                     --local-dir /shared/models/gguf/            │"
    echo "  │                                                                 │"
    echo "  │  OpenClaw:          Point to http://127.0.0.1:8080              │"
    echo "  │                     (same OpenAI-compatible API as Ollama)      │"
    echo "  │                                                                 │"
    echo "  │  SYCL FP16 is +49% faster prefill, +1.8x at 32K vs Vulkan     │"
    echo "  │  Use --vulkan if SYCL build failed or oneAPI is not installed   │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
else
    PULLED_MODEL="skipped"
    echo "  Skipping AI tools. You can install later:"
    echo ""
    echo "  # Install build tools and build llama.cpp (SYCL + Vulkan)"
    echo "  sudo dnf install cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel glslc"
    echo "  git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp"
    echo "  cd ~/llama.cpp"
    echo "  # Vulkan backend (simpler, no oneAPI needed):"
    echo "  cmake -B build -DGGML_VULKAN=ON && cmake --build build -j\$(nproc)"
    echo "  # SYCL FP16 backend (recommended — +49% faster prefill via oneMKL):"
    echo "  sudo tee /etc/yum.repos.d/oneAPI.repo <<< '[oneAPI]"
    echo "  name=Intel oneAPI"
    echo "  baseurl=https://yum.repos.intel.com/oneapi"
    echo "  enabled=1"
    echo "  gpgcheck=1"
    echo "  repo_gpgcheck=1"
    echo "  gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB'"
    echo "  sudo dnf install intel-oneapi-mkl-devel"
    echo "  source /opt/intel/oneapi/setvars.sh"
    echo "  cmake -B build-sycl -DGGML_SYCL=ON -DGGML_SYCL_F16=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DCMAKE_BUILD_TYPE=Release"
    echo "  cmake --build build-sycl -j\$(nproc)"
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
echo -e "${GREEN} Platform: ${PLATFORM_NAME}${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  [✓] System updated via nobara-sync"
echo "  [✓] GPU driver: $GPU_DRIVER (ID: 8086:$GPU_ID)"
echo "  [✓] InputPlumber masked"
echo "  [✓] Handheld Daemon (HHD) installed"
echo "  [✓] WiFi sleep fix installed (D3Cold + module reload)"
echo "  [✓] Hibernate disabled"
if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then
    if [ -f "$REAL_HOME/llama.cpp/build-sycl/bin/llama-server" ]; then
        echo "  [✓] llama.cpp built with SYCL FP16 backend (build-sycl/) ★ default"
    else
        echo "  [~] llama.cpp SYCL backend: build failed (Vulkan fallback available)"
    fi
    echo "  [✓] llama.cpp built with Vulkan backend (build/)"
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
    echo "  To start:  ~/run-model.sh              (SYCL FP16 — default, fastest)"
    echo "             ~/run-model.sh --vulkan     (Vulkan — fallback)"
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
