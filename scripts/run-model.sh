#!/bin/bash
# run-model.sh — auto-discover and launch GGUF models via llama.cpp
#
# Usage:
#   ~/run-model.sh              # interactive menu → launch server
#   ~/run-model.sh 2            # directly load model #2
#   ~/run-model.sh --list       # list models and exit
#   ~/run-model.sh --kill       # stop running llama-server
#   ~/run-model.sh --bench-only # benchmark a model (no server)
#   ~/run-model.sh --detach     # run server in background
#   ~/run-model.sh --help       # show usage
#
# Behavior:
#   - Models >= 9B: reasoning ON, 32k context (agentic/tool-calling ready)
#   - Models < 9B:  reasoning OFF, 8k context (small models loop in thinking mode)
#   - Serves OpenAI-compatible API at http://127.0.0.1:8080/v1/chat/completions
#   - Built-in Web UI at http://127.0.0.1:8080

# ── Environment variable overrides ───────────────────────────────────────────
# Override these without editing the script:
#   MODEL_DIR=/other/path ~/run-model.sh
#   LLAMA_SERVER=/custom/path/llama-server ~/run-model.sh

MODEL_DIR="${MODEL_DIR:-/shared/models/gguf}"
LLAMA_SERVER="${LLAMA_SERVER:-$HOME/llama.cpp/build/bin/llama-server}"
LLAMA_BENCH="${LLAMA_BENCH:-$HOME/llama.cpp/build/bin/llama-bench}"
PIDFILE="${PIDFILE:-$HOME/.llama-server.pid}"
AVAILABLE_VRAM=24  # Arc 140V usable shared VRAM in GB

# ── Parse flags ──────────────────────────────────────────────────────────────

ACTION="serve"      # default action
DETACH=false
MODEL_NUM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS] [MODEL_NUMBER]"
            echo ""
            echo "Options:"
            echo "  --list         List available models and exit"
            echo "  --kill         Stop running llama-server"
            echo "  --bench-only   Benchmark a model without starting the server"
            echo "  --detach       Run server in background (returns immediately)"
            echo "  --help, -h     Show this help"
            echo ""
            echo "Environment variables:"
            echo "  MODEL_DIR      Model directory (default: /shared/models/gguf)"
            echo "  LLAMA_SERVER   llama-server path (default: ~/llama.cpp/build/bin/llama-server)"
            echo "  LLAMA_BENCH    llama-bench path (default: ~/llama.cpp/build/bin/llama-bench)"
            echo ""
            echo "Examples:"
            echo "  ~/run-model.sh              # interactive menu"
            echo "  ~/run-model.sh 3            # load model #3 directly"
            echo "  ~/run-model.sh --bench-only # pick a model and benchmark it"
            echo "  ~/run-model.sh --kill       # stop the server"
            exit 0
            ;;
        --list)
            ACTION="list"
            shift
            ;;
        --kill)
            ACTION="kill"
            shift
            ;;
        --bench-only)
            ACTION="bench"
            shift
            ;;
        --detach)
            DETACH=true
            shift
            ;;
        *)
            MODEL_NUM="$1"
            shift
            ;;
    esac
done

# ── Kill action (early exit) ─────────────────────────────────────────────────

if [ "$ACTION" = "kill" ]; then
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        PID=$(cat "$PIDFILE")
        kill "$PID"
        rm -f "$PIDFILE"
        echo "Stopped llama-server (PID: $PID)"
    elif pkill -f llama-server 2>/dev/null; then
        rm -f "$PIDFILE"
        echo "Stopped llama-server (found via pkill)"
    else
        echo "No llama-server running."
    fi
    exit 0
fi

# ── Preflight checks ────────────────────────────────────────────────────────

if [ "$ACTION" = "serve" ]; then
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
fi

if [ "$ACTION" = "bench" ]; then
    if [ ! -f "$LLAMA_BENCH" ]; then
        echo "Error: llama-bench not found at $LLAMA_BENCH"
        echo "It should be built alongside llama-server."
        exit 1
    fi
