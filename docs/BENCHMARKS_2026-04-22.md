# vLLM 0.19.0 + XPU prefill/decode benchmarks on MSI Claw 8 (Arc 140V, Lunar Lake)

Single-query (`--max-concurrency 1 --num-prompts 1`) benchmarks of three 30B-class open-weight MoE models under vLLM 0.19.0+xpu / IPEX 2.10.10 on the MSI Claw 8's Arc 140V iGPU (28.6 GiB shared LPDDR5x, Xe2 LPG).

Date: 2026-04-22. Supersedes the 2026-04-21 measurements (which were polluted by prefix-cache reuse and cold-kernel JIT).

## Methodology

- **Per-shape warmup** (seed 9xx, 32-token output) before each measurement — pays XPU kernel compile cost outside the measurement window.
- **Shape-unique measurement seeds** (1024→101, 2048→201, 4096→301, 8192→401) so no two shapes share a leading token prefix → no prefix-cache hits between shapes.
- **Single fresh measurement per shape**, except anomalous cells retested with 3 additional seeds (7104/7204/7304 etc).
- **Output = 512 tokens** for every shape.
- All models: `--enforce-eager --max-num-seqs 1 --gpu-memory-utilization 0.70`.
- Fresh reboot between the previous session's polluted runs and these, to clear XPU L0 mappings.
- `sudo drop_caches` between server restarts to reclaim buff/cache that competes with XPU for LPDDR5x.

Raw bench outputs: `/tmp/clean-<label>-<IN>-512.txt`; retest outputs: `/tmp/retest-<label>-<shape>-seed<N>.txt`.

## Environment

| Component | Version |
|---|---|
| CPU / GPU | Intel Core Ultra 7 258V (Lunar Lake) / Arc 140V iGPU (Xe2 LPG) |
| RAM | 32 GiB LPDDR5x (shared system+GPU) |
| Kernel | Linux 6.19.11-201.nobara.fc43.x86_64 |
| vLLM | 0.19.0+xpu (llm-scaler-vllm-v19 tree, commit `2a69949bd`) |
| torch | 2.10.0+xpu |
| intel_extension_for_pytorch | 2.10.10.post1+xpu |
| oneAPI | 2025.3.1 |

## Models

| Model | Quantization | Source | Path |
|---|---|---|---|
| gpt-oss-20b | MXFP4 (native) | openai/gpt-oss-20b | `/shared/models/gpt-oss-20b` |
| qwen3-coder-30b-a3b | compressed-tensors AWQ gs=32 | cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit | `/shared/models/qwen3-coder-30b-a3b-instruct-awq-4bit` |
| qwen3-30b-a3b-instruct-2507 | compressed-tensors AWQ gs=32 | cyankiwi/Qwen3-30B-A3B-Instruct-2507-AWQ-4bit | `/shared/models/qwen3-30b-a3b-instruct-2507-awq-4bit` |

## Side-by-side — TTFT (prefill latency)

All at 32K max-model-len (gpt-oss 3 GiB KV, Qwen models 4 GiB).

| Shape | gpt-oss-20b | qwen3-coder-30b | qwen3-30b-2507 | Winner |
|---|---|---|---|---|
| 1024/512 | 954 ms | 1053 ms | **879 ms** | qwen3-2507 |
| 2048/512 | 1413 ms | 1954 ms | **1311 ms** | qwen3-2507 |
| 4096/512 | **2501 ms** | 5178 ms | 3904 ms | gpt-oss |
| 8192/512 | **5817 ms** | 19978 ms | 7988 ms | gpt-oss |

## Side-by-side — decode TPOT

| Shape | gpt-oss-20b | qwen3-coder-30b | qwen3-30b-2507 | Winner |
|---|---|---|---|---|
| 1024/512 | 44 ms | 39 ms | **38 ms** | qwen3-2507 |
| 2048/512 | 76 ms | 54 ms | **53 ms** | qwen3-2507 |
| 4096/512 | 70 ms | **60 ms** | 63 ms | qwen3-coder |
| 8192/512 | 74 ms | **66 ms** | 66 ms | tie |

Qwen-family wins decode across the board (~15% lower TPOT than gpt-oss).

## gpt-oss-20b max-model-len sensitivity

Separately benched the MXFP4 path at 16K / 32K / 64K to check if it has the same pathological scaling that the compressed-tensors AWQ path exhibited at 65K on 2026-04-21.

| Shape | 16K | 32K | 64K |
|---|---|---|---|
| TTFT 1024 | 988 ms | 954 ms | 1513 ms |
| TTFT 2048 | 1331 ms | 1413 ms | 1256 ms |
| TTFT 4096 | 2659 ms | 2501 ms | 2511 ms |
| TTFT 8192 | 6526 ms | 5817 ms | 5948 ms |

**gpt-oss MXFP4 is essentially insensitive to max-model-len** — variation is within single-sample noise. The pathology is **quantization-path-specific**: only the compressed-tensors WNA16 MoE path degrades with large KV pools, not the dedicated MXFP4 XPU backend (`vllm/model_executor/layers/fused_moe/mxfp4.py`).

## qwen-coder 8192 reproducible slowdown

