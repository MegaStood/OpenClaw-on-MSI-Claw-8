#!/bin/bash
# ============================================================
# MSI Claw Post-Install Script — vLLM Edition (Claw 8 AI+ / Claw A1M)
# Auto-detects hardware and adapts configuration accordingly
# Run this ONCE after first boot and WiFi connection
# Usage: chmod +x claw-post-install-vllm.sh && sudo bash claw-post-install-vllm.sh
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
echo -e "${GREEN} MSI Claw Post-Install Setup (vLLM)${NC}"
echo -e "${GREEN} Nobara Steam-Handheld Edition${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Detected: ${GREEN}${PLATFORM_NAME}${NC}"
echo "  CPU:      $CPU_MODEL ($CPU_THREADS threads)"
echo "  GPU:      $GPU_NAME (8086:$GPU_ID, driver: $GPU_DRIVER)"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo: sudo bash claw-post-install-vllm.sh${NC}"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~"$REAL_USER")

# ============================================================
# PHASE 0: Swap optimization
# ============================================================
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
ZRAM_ACTIVE=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -c zram || true)
DISK_SWAP_CREATED=false   # Tracks user's swap choice for MAX_JOBS in Step A
SWAPFILE="$REAL_HOME/swapfile"
FS_TYPE=$(df -T "$REAL_HOME" | awk 'NR==2{print $2}')

# Helper: create a disk swapfile if it doesn't already exist
create_swapfile() {
    local size="$1"
    if [ -f "$SWAPFILE" ]; then
        echo -e "${GREEN}  Swapfile already exists at $SWAPFILE. Activating.${NC}"
    else
        echo "  Creating ${size} disk swapfile..."
        if [ "$FS_TYPE" = "btrfs" ]; then
            btrfs filesystem mkswapfile --size "$size" "$SWAPFILE"
        else
            fallocate -l "$size" "$SWAPFILE"
            chmod 600 "$SWAPFILE"
            mkswap "$SWAPFILE"
        fi
    fi
}

if [ "$TOTAL_RAM_GB" -le 16 ]; then
    # ── Meteor Lake / 16GB ──────────────────────────────────
    # zram wastes precious RAM and the build WILL OOM without disk swap.
    # (Tested: peak 14GB RAM + 8GB swap during xpu-kernels compilation.)
    # No user prompt — this is required, not optional.
    if [ "$ZRAM_ACTIVE" -gt 0 ]; then
        echo -e "${YELLOW}[0/7] Swap optimization (16GB system)...${NC}"
        echo ""
        echo "  Replacing zram with 16GB disk swapfile (required for 16GB builds)."
        echo "  zram + 16GB RAM cannot survive the xpu-kernels compilation."
        echo ""

        echo "  Disabling zram permanently..."
        swapoff /dev/zram0 2>/dev/null || true
        zramctl --reset /dev/zram0 2>/dev/null || true
        systemctl mask systemd-zram-setup@zram0.service 2>/dev/null || true

        create_swapfile 16G
        swapon "$SWAPFILE"
        sysctl vm.swappiness=10
        echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf

        if ! grep -q "$SWAPFILE" /etc/fstab 2>/dev/null; then
            echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
        fi

        DISK_SWAP_CREATED=true
        echo -e "${GREEN}  zram permanently disabled, 16GB disk swapfile active.${NC}"
        echo "  To reverse: sudo swapoff $SWAPFILE && sudo systemctl unmask systemd-zram-setup@zram0.service"
        echo ""
    fi

