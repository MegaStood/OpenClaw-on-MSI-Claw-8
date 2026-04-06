#!/bin/bash
# ============================================================
# MSI Claw Post-Install Script (Claw 8 AI+ / Claw A1M)
# *** OLLAMA VERSION ***
# Auto-detects hardware and adapts configuration accordingly
# Run this ONCE after first boot and WiFi connection
# Usage: chmod +x claw-post-install-ollama.sh && sudo bash claw-post-install-ollama.sh
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
    echo -e "${RED}Please run with sudo: sudo bash claw-post-install-ollama.sh${NC}"
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
# PHASE 6: Install Ollama + OpenClaw (optional)
# ============================================================
echo -e "${YELLOW}[6/7] AI tools setup...${NC}"

# Create model directories with correct ownership
echo "  Setting up model directories..."
mkdir -p /shared/models/gguf
chown -R "$REAL_USER:$REAL_USER" /shared/models

read -p "  Install Ollama + OpenClaw for AI assistant? (y/n): " INSTALL_AI

if [ "$INSTALL_AI" = "y" ] || [ "$INSTALL_AI" = "Y" ]; then

    # Check if Ollama is properly installed (not just binary exists, but actually works)
    if command -v ollama &>/dev/null && ollama --version &>/dev/null; then
        OLLAMA_VER=$(ollama --version 2>/dev/null || echo "unknown")
        echo -e "${GREEN}  Ollama already installed ($OLLAMA_VER). Skipping installation.${NC}"
    else
        if command -v ollama &>/dev/null; then
            echo "  Ollama binary found but not functional. Reinstalling..."
        else
            echo "  Installing Ollama..."
        fi
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    echo ""
    # Platform-aware recommendations
    # Claw 8 AI+ (32GB): qwen3.5:9b (best multimodal all-rounder) + gemma4:26b (best reasoning/coding)
    # Claw A1M (16GB):   qwen3.5:4b (lightest) + gemma4:e4b (smartest small model)
    if [ "$PLATFORM" = "lunar_lake" ]; then
        REC_4B=""
        REC_GEMMA4_E4B=""
        REC_9B="★ RECOMMENDED — compact"
        REC_GEMMA4_26B="★ RECOMMENDED — reasoning"
    else
        REC_4B="★ RECOMMENDED — lightest"
        REC_GEMMA4_E4B="★ RECOMMENDED — smartest"
        REC_9B=""
        REC_GEMMA4_26B=""
    fi

    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │              Choose a model for OpenClaw                        │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  LOCAL MODELS (run on this device)                              │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    printf "  │  1) qwen3.5:4b        [2.7GB]  %-30s│\n" "$REC_4B"
    echo "  │     Dense 4B. Fastest inference, smallest footprint.            │"
    echo "  │     Leaves most RAM free for gaming + desktop. Text only.       │"
    echo "  │                                                                 │"
    printf "  │  2) gemma4:e4b        [9.6GB]  %-30s│\n" "$REC_GEMMA4_E4B"
    echo "  │     MoE 9.6B/4.5B active. Multimodal (text+image+audio).       │"
    echo "  │     128K context. Thinking mode + tool calling. Google Gemma 4. │"
    echo "  │                                                                 │"
    printf "  │  3) qwen3.5:9b        [6.6GB]  %-30s│\n" "$REC_9B"
    echo "  │     Dense 9B. Multimodal (text+image+video), tool calling,      │"
    echo "  │     thinking mode. 262K context. Best multimodal all-rounder.   │"
    echo "  │                                                                 │"
    printf "  │  4) gemma4:26b        [18GB]   %-30s│\n" "$REC_GEMMA4_26B"
    echo "  │     MoE 25.2B/3.8B active. Multimodal (text+image).            │"
    echo "  │     256K context. Top reasoning (88% AIME) + coding. Fast MoE.  │"
    echo "  │                                                                 │"
    echo "  │  5) gpt-oss:20b       [12GB]                                    │"
    echo "  │     MoE 20B/3.6B active. Most tested model in OpenClaw          │"
    echo "  │     community. Very reliable tool calling. Text only.            │"
    echo "  │                                                                 │"
    echo "  │  6) lfm2:24b          [14GB]                                    │"
    echo "  │     MoE 24B/2B active. Liquid AI hybrid architecture.           │"
    echo "  │     Designed for on-device. Fastest MoE inference. Tool calling. │"
    echo "  │     32K context (shorter than others). Text only.               │"
    echo "  │                                                                 │"
    echo "  │  7) glm-4.7-flash     [19GB]  ⚠ TIGHT ON RAM                   │"
    echo "  │     MoE 30B/3B active. Best agentic coding (59% SWE-bench).     │"
    echo "  │     Officially recommended by Ollama. Tool calling + thinking.   │"
    echo "  │                                                                 │"
    echo "  │  8) qwen3-coder:30b   [20GB]  ⚠ TIGHT ON RAM                   │"
    echo "  │     MoE 30B/3.3B active. Top coding + tool calling.             │"
    echo "  │     256K context. Best for code-heavy OpenClaw workflows.        │"
    echo "  │                                                                 │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  CLOUD MODELS (no local GPU needed, requires API key)           │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │                                                                 │"
    echo "  │  9) Ollama Cloud      [free tier available]                     │"
    echo "  │     Use kimi-k2.5:cloud, minimax-m2.5:cloud, or glm-5:cloud    │"
    echo "  │     via Ollama's built-in cloud. No local RAM used.             │"
    echo "  │                                                                 │"
    echo "  │ 10) Anthropic API     [requires API key from console.anthropic] │"
    echo "  │     Use Claude as cloud fallback. Best reasoning quality.        │"
    echo "  │     Set up in ~/.openclaw/openclaw.json after install.           │"
    echo "  │                                                                 │"
    echo "  │ 11) Remote vLLM/Ollama server on local network                  │"
    echo "  │     Point OpenClaw to a more powerful machine running vLLM.      │"
    echo "  │     Configure baseUrl in ~/.openclaw/openclaw.json after install.│"
    echo "  │                                                                 │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │ 12) Skip model pull — Install Ollama only, choose later.        │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}  Note: Options 7-8 use 19-20GB. With OpenClaw + desktop on 32GB shared${NC}"
    echo -e "${YELLOW}  memory, expect reduced performance. Options 9-11 offload to cloud/remote.${NC}"
    echo -e "${YELLOW}  ⚠ Ollama currently runs CPU-only on Intel iGPU (no Vulkan support).${NC}"
    echo -e "${YELLOW}  For GPU acceleration, use claw-post-install-llama.sh (llama.cpp version).${NC}"
    echo ""
    read -p "  Choose [1-12]: " MODEL_CHOICE

    case $MODEL_CHOICE in
        1)
            MODEL_NAME="qwen3.5:4b"
            MODEL_SIZE="2.7GB"
            ;;
        2)
            MODEL_NAME="gemma4:e4b"
            MODEL_SIZE="9.6GB"
            ;;
        3)
            MODEL_NAME="qwen3.5:9b"
            MODEL_SIZE="6.6GB"
            ;;
        4)
            MODEL_NAME="gemma4:26b"
            MODEL_SIZE="18GB"
            ;;
        5)
            MODEL_NAME="gpt-oss:20b"
            MODEL_SIZE="12GB"
            ;;
        6)
            MODEL_NAME="lfm2:24b"
            MODEL_SIZE="14GB"
            ;;
        7)
            MODEL_NAME="glm-4.7-flash"
            MODEL_SIZE="19GB"
            ;;
        8)
            MODEL_NAME="qwen3-coder:30b"
            MODEL_SIZE="20GB"
            ;;
        9)
            MODEL_NAME=""
            PULLED_MODEL="cloud"
            echo ""
            echo -e "${GREEN}  Ollama Cloud selected.${NC}"
            echo "  When you run 'ollama launch openclaw', select a cloud model"
            echo "  from the model picker (e.g., kimi-k2.5:cloud, minimax-m2.5:cloud)."
            echo "  Cloud models have full context length and need no local RAM."
            ;;
        10)
            MODEL_NAME=""
            PULLED_MODEL="anthropic-api"
            echo ""
            echo -e "${GREEN}  Anthropic API selected as cloud backend.${NC}"
            echo "  After running 'ollama launch openclaw', edit ~/.openclaw/openclaw.json:"
            echo ""
            echo '  "providers": {'
            echo '    "anthropic": {'
            echo '      "apiKey": "sk-ant-YOUR_KEY_HERE"'
            echo '    }'
            echo '  }'
            echo '  "agents": { "defaults": { "model": {'
            echo '    "primary": "anthropic/claude-sonnet-4-6"'
            echo '  }}}'
            echo ""
            echo "  Get your API key from: https://console.anthropic.com"
            ;;
        11)
            MODEL_NAME=""
            PULLED_MODEL="remote-server"
            echo ""
            echo -e "${GREEN}  Remote server selected.${NC}"
            echo "  After running 'ollama launch openclaw', edit ~/.openclaw/openclaw.json:"
            echo ""
            echo '  "providers": {'
            echo '    "remote": {'
            echo '      "baseUrl": "http://YOUR_SERVER_IP:8000/v1",'
            echo '      "apiKey": "EMPTY",'
            echo '      "api": "openai-completions"'
            echo '    }'
            echo '  }'
            echo '  "agents": { "defaults": { "model": {'
            echo '    "primary": "remote/YOUR_MODEL_NAME",'
            echo '    "fallback": "ollama/qwen3.5:9b"'
            echo '  }}}'
            echo ""
            echo "  Replace YOUR_SERVER_IP and YOUR_MODEL_NAME with your actual values."
            echo "  Check available models: curl http://YOUR_SERVER_IP:8000/v1/models"
            ;;
        12|*)
            MODEL_NAME=""
            PULLED_MODEL="none"
            ;;
    esac

    if [ -n "$MODEL_NAME" ]; then
        echo "  Pulling $MODEL_NAME ($MODEL_SIZE, this may take a while)..."
        sudo -u "$REAL_USER" ollama pull "$MODEL_NAME"
        PULLED_MODEL="$MODEL_NAME"
        echo -e "${GREEN}  Ollama installed with $MODEL_NAME.${NC}"
    elif [ "$PULLED_MODEL" = "none" ]; then
        echo -e "${GREEN}  Ollama installed. No model pulled.${NC}"
        echo "  Pull a model later with: ollama pull qwen3.5:9b"
    fi

    echo ""
    echo "  To launch OpenClaw (Ollama 0.17+ handles installation automatically):"
    echo "    ollama launch openclaw"
    echo ""
    echo "  To test Vulkan GPU acceleration:"
    echo "    OLLAMA_VULKAN=1 ollama serve"