fi

if [ ! -d "$MODEL_DIR" ]; then
    echo "Error: Model directory $MODEL_DIR does not exist."
    echo "Create it with: sudo mkdir -p $MODEL_DIR && sudo chown \$USER:\$USER $MODEL_DIR"
    exit 1
fi

# ── Extract parameter count from filename ────────────────────────────────────
# Matches patterns like: 35B-A3B → 35, 24B-A2B → 24, 4B-UD → 4, 27B.Q4 → 27
# The 'B' must be followed by a separator (-, _, ., space) or uppercase letter
# to avoid matching version numbers like "4.6" in "Opus-4.6-Distill"

get_param_size() {
    local name
    name=$(basename "$1")
    # Match: separator-or-start, then DIGITS, then B/b, then separator-or-uppercase
    # Examples: -35B- → 35, .4B. → 4, -24B- → 24, -9b- → 9, -20b- → 20
    local size
    size=$(echo "$name" | grep -oiP '(?<=[-_. ])(\d+)(?=b[-_. A-Z])' | head -1)
    if [ -n "$size" ]; then
        printf "%.0f" "$size"
        return
    fi
    # Special case: GLM-style names where param count isn't in XB format
    # GLM-4.7-Flash = ~30B total params, 3B active
    if echo "$name" | grep -qi "GLM-4.7"; then
        echo 30
        return
    fi
    # Fallback: estimate from file size
    # Q4 quantization ≈ 0.5 GB per 1B total params
    local file_gb
    file_gb=$(du -BG "$1" | grep -oP '\d+' | head -1)
    echo $(( file_gb * 2 ))
}

# ── VRAM check ───────────────────────────────────────────────────────────────
# Warns if model file + estimated KV cache may exceed available VRAM.
# Uses actual file size instead of parameter-based formulas — accurate for
# any quantization format or architecture (dense, MoE, hybrid).

check_vram() {
    local model_path="$1"
    local context="$2"
    local file_gb
    file_gb=$(du -BG "$model_path" | grep -oP '\d+' | head -1)
    # Rough KV cache estimate: ~1GB per 16k context for typical models
    local kv_gb=$(( context / 16384 ))
    [ "$kv_gb" -lt 1 ] && kv_gb=1
    local total_needed=$(( file_gb + kv_gb ))

    if [ "$total_needed" -gt "$AVAILABLE_VRAM" ]; then
        echo ""
        echo "  WARNING: Model (${file_gb}GB) + KV cache (~${kv_gb}GB) = ~${total_needed}GB"
        echo "  Available VRAM: ~${AVAILABLE_VRAM}GB"
        echo "  Consider: --parallel 1, smaller context (-c), or a smaller model"
        echo ""
    fi
}

# ── Discover models ──────────────────────────────────────────────────────────

mapfile -t MODELS < <(find "$MODEL_DIR" -maxdepth 1 -name "*.gguf" -not -name ".*" | sort)

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "No .gguf models found in $MODEL_DIR"
    echo ""
    echo "Download models from https://huggingface.co and place .gguf files in $MODEL_DIR"
    echo "Example:"
    echo "  pip install huggingface-hub"
    echo "  huggingface-cli download unsloth/Qwen3.5-9B-UD-GGUF Qwen3.5-9B-UD-Q4_K_M.gguf \\"
    echo "    --local-dir $MODEL_DIR"
    exit 1
fi

# ── Display model list ───────────────────────────────────────────────────────

show_models() {
    echo ""
    echo "Available models:"
    echo "───────────────────────────────────────────────────────────────────────────────"
    for i in "${!MODELS[@]}"; do
        local name size params mode
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
}

# ── List action (early exit) ─────────────────────────────────────────────────

if [ "$ACTION" = "list" ]; then
    show_models
    exit 0
fi

# ── Model selection ──────────────────────────────────────────────────────────

