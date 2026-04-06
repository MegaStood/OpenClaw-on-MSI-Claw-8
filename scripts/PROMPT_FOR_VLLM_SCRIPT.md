# Prompt for Claude CLI: Create claw-post-install-vllm.sh

Copy this entire prompt and paste it to Claude CLI on the Claw A1M:

---

## Task

Create a new post-install script `~/OpenClaw-on-MSI-Claw-8/scripts/claw-post-install-vllm.sh` for building vLLM natively from the forked llm-scaler repo.

## Structure

The script should follow the EXACT same structure as `claw-post-install-llama.sh` for Phases 1-5 (copy them verbatim), then replace Phase 6 with vLLM build steps, and Phase 7 with vLLM-specific model download + summary.

### Phases 1-5: COPY FROM claw-post-install-llama.sh (identical)

- Hardware Detection block (Lunar Lake / Meteor Lake / unknown)
- Banner with platform info
- Root check (AFTER banner, not before)
- REAL_USER / REAL_HOME
- Phase 1: System Update (nobara-sync)
- Phase 2: GPU driver (xe force_probe with XE_RECOMMENDED check)
- Phase 3: InputPlumber + HHD
- Phase 4: WiFi sleep fix (with gaussian/NPU filter + d3cold sysfs check)
- Phase 5: Disable hibernate

### Phase 6: Build vLLM from llm-scaler (REPLACE the llama.cpp build)

Instead of building llama.cpp, build vLLM natively from `~/llm-scaler`. The build steps come from the llm-scaler Dockerfile at `~/llm-scaler/vllm/docker/Dockerfile` and our native install script at `~/llm-scaler/vllm/scripts/install_vllm_native.sh`. Key steps:

1. **RAM-based MAX_JOBS auto-detection** (CRITICAL for 16GB machines):
   ```bash
   TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
   if [ "$TOTAL_RAM_GB" -le 16 ]; then
       export MAX_JOBS=3   # Claw A1M (16GB)
   elif [ "$TOTAL_RAM_GB" -le 32 ]; then
       export MAX_JOBS=6   # Claw 8 AI+ (32GB)
   else
       export MAX_JOBS=8
   fi
   ```

2. **Install system dependencies** (Ubuntu/Nobara compatible):
   - Intel oneAPI repo + `intel-oneapi-dpcpp-ct`
   - For Nobara: use `dnf` not `apt`
   - Python 3.12, build tools, etc.

3. **Set environment variables**:
   ```bash
   export VLLM_TARGET_DEVICE=xpu
   export VLLM_WORKER_MULTIPROC_METHOD=spawn
   export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/local/lib/"
   source /opt/intel/oneapi/setvars.sh --force
   export CPATH=/opt/intel/oneapi/dpcpp-ct/2025.2/include/:${CPATH}
   ```

4. **Clone and patch vLLM** (from llm-scaler repo):
   ```bash
   # Use the user's forked llm-scaler repo (already cloned at ~/llm-scaler)
   VLLM_DIR="$INSTALL_DIR/vllm"
   git clone -b v0.14.0 https://github.com/vllm-project/vllm.git "$VLLM_DIR"
   cd "$VLLM_DIR"
   git apply ~/llm-scaler/vllm/patches/vllm_for_multi_arc.patch
   ```

5. **Build vLLM** (MAX_JOBS controls parallelism):
   ```bash
   pip install -r requirements/xpu.txt
   pip install arctic-inference==0.1.1
   pip install --no-build-isolation .
   ```

6. **Install additional deps**:
   ```bash
   pip install accelerate hf_transfer 'modelscope!=1.15.0'
   pip install librosa soundfile decord
   pip install git+https://github.com/huggingface/transformers.git
   pip install ijson bigdl-core==2.4.0b2
   ```

7. **Build vllm-xpu-kernels**:
   ```bash
   git clone https://github.com/vllm-project/vllm-xpu-kernels.git
   cd vllm-xpu-kernels && git checkout 4c83144
   # Comment out conflicting pinned deps in requirements.txt
   pip install -r requirements.txt
   pip install --no-build-isolation .
   ```

8. **Fix triton**:
   ```bash
   pip uninstall triton triton-xpu -y
   pip install triton-xpu==3.6.0 --extra-index-url=https://download.pytorch.org/whl/test/xpu
   ```

9. **Configure production env vars** in ~/.bashrc:
   ```bash
   export VLLM_TARGET_DEVICE=xpu
   export VLLM_WORKER_MULTIPROC_METHOD=spawn
   export VLLM_QUANTIZE_Q40_LIB="<python-site>/vllm_int4_for_multi_arc.so"
   export VLLM_OFFLOAD_WEIGHTS_BEFORE_QUANT=1
   export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
   ```

10. **Check if ~/llm-scaler exists**, if not, clone it:
    ```bash
    if [ ! -d "$REAL_HOME/llm-scaler" ]; then
        sudo -u "$REAL_USER" git clone https://github.com/MegaStood/llm-scaler.git "$REAL_HOME/llm-scaler"
    fi
    ```

### Phase 6b: Model Download (use download_model_fast.sh)

Use `~/OpenClaw-on-MSI-Claw-8/scripts/download_model_fast.sh` for downloading safetensors models to `/shared/models/`. The script supports parallel downloads and resumes.

Model menu should be platform-aware (like the ollama script):

**For Claw 8 AI+ (32GB):**
- gpt-oss-20b (MXFP4, MoE 20B/3.6B active) — RECOMMENDED, 13GB
- Qwen3.5-4B — lightweight fallback, 3GB

**For Claw A1M (16GB):**
- Qwen3.5-4B — RECOMMENDED, 3GB (only safe choice for 16GB)
- Qwen3.5-1.7B — ultra-lightweight, 1.5GB

**Cloud/Remote options:**
- Anthropic API
- Remote vLLM server (e.g., DGX Spark on local network)
- Skip

Download command format:
```bash
sudo -u "$REAL_USER" bash "$REAL_HOME/OpenClaw-on-MSI-Claw-8/scripts/download_model_fast.sh" <repo_id>
```

### Phase 7: Summary

Show:
- Platform detected
- MAX_JOBS used
- vLLM install location
- Model downloaded
- How to serve:
  ```bash
  source /opt/intel/oneapi/setvars.sh
  vllm serve /shared/models/<model> --device xpu --gpu-memory-utilization 0.6 --enforce-eager
  ```
- Memory notes per platform (16GB → 4B models only, 32GB → up to 20B MoE)

## Important Notes

- The script name is `claw-post-install-vllm.sh`
- Phases 1-5 MUST be identical to `claw-post-install-llama.sh` (read it and copy)
- Phase 6 uses `dnf` for system packages (this is Nobara/Fedora, not Ubuntu)
- The oneAPI packages may have different names on Nobara vs Ubuntu — handle both
- All builds must use MAX_JOBS (not nproc) to avoid OOM on 16GB
- The patch file is at `~/llm-scaler/vllm/patches/vllm_for_multi_arc.patch`
- Skip steps that are already done on re-run (check if dirs/files exist)
- After creating the script, commit and push to main

---

Delete this file after the CLI has created the script.