elif [ "$TOTAL_RAM_GB" -le 32 ]; then
    # ── Lunar Lake / 32GB ───────────────────────────────────
    # zram is fine for daily use. Temporarily disable it during the build,
    # and create a permanent low-priority disk swapfile as overflow.
    echo -e "${YELLOW}[0/7] Swap optimization (32GB system)...${NC}"
    echo ""

    # Create persistent disk swapfile if not already present
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q "$SWAPFILE"; then
        echo "  A 32GB disk swapfile provides a safety net for heavy builds"
        echo "  and LLM inference, without replacing zram for daily use."
        echo "  zram stays active after reboot (higher priority = used first)."
        echo "  The disk swapfile only kicks in when zram overflows."
        echo ""
        read -p "  Create 32GB disk swapfile as overflow? (y/n): " SWAP_CHOICE

        if [ "$SWAP_CHOICE" = "y" ] || [ "$SWAP_CHOICE" = "Y" ]; then
            create_swapfile 32G
            # Low priority (10) so zram (default ~100) is preferred after reboot
            swapon --priority 10 "$SWAPFILE"

            if ! grep -q "$SWAPFILE" /etc/fstab 2>/dev/null; then
                echo "$SWAPFILE none swap pri=10 0 0" >> /etc/fstab
            fi

            DISK_SWAP_CREATED=true
            echo -e "${GREEN}  32GB disk swapfile active (priority 10, below zram).${NC}"
        else
            echo "  Skipping disk swapfile."
        fi
    else
        echo -e "${GREEN}  Disk swapfile already active. Skipping.${NC}"
    fi

    # Temporarily disable zram for the build to free all 32GB RAM
    if [ "$ZRAM_ACTIVE" -gt 0 ]; then
        echo "  Temporarily disabling zram for the build (returns on reboot)..."
        swapoff /dev/zram0 2>/dev/null || true
        zramctl --reset /dev/zram0 2>/dev/null || true
        echo -e "${GREEN}  zram disabled for this session. It will return after reboot.${NC}"
    fi
    echo ""
fi

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
# PHASE 6: Build vLLM from llm-scaler (XPU native)
# ============================================================
echo -e "${YELLOW}[6/7] vLLM setup (native XPU build from llm-scaler)...${NC}"
echo ""
echo "  vLLM provides an OpenAI-compatible API server with Intel XPU acceleration."
echo "  Building natively from the llm-scaler fork with multi-Arc GPU support."
echo ""

# ----------------------------------------------------------
# Step A: Auto-detect MAX_JOBS based on available RAM
# ----------------------------------------------------------
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM_GB" -le 16 ]; then
    export MAX_JOBS=3   # Claw A1M (16GB)
elif [ "$TOTAL_RAM_GB" -le 32 ]; then
    if [ "$DISK_SWAP_CREATED" = true ]; then
        export MAX_JOBS=6   # Claw 8 AI+ (32GB) — disk swap available as overflow
    else
        export MAX_JOBS=4   # zram active, less usable RAM for compilation
    fi
else
    export MAX_JOBS=8
fi
echo "  RAM detected: ${TOTAL_RAM_GB}GB → MAX_JOBS=$MAX_JOBS"

# Create model directory with correct ownership
echo "  Setting up model directories..."
mkdir -p /shared/models
chown -R "$REAL_USER:$REAL_USER" /shared/models

read -p "  Install vLLM + AI tools? (y/n): " INSTALL_AI