if [ -z "$MODEL_NUM" ]; then
    show_models
    read -p "Select model (1-${#MODELS[@]}): " choice
else
    choice="$MODEL_NUM"
fi

# Validate selection
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#MODELS[@]} ]; then
    echo "Invalid selection: $choice"
    exit 1
fi

MODEL="${MODELS[$((choice-1))]}"
MODEL_NAME=$(basename "$MODEL")
PARAMS=$(get_param_size "$MODEL")

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

# Large models (>20B) need VRAM optimization:
# -ctk q8_0 -ctv q8_0: quantize KV cache to Q8 (~50% memory, <0.1% quality loss)
# --parallel 1: single slot only (not enough VRAM for multiple concurrent requests)
if [ "$PARAMS" -ge 20 ] 2>/dev/null; then
    VRAM_ARGS="-ctk q8_0 -ctv q8_0 --parallel 1"
else
    VRAM_ARGS=""
fi

# ── Benchmark action ─────────────────────────────────────────────────────────
# llama-bench is a separate binary that loads the model directly and runs
# standardized PP/TG speed tests. No server is started, no port is used.
# You can benchmark a model while another model is already serving on :8080.

if [ "$ACTION" = "bench" ]; then
    echo ""
    echo "Benchmarking: $MODEL_NAME"
    echo "───────────────────────────────────────────────────────────────────────────────"
    # -ngl 99: GPU offload all layers
    # -t 8:    8 threads (matching Lunar Lake 4P+4E)
    # -r 2:    repeat each test twice for reliable averages
    # -p:      prompt processing at 4 context sizes
    # -n:      token generation at 3 output lengths
    # -pg:     combined prompt+generation for realistic throughput
    "$LLAMA_BENCH" \
        -m "$MODEL" \
        -ngl 99 \
        -t 8 \
        -r 2 \
        -p 512,2048,8192,32768 \
        -n 128,256,512 \
        -pg 512,128 -pg 2048,128 -pg 8192,128
    exit $?
fi

# ── Check VRAM ───────────────────────────────────────────────────────────────

check_vram "$MODEL" "$CONTEXT"

# ── Check for already-running server ─────────────────────────────────────────

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    RUNNING_PID=$(cat "$PIDFILE")
    echo "llama-server already running (PID: $RUNNING_PID)"
    read -p "Kill it and load new model? (y/n): " KILL_EXISTING
    if [ "$KILL_EXISTING" = "y" ] || [ "$KILL_EXISTING" = "Y" ]; then
        kill "$RUNNING_PID"
        rm -f "$PIDFILE"
        sleep 1
    else
        echo "Aborted."
        exit 0
    fi
else
    # Clean up stale PID file
    rm -f "$PIDFILE"
    # Kill any orphaned llama-server processes
    pkill -f llama-server 2>/dev/null && sleep 1
fi

# ── Launch server ────────────────────────────────────────────────────────────

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
# --jinja: enables proper tool call format parsing (required for OpenClaw tool calling)

if [ "$DETACH" = true ]; then
    $LLAMA_SERVER \
        -m "$MODEL" \
        -ngl 99 \
        -t 8 \
        -c $CONTEXT \
        --jinja \
        $REASONING_ARGS \
        $VRAM_ARGS \
        > "$HOME/.llama-server.log" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PIDFILE"
    echo "Server started in background (PID: $SERVER_PID)"
    echo "Log: $HOME/.llama-server.log"
    echo "Stop: ~/run-model.sh --kill"
else
    # Foreground mode — write PID file, clean up on exit
    trap 'rm -f "$PIDFILE"' EXIT INT TERM
    $LLAMA_SERVER \
        -m "$MODEL" \
        -ngl 99 \
        -t 8 \
        -c $CONTEXT \
        --jinja \
        $REASONING_ARGS \
        $VRAM_ARGS &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PIDFILE"
    wait "$SERVER_PID"
fi