The original first-pass `qwen-coder 8192/512` result (24072 ms) was confirmed with three fresh seeds:

| Seed | TTFT | TPOT |
|---|---|---|
| 7108 | 19978 ms | 68 ms |
| 7208 | 19513 ms | 70 ms |
| 7308 | 20516 ms | 68 ms |
| **Median** | **~20 s** | ~68 ms |

qwen-coder at 8192 takes **~2.5× longer** than qwen3-2507 at the same shape, despite identical architecture (Qwen3-MoE), quantization (compressed-tensors AWQ gs=32), hardware, and launcher config. The only difference is the weights.

**Hypothesis: MoE router distribution.** qwen-coder was fine-tuned on code, which has narrower token distributions than general-purpose instruct data. The router likely learned to concentrate traffic on a narrow subset of experts. At 8k prompts, this creates a straggler matmul that serializes the MoE step — no parallelism across experts helps when one expert handles most tokens. The ratio widens from 1.1× at 1k to 2.5× at 8k because attention compute grows quadratically but stays parallel, while the MoE straggler grows linearly but stays serialized. See `TROUBLESHOOTING.md` for deeper discussion.

Not verified by direct profiling. Would need per-layer MoE timing + router activation entropy measurements to confirm.

## Recommendations for OpenClaw on MSI Claw 8

| Use case | Model | Config | Notes |
|---|---|---|---|
| **Agent / tool-calling primary** | qwen3-30b-a3b-instruct-2507 | 32K ctx, 4 GiB KV | strongest published BFCL/tau-bench + fastest local TTFT + cleanest scaling |
| **Code generation (short/medium context)** | qwen3-coder-30b-a3b | 32K ctx, 4 GiB KV | code-tuned weights; keep prompts ≤ 4k to avoid the MoE routing penalty |
| **Long-context agent (≥ 8k)** | gpt-oss-20b | 32K or 64K ctx, 3 GiB KV | MXFP4 path stays fast at long prompts; max-model-len insensitive |
| **Deep reasoning / SWE-bench** | gpt-oss-20b | 64K ctx, `reasoning_effort=high` | only model with published 60.7% SWE-bench Verified |

## Launcher commands (one-liners)

**Qwen3-Instruct-2507 (tool/agent default):**
```bash
source /opt/intel/oneapi/setvars.sh --force && source ~/llm-scaler-vllm-v19/venv/bin/activate && \
  VLLM_TARGET_DEVICE=xpu VLLM_WORKER_MULTIPROC_METHOD=spawn \
  vllm serve /shared/models/qwen3-30b-a3b-instruct-2507-awq-4bit \
  --served-model-name qwen3-30b-2507 --tensor-parallel-size 1 --gpu-memory-utilization 0.70 \
  --enforce-eager --port 8080 --max-model-len 32768 --max-num-seqs 1 --kv-cache-memory-bytes 4294967296
```

**Qwen3-Coder (short-prompt coding):**
```bash
source /opt/intel/oneapi/setvars.sh --force && source ~/llm-scaler-vllm-v19/venv/bin/activate && \
  VLLM_TARGET_DEVICE=xpu VLLM_WORKER_MULTIPROC_METHOD=spawn \
  vllm serve /shared/models/qwen3-coder-30b-a3b-instruct-awq-4bit \
  --served-model-name qwen3-coder --tensor-parallel-size 1 --gpu-memory-utilization 0.70 \
  --enforce-eager --port 8080 --max-model-len 32768 --max-num-seqs 1 --kv-cache-memory-bytes 4294967296 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder
```

**gpt-oss (long-context + reasoning):**
```bash
source /opt/intel/oneapi/setvars.sh --force && source ~/llm-scaler-vllm-v19/venv/bin/activate && \
  VLLM_TARGET_DEVICE=xpu VLLM_WORKER_MULTIPROC_METHOD=spawn \
  vllm serve /shared/models/gpt-oss-20b \
  --served-model-name gpt-oss-20b --tensor-parallel-size 1 --gpu-memory-utilization 0.70 \
  --enforce-eager --port 8081 --max-model-len 65536 --max-num-seqs 1 --kv-cache-memory-bytes 3221225472 \
  --enable-auto-tool-choice --tool-call-parser openai --reasoning-parser openai_gptoss
```

## Known gotchas

- **Benching gpt-oss via `/v1/chat/completions` with `--ignore-eos`** crashes the Harmony response parser (`HarmonyError: Unexpected token 200002 while expecting start token 200006`). Bench via `--backend openai --endpoint /v1/completions` instead.
- **Default `--seed 0` in `vllm bench serve`** produces deterministic token sequences. Benching multiple shapes in the same server session with the default seed causes prefix cache hits on later shapes, inflating measurements. Always use shape-unique seeds or restart the server between shapes.
- **First-request-after-launch TTFT** includes XPU kernel JIT compile (~500–3000 ms). Always warm each shape before measuring.
- **Compressed-tensors AWQ gs=32 at 65K max-model-len** tanks prefill 20–30× vs 32K. Keep max-model-len tight to actual need.
- **vLLM 0.14 + IPEX ESIMD attention** requires `head_dim=256` — incompatible with Qwen3/Llama (head_dim=128). Only Gemma-family works on that path.