if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then

    # ----------------------------------------------------------
    # Step B: Ensure llm-scaler repo exists
    # ----------------------------------------------------------
    if [ ! -d "$REAL_HOME/llm-scaler" ]; then
        echo "  Cloning llm-scaler repo..."
        sudo -u "$REAL_USER" git clone https://github.com/MegaStood/llm-scaler.git "$REAL_HOME/llm-scaler"
    else
        echo -e "${GREEN}  llm-scaler repo already present at ~/llm-scaler${NC}"
    fi

    # ----------------------------------------------------------
    # Step C: Install system dependencies
    # ----------------------------------------------------------
    echo ""
    echo "  Installing system build dependencies..."
    dnf install -y cmake gcc gcc-c++ git \
        numactl wget curl vim ffmpeg libsndfile-devel \
        libSM libXext libaio-devel mesa-libGL nvtop 2>&1 | tail -1

    # vLLM + intel_extension_for_pytorch require Python 3.12 (cp312 wheels).
    # Nobara 43 ships Python 3.14 — install 3.12 alongside it.
    # Separate dnf call so a failure here is not hidden by --skip-broken.
    if ! command -v python3.12 &>/dev/null; then
        echo "  Installing Python 3.12 (required for vLLM XPU wheels)..."
        dnf install -y python3.12 python3.12-devel
    else
        echo "  Python 3.12 already installed: $(python3.12 --version)"
    fi

    # ----------------------------------------------------------
    # Step C2: Create Python 3.12 virtual environment
    # ----------------------------------------------------------
    VLLM_VENV="$REAL_HOME/vllm-venv"
    if [ -d "$VLLM_VENV" ] && [ -f "$VLLM_VENV/bin/python" ]; then
        echo -e "${GREEN}  Python 3.12 venv already exists at $VLLM_VENV${NC}"
    else
        echo "  Creating Python 3.12 virtual environment at $VLLM_VENV..."
        sudo -u "$REAL_USER" python3.12 -m venv "$VLLM_VENV"
    fi
    # Activate venv — all pip/python commands below use Python 3.12
    source "$VLLM_VENV/bin/activate"

    # Redirect pip temp files to disk — /tmp is a tmpfs (RAM-backed, ~7.6GB)
    # and large XPU wheels will fill it, causing "No space left on device".
    export TMPDIR="$REAL_HOME/.pip-tmp"
    mkdir -p "$TMPDIR"
    chown "$REAL_USER:$REAL_USER" "$TMPDIR"

    # Clean corrupted pip temp directories from previous interrupted upgrades
    # (causes "WARNING: Ignoring invalid distribution ~..." on every pip command)
    find "$VLLM_VENV" -type d -name '~*' -exec rm -rf {} + 2>/dev/null || true

    pip install --upgrade pip setuptools wheel 2>&1 | tail -1
    echo "  Using Python: $(python --version) from $(which python)"

    # ----------------------------------------------------------
    # Step D: Install Intel oneAPI DPCPP-CT
    # ----------------------------------------------------------
    echo "  Setting up Intel oneAPI repository..."
    if [ ! -f /etc/yum.repos.d/oneAPI.repo ]; then
        cat > /etc/yum.repos.d/oneAPI.repo << 'ONEAPI_REPO'
