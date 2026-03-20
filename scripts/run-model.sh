#!/bin/bash
# run-model.sh — auto-discover and launch GGUF models via llama.cpp
#
# Usage:
#   ~/run-model.sh          # interactive menu
#   ~/run-model.sh 2        # directly load model #2
#
# Setup:
#   1. Build llama.cpp with Vulkan:
#      sudo dnf install cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel shaderc
#      git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp
#      cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON
#      cmake --build build --config Release -j$(nproc)
#
#   2. Drop .gguf models into /shared/models/gguf/
#
#   3. Run this script: ~/run-model.sh
#
# Behavior:
#   - Models >= 9B: reasoning ON, 32k context (agentic/tool-calling ready)
#   - Models < 9B:  reasoning OFF, 8k context (small models loop in thinking mode)
#   - Serves OpenAI-compatible API at http://127.0.0.1:8080/v1/chat/completions
#   - Built-in Web UI at http://127.0.0.1:8080

MODEL_DIR="/shared/models/gguf"
LLAMA_SERVER="$HOME/llama.cpp/build/bin/llama-server"

# ── Preflight checks ──────────────────────────────────────────────────────────

if [ ! -f "$LLAMA_SERVER" ]; then
    echo "Error: llama-server not found at $LLAMA_SERVER"
    echo ""
    echo "Build llama.cpp with Vulkan support first:"
    echo "  sudo dnf install cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel shaderc"
    echo "  git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp"
    echo "  cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON"
    echo "  cmake --build build --config Release -j\$(nproc)"
    exit 1
fi

if [ ! -d "$MODEL_DIR" ]; then
    echo "Error: Model directory $MODEL_DIR does not exist."
    echo "Create it with: sudo mkdir -p $MODEL_DIR && sudo chown \$USER:\$USER $MODEL_DIR"
    exit 1
fi

# ── Extract parameter count from filename ─────────────────────────────────────

get_param_size() {
    local name=$(basename "$1")
    # Match the largest number followed by 'B' then a separator
    # e.g., 35B-A3B → 35, 24B-A2B → 24, 4B-UD → 4, 27B.Q4 → 27
    local size=$(echo "$name" | grep -oiP '\d+(\.\d+)?(?=B[-._])' | head -1)
    if [ -n "$size" ]; then
        printf "%.0f" "$size"
        return
    fi
    # Fallback: estimate from file size (Q4 ≈ 0.6 GB per 1B params)
    local file_gb=$(du -BG "$1" | cut -f1 | tr -dc '0-9')
    echo $(( file_gb * 10 / 6 ))
}

# ── Discover models ───────────────────────────────────────────────────────────

mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -name "*.gguf" -not -name ".*" | sort)

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "No .gguf models found in $MODEL_DIR"
    echo ""
    echo "Download models using the fast downloader:"
    echo "  scripts/download_model_fast.sh unsloth/Qwen3.5-9B-UD-GGUF --gguf Q4_K_M"
    echo ""
    echo "Or manually from https://huggingface.co — place .gguf files in $MODEL_DIR"
    exit 1
fi

# ── Interactive menu or direct selection ──────────────────────────────────────

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

# ── Validate selection ────────────────────────────────────────────────────────

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#MODELS[@]} ]; then
    echo "Invalid selection: $choice"
    exit 1
fi

MODEL="${MODELS[$((choice-1))]}"
MODEL_NAME=$(basename "$MODEL")
PARAMS=$(get_param_size "$MODEL")

# ── Action menu: Run or Bench ────────────────────────────────────────────────

LLAMA_BENCH="$HOME/llama.cpp/build/bin/llama-bench"

echo ""
echo "Selected: $MODEL_NAME (~${PARAMS}B)"
echo ""
echo "  1) Run model (start server)"
echo "  2) Benchmark model (llama-bench)"
echo ""
read -p "Action (1-2) [1]: " action
action="${action:-1}"

if [ "$action" = "2" ]; then
    # ── Benchmark mode ────────────────────────────────────────────────────────
    if [ ! -f "$LLAMA_BENCH" ]; then
        echo "Error: llama-bench not found at $LLAMA_BENCH"
        echo ""
        echo "Rebuild llama.cpp — llama-bench is included by default:"
        echo "  cd ~/llama.cpp && cmake -B build -DGGML_VULKAN=ON"
        echo "  cmake --build build --config Release -j\$(nproc)"
        exit 1
    fi

    echo ""
    echo "Benchmarking: $MODEL_NAME"
    echo "───────────────────────────────────────────────────────────────────────────────"
    echo ""

    # -ngl 99: offload all layers to GPU (Vulkan)
    # -t 8:    use all 8 threads
    # Runs prompt processing (pp) and text generation (tg) benchmarks
    $LLAMA_BENCH \
        -m "$MODEL" \
        -ngl 99 \
        -t 8 \
        -r 2 \
        -p 512,2048,8192,32768 \
        -n 0 \
        -pg 512,128 -pg 2048,128 -pg 8192,128

    exit 0
fi

# ── Configure reasoning and context ──────────────────────────────────────────
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

# ── Kill existing server and launch ──────────────────────────────────────────

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