else
    PULLED_MODEL="skipped"
    echo "  Skipping AI tools. You can install later with:"
    echo "    curl -fsSL https://ollama.com/install.sh | sh"
    echo "    ollama pull qwen3.5:9b        # local model"
    echo "    ollama launch openclaw         # starts OpenClaw"
    echo ""
    echo "  Or use cloud models (no local RAM needed):"
    echo "    ollama launch openclaw --model kimi-k2.5:cloud"
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
    case $PULLED_MODEL in
        cloud)
            echo "  [✓] Ollama installed (cloud model selected)"
            ;;
        anthropic-api)
            echo "  [✓] Ollama installed (Anthropic API — configure key in openclaw.json)"
            ;;
        remote-server)
            echo "  [✓] Ollama installed (remote server — configure baseUrl in openclaw.json)"
            ;;
        none)
            echo "  [✓] Ollama installed (no model pulled yet)"
            ;;
        *)
            echo "  [✓] Ollama installed with $PULLED_MODEL"
            ;;
    esac
    echo "  To start OpenClaw: ollama launch openclaw"
    echo ""
    echo -e "${YELLOW}  Note: Ollama currently runs CPU-only on Intel iGPU.${NC}"
    echo -e "${YELLOW}  For GPU acceleration, switch to the llama.cpp version:${NC}"
    echo -e "${YELLOW}  sudo bash claw-post-install-llama.sh${NC}"
fi
echo ""
echo -e "${YELLOW}After reboot, verify:${NC}"
echo "  1. Controller works in Desktop Mode"
echo "  2. Sleep/wake works and WiFi reconnects"
echo "  3. Sound plays through speakers"
echo "  4. GPU driver: lspci -k | grep -EA3 'VGA|3D|Display'"
echo "  5. Switch to Gaming Mode and test Steam"
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