[oneAPI]
name=Intel oneAPI repository
baseurl=https://yum.repos.intel.com/oneapi
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
ONEAPI_REPO
        echo -e "${GREEN}  oneAPI repo added.${NC}"
    else
        echo "  oneAPI repo already configured."
    fi

    echo "  Installing Intel DPC++ compiler + compatibility tool (this may take a while)..."
    dnf install -y intel-oneapi-dpcpp-cpp intel-oneapi-dpcpp-ct 2>&1 | tail -3

    # ----------------------------------------------------------
    # Step E: Set build environment variables
    # ----------------------------------------------------------
    echo "  Configuring build environment..."
    export VLLM_TARGET_DEVICE=xpu
    export VLLM_WORKER_MULTIPROC_METHOD=spawn
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib/"

    # Source oneAPI environment
    if [ -f /opt/intel/oneapi/setvars.sh ]; then
        source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
    else
        echo -e "${RED}  Warning: /opt/intel/oneapi/setvars.sh not found. Build may fail.${NC}"
    fi

    # Set CPATH for DPCPP-CT headers
    # Find the installed dpcpp-ct version dynamically
    DPCPP_INCLUDE=$(find /opt/intel/oneapi/dpcpp-ct/ -maxdepth 2 -name "include" -type d 2>/dev/null | head -1)
    if [ -n "$DPCPP_INCLUDE" ]; then
        export CPATH="${DPCPP_INCLUDE}:${CPATH:-}"
        echo "  DPCPP include path: $DPCPP_INCLUDE"
    else
        echo -e "${YELLOW}  Warning: Could not find dpcpp-ct include directory.${NC}"
    fi

    # ----------------------------------------------------------
    # Step F: Clone and patch vLLM
    # ----------------------------------------------------------
    INSTALL_DIR="$REAL_HOME"
    VLLM_DIR="$INSTALL_DIR/vllm"

    if [ -d "$VLLM_DIR" ] && [ -f "$VLLM_DIR/setup.py" ]; then
        echo -e "${GREEN}  vLLM source already present at $VLLM_DIR. Skipping clone.${NC}"
        echo "  To rebuild from scratch: rm -rf ~/vllm && re-run this script."
    else
        echo "  Cloning vLLM v0.14.0..."
        sudo -u "$REAL_USER" git clone -b v0.14.0 https://github.com/vllm-project/vllm.git "$VLLM_DIR"
    fi

    # Apply patch idempotently: check first, apply if clean, skip if already applied
    PATCH_FILE="$REAL_HOME/llm-scaler/vllm/patches/vllm_for_multi_arc.patch"
    cd "$VLLM_DIR"
    if sudo -u "$REAL_USER" git apply --check "$PATCH_FILE" 2>/dev/null; then
        echo "  Applying multi-Arc GPU patch from llm-scaler..."
        sudo -u "$REAL_USER" git apply "$PATCH_FILE"
    else
        echo -e "${GREEN}  Multi-Arc patch already applied (or source modified). Skipping.${NC}"
    fi

    # ----------------------------------------------------------
    # Step G: Build vLLM (MAX_JOBS controls parallelism)
    # ----------------------------------------------------------
    VLLM_CHECK=$(pip show vllm 2>/dev/null | grep -c "Name: vllm" || true)
    if [ "$VLLM_CHECK" -gt 0 ]; then
        echo -e "${GREEN}  vLLM already installed in venv. Skipping build.${NC}"
        echo "  To rebuild: source ~/vllm-venv/bin/activate && pip uninstall vllm -y && re-run this script."
    else
        echo ""
        echo "  Building vLLM with MAX_JOBS=$MAX_JOBS (this will take a while)..."
        echo "  With MAX_JOBS=$MAX_JOBS this can take $([ "$MAX_JOBS" -le 3 ] && echo '90-120' || echo '45-70') minutes. Do not interrupt."
        echo ""
        cd "$VLLM_DIR"

        echo "  Installing XPU requirements..."
        pip install -r requirements/xpu.txt 2>&1 | tail -3

        echo "  Installing arctic-inference..."
        pip install arctic-inference==0.1.1 2>&1 | tail -1

        echo "  Building and installing vLLM (MAX_JOBS=$MAX_JOBS)..."
        pip install --no-build-isolation . 2>&1 | tail -5

        if pip show vllm &>/dev/null; then
            echo -e "${GREEN}  vLLM built and installed successfully.${NC}"
        else
            echo -e "${RED}  vLLM build failed. Check errors above.${NC}"
            echo "  You can retry manually:"
            echo "    source ~/vllm-venv/bin/activate"
            echo "    cd ~/vllm && MAX_JOBS=$MAX_JOBS pip install --no-build-isolation ."
        fi
    fi

    # ----------------------------------------------------------
    # Step H: Install additional Python dependencies
    # ----------------------------------------------------------
    echo "  Installing additional Python dependencies..."
    pip install accelerate hf_transfer 'modelscope!=1.15.0' 2>&1 | tail -1
    pip install librosa soundfile decord 2>&1 | tail -1
    pip install git+https://github.com/huggingface/transformers.git 2>&1 | tail -1
    pip install ijson bigdl-core==2.4.0b2 2>&1 | tail -1
    echo -e "${GREEN}  Additional dependencies installed.${NC}"

    # ----------------------------------------------------------
    # Step I: Build vllm-xpu-kernels
    # ----------------------------------------------------------
    XPU_KERNELS_DIR="$INSTALL_DIR/vllm-xpu-kernels"
    XPU_KERNELS_CHECK=$(pip show vllm-xpu-kernels 2>/dev/null | grep -c "Name:" || true)

    if [ "$XPU_KERNELS_CHECK" -gt 0 ]; then
        echo -e "${GREEN}  vllm-xpu-kernels already installed. Skipping.${NC}"
    else
        echo "  Building vllm-xpu-kernels..."
        if [ ! -d "$XPU_KERNELS_DIR" ]; then
            sudo -u "$REAL_USER" git clone https://github.com/vllm-project/vllm-xpu-kernels.git "$XPU_KERNELS_DIR"
        fi
        cd "$XPU_KERNELS_DIR"
        sudo -u "$REAL_USER" git checkout 4c83144 2>/dev/null || true

        # Clean stale build artifacts from previous failed runs to avoid
        # permission errors or stale object files
        if [ -d "$XPU_KERNELS_DIR/build" ]; then
            echo "  Cleaning stale build directory..."
            rm -rf "$XPU_KERNELS_DIR/build"
        fi

        # Comment out conflicting pinned deps in requirements.txt
        sed -i 's|^--extra-index-url=https://download.pytorch.org/whl/xpu|# --extra-index-url=https://download.pytorch.org/whl/xpu|' requirements.txt
        sed -i 's|^torch==2.10.0+xpu|# torch==2.10.0+xpu|' requirements.txt
        sed -i 's|^triton-xpu|# triton-xpu|' requirements.txt
        sed -i 's|^transformers|# transformers|' requirements.txt

        # Fix ownership — sed runs as root can leave root-owned files
        chown -R "$REAL_USER:$REAL_USER" "$XPU_KERNELS_DIR"

        # All pip commands run as REAL_USER to prevent root-owned build artifacts.
        # If build/ is owned by root, the final wheel packaging step fails with
        # "Permission denied" after hours of compilation.
        XPU_BUILD_LOG="$REAL_HOME/.pip-tmp/xpu-kernels-build.log"
        mkdir -p "$REAL_HOME/.pip-tmp"
        chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.pip-tmp"

        sudo -u "$REAL_USER" bash -c "source $VLLM_VENV/bin/activate && source /opt/intel/oneapi/setvars.sh --force 2>/dev/null && cd $XPU_KERNELS_DIR && pip install -r requirements.txt 2>&1 | tail -1"

        echo ""
        if [ "$MAX_JOBS" -le 3 ]; then
            BUILD_EST="90-120 minutes (3 workers / 16GB)"
        else
            BUILD_EST="45-70 minutes ($MAX_JOBS workers / ${TOTAL_RAM_GB}GB)"
        fi
        echo -e "${YELLOW}  ┌─────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}  │  Compiling vllm-xpu-kernels (oneDNN + SYCL kernels)...      │${NC}"
        echo -e "${YELLOW}  │  The terminal may appear frozen — this is normal.            │${NC}"
        echo -e "${YELLOW}  │  DO NOT close this window or press Ctrl+C.                   │${NC}"
        echo -e "${YELLOW}  └─────────────────────────────────────────────────────────────┘${NC}"
        echo -e "${YELLOW}  Estimated time: ${BUILD_EST}${NC}"
        echo ""

        # Build as REAL_USER. Capture exit code via a temp file since the pipe
        # (for progress display) runs in a subshell and hides the real exit code.
        XPU_EXIT_FILE="$REAL_HOME/.pip-tmp/xpu-build-exit"
        sudo -u "$REAL_USER" bash -c "
            source $VLLM_VENV/bin/activate
            source /opt/intel/oneapi/setvars.sh --force 2>/dev/null
            export MAX_JOBS=$MAX_JOBS
            export TMPDIR=$REAL_HOME/.pip-tmp
            cd $XPU_KERNELS_DIR
            pip install --no-build-isolation -v . 2>&1 | tee $XPU_BUILD_LOG
            echo \${PIPESTATUS[0]} > $XPU_EXIT_FILE
        " | while IFS= read -r line; do
            if [[ "$line" =~ \[([0-9]+)/([0-9]+)\] ]]; then
                printf "\r  Compiling: [%s/%s] files..." "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
            fi
        done
        echo ""  # newline after progress

        XPU_BUILD_EXIT=$(cat "$XPU_EXIT_FILE" 2>/dev/null || echo 1)
        rm -f "$XPU_EXIT_FILE"

        if [ "$XPU_BUILD_EXIT" -eq 0 ] && sudo -u "$REAL_USER" bash -c "source $VLLM_VENV/bin/activate && pip show vllm-xpu-kernels &>/dev/null"; then
            echo -e "${GREEN}  vllm-xpu-kernels built successfully.${NC}"
            rm -f "$XPU_BUILD_LOG"
        else
            echo -e "${RED}  vllm-xpu-kernels build failed. Last 20 lines of build log:${NC}"
            tail -20 "$XPU_BUILD_LOG" 2>/dev/null | sed 's/^/    /'
            echo ""
            echo "  Full log: $XPU_BUILD_LOG"
        fi
    fi

    # ----------------------------------------------------------
    # Step J: Fix triton
    # ----------------------------------------------------------
    echo "  Fixing triton installation..."
    pip uninstall triton triton-xpu -y 2>/dev/null || true
    pip install triton-xpu==3.6.0 --extra-index-url=https://download.pytorch.org/whl/test/xpu 2>&1 | tail -1
    echo -e "${GREEN}  triton-xpu installed.${NC}"

    # ----------------------------------------------------------
    # Step K: Configure production environment in ~/.bashrc
    # ----------------------------------------------------------
    echo "  Configuring vLLM environment in ~/.bashrc..."
    BASHRC="$REAL_HOME/.bashrc"

    # Find the python site-packages path for the quantization library (inside venv)
    SITE_PACKAGES=$(python -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "$VLLM_VENV/lib/python3.12/site-packages")
    Q40_LIB="${SITE_PACKAGES}/vllm_int4_for_multi_arc.so"

    if ! grep -q "VLLM_TARGET_DEVICE" "$BASHRC" 2>/dev/null; then
        cat >> "$BASHRC" << VLLM_ENV

# vLLM XPU environment (added by claw-post-install-vllm.sh)
# oneAPI must be sourced FIRST — it resets LD_LIBRARY_PATH to its own paths.
# Our exports below then append to it rather than being overwritten.
source /opt/intel/oneapi/setvars.sh --force 2>/dev/null || true
source ${VLLM_VENV}/bin/activate
export VLLM_TARGET_DEVICE=xpu
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export VLLM_QUANTIZE_Q40_LIB="${Q40_LIB}"
export VLLM_OFFLOAD_WEIGHTS_BEFORE_QUANT=1
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH}:/usr/local/lib/"
VLLM_ENV
        echo -e "${GREEN}  vLLM env vars added to ~/.bashrc${NC}"
    else
        echo "  vLLM env vars already in ~/.bashrc, skipping."
    fi

    # ----------------------------------------------------------
    # Step L: Model selection and download
    # ----------------------------------------------------------
    echo ""
    DOWNLOAD_SCRIPT="$REAL_HOME/OpenClaw-on-MSI-Claw-8/scripts/download_model_fast.sh"

    if [ "$PLATFORM" = "lunar_lake" ] || [ "$TOTAL_RAM_GB" -gt 24 ]; then
        # 32GB platform menu
        echo "  ┌─────────────────────────────────────────────────────────────────┐"
        echo "  │              Choose a model to download (32GB)                  │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │  LOCAL MODELS (safetensors, served via vLLM XPU)               │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │                                                                 │"
        echo "  │  1) gpt-oss-20b (MXFP4, MoE 20B/3.6B)  [~13GB] RECOMMENDED   │"
        echo "  │     Intel's open MoE model, optimized for Arc XPU.             │"
        echo "  │     Best performance/quality on 32GB Claw 8 AI+.               │"
        echo "  │                                                                 │"
        echo "  │  2) Qwen3.5-4B                           [~3GB]  LIGHTWEIGHT   │"
        echo "  │     Dense 4B fallback. Fast, low memory.                       │"
        echo "  │                                                                 │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │  CLOUD OPTIONS (configure after install)                        │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │                                                                 │"
        echo "  │  3) Anthropic API     [requires API key from console.anthropic] │"
        echo "  │  4) Remote vLLM server (e.g., DGX Spark on local network)      │"
        echo "  │  5) Skip — I'll download models manually later                 │"
        echo "  │                                                                 │"
        echo "  └─────────────────────────────────────────────────────────────────┘"
        echo ""
        read -p "  Choose [1-5]: " MODEL_CHOICE

        case $MODEL_CHOICE in
            1)
                MODEL_DISPLAY="gpt-oss-20b (MXFP4 MoE)"
                echo "  Downloading gpt-oss-20b (~13GB, this may take a while)..."
                sudo -u "$REAL_USER" bash "$DOWNLOAD_SCRIPT" Intel/gpt-oss-20b
                PULLED_MODEL="local"
                ;;
            2)
                MODEL_DISPLAY="Qwen3.5-4B"
                echo "  Downloading Qwen3.5-4B (~3GB)..."
                sudo -u "$REAL_USER" bash "$DOWNLOAD_SCRIPT" Qwen/Qwen3.5-4B
                PULLED_MODEL="local"
                ;;
            3)
                MODEL_DISPLAY="Anthropic API"
                PULLED_MODEL="anthropic-api"
                echo ""
                echo -e "${GREEN}  Anthropic API selected as cloud backend.${NC}"
                echo "  Get your API key from: https://console.anthropic.com"
                ;;
            4)
                MODEL_DISPLAY="Remote vLLM server"
                PULLED_MODEL="remote-server"
                echo ""
                echo -e "${GREEN}  Remote vLLM server selected.${NC}"
                echo "  Point your client to: http://YOUR_SERVER_IP:8000/v1"
                ;;
            5|*)
                MODEL_DISPLAY="none"
                PULLED_MODEL="none"
                ;;
        esac
    else
        # 16GB platform menu
        echo "  ┌─────────────────────────────────────────────────────────────────┐"
        echo "  │              Choose a model to download (16GB)                  │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │  LOCAL MODELS (safetensors, served via vLLM XPU)               │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │                                                                 │"
        echo "  │  1) Qwen3.5-4B        [~3GB]  RECOMMENDED for 16GB            │"
        echo "  │     Dense 4B. Best safe choice for 16GB RAM.                   │"
        echo "  │                                                                 │"
        echo "  │  2) Qwen3.5-1.7B      [~1.5GB]  ULTRA-LIGHTWEIGHT             │"
        echo "  │     Dense 1.7B. Minimal memory footprint.                      │"
        echo "  │                                                                 │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │  CLOUD OPTIONS (configure after install)                        │"
        echo "  ├─────────────────────────────────────────────────────────────────┤"
        echo "  │                                                                 │"
        echo "  │  3) Anthropic API     [requires API key from console.anthropic] │"
        echo "  │  4) Remote vLLM server (e.g., DGX Spark on local network)      │"
        echo "  │  5) Skip — I'll download models manually later                 │"
        echo "  │                                                                 │"
        echo "  └─────────────────────────────────────────────────────────────────┘"
        echo ""
        echo -e "${YELLOW}  Note: 16GB RAM limits you to 4B models or smaller with vLLM.${NC}"
        echo ""
        read -p "  Choose [1-5]: " MODEL_CHOICE

        case $MODEL_CHOICE in
            1)
                MODEL_DISPLAY="Qwen3.5-4B"
                echo "  Downloading Qwen3.5-4B (~3GB)..."
                sudo -u "$REAL_USER" bash "$DOWNLOAD_SCRIPT" Qwen/Qwen3.5-4B
                PULLED_MODEL="local"
                ;;
            2)
                MODEL_DISPLAY="Qwen3.5-1.7B"
                echo "  Downloading Qwen3.5-1.7B (~1.5GB)..."
                sudo -u "$REAL_USER" bash "$DOWNLOAD_SCRIPT" Qwen/Qwen3.5-1.7B
                PULLED_MODEL="local"
                ;;
            3)
                MODEL_DISPLAY="Anthropic API"
                PULLED_MODEL="anthropic-api"
                echo ""
                echo -e "${GREEN}  Anthropic API selected as cloud backend.${NC}"
                echo "  Get your API key from: https://console.anthropic.com"
                ;;
            4)
                MODEL_DISPLAY="Remote vLLM server"
                PULLED_MODEL="remote-server"
                echo ""
                echo -e "${GREEN}  Remote vLLM server selected.${NC}"
                echo "  Point your client to: http://YOUR_SERVER_IP:8000/v1"
                ;;
            5|*)
                MODEL_DISPLAY="none"
                PULLED_MODEL="none"
                ;;
        esac
    fi

    # Fix ownership of downloaded files
    chown -R "$REAL_USER:$REAL_USER" /shared/models

    if [ "$PULLED_MODEL" = "local" ]; then
        echo -e "${GREEN}  Downloaded $MODEL_DISPLAY to /shared/models/${NC}"
    elif [ "$PULLED_MODEL" = "none" ]; then
        echo -e "${GREEN}  vLLM installed. No model downloaded.${NC}"
        echo "  Download models later with:"
        echo "    ~/OpenClaw-on-MSI-Claw-8/scripts/download_model_fast.sh <repo_id>"
    fi

    # Clean up pip temp directory
    rm -rf "$TMPDIR"
    unset TMPDIR

else
    PULLED_MODEL="skipped"
    echo "  Skipping vLLM. You can install later by re-running this script."
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
    echo "  [✓] vLLM built with XPU acceleration (MAX_JOBS=$MAX_JOBS)"
    echo "  [✓] vLLM install: ~/vllm"
    echo "  [✓] vllm-xpu-kernels built"
    echo "  [✓] triton-xpu installed"
    case $PULLED_MODEL in
        local)
            echo "  [✓] Downloaded $MODEL_DISPLAY to /shared/models/"
            ;;
        anthropic-api)
            echo "  [✓] Anthropic API selected — configure key in your client"
            ;;
        remote-server)
            echo "  [✓] Remote vLLM server selected — configure endpoint in your client"
            ;;
        none)
            echo "  [✓] No model downloaded yet — use download_model_fast.sh later"
            ;;
    esac
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  Quick Start — vLLM                                            │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  Serve a model:                                                 │"
    echo "  │    source ~/vllm-venv/bin/activate                              │"
    echo "  │    source /opt/intel/oneapi/setvars.sh                          │"
    echo "  │    vllm serve /shared/models/<model> \\                         │"
    echo "  │      --device xpu --gpu-memory-utilization 0.6 --enforce-eager  │"
    echo "  │                                                                 │"
    echo "  │  API endpoint:  http://127.0.0.1:8000/v1/chat/completions      │"
    echo "  │                                                                 │"
    echo "  │  Download models:                                               │"
    echo "  │    ~/OpenClaw-on-MSI-Claw-8/scripts/download_model_fast.sh \\   │"
    echo "  │      <repo_id>                                                  │"
    echo "  │                                                                 │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    if [ "$TOTAL_RAM_GB" -le 16 ]; then
        echo -e "${YELLOW}  Memory note (16GB): Only 4B models or smaller are safe.${NC}"
        echo -e "${YELLOW}  Larger models will OOM. Use --gpu-memory-utilization 0.5${NC}"
    else
        echo -e "${YELLOW}  Memory note (32GB): Up to 20B MoE models (e.g., gpt-oss-20b).${NC}"
        echo -e "${YELLOW}  Dense models beyond 7B may require weight offloading.${NC}"
    fi
fi
echo ""
echo -e "${YELLOW}After reboot, verify:${NC}"
echo "  1. Controller works in Desktop Mode"
echo "  2. Sleep/wake works and WiFi reconnects"
echo "  3. Sound plays through speakers"
echo "  4. GPU driver: lspci -k | grep -EA3 'VGA|3D|Display'"
echo "  5. Switch to Gaming Mode and test Steam"
if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then
    echo "  6. Activate venv + oneAPI: source ~/vllm-venv/bin/activate && source /opt/intel/oneapi/setvars.sh"
    echo "     Then run: vllm serve /shared/models/<model> --device xpu"
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
