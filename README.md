# MSI Claw 8 AI+ Nobara Linux Dual Boot Guide

Turn your MSI Claw 8 AI+ into a dual boot handheld — with the Steam Deck experience on Nobara Linux and the ability to run local LLMs with GPU acceleration via llama.cpp, or connect to OpenClaw as your personal AI assistant.

> **⚠️ This guide is for the Claw 8 AI+ (Lunar Lake / Core Ultra 7 258V) specifically.**
> The popular [A1M Reddit guide](https://www.reddit.com/r/MSIClaw/comments/1lnv5m9/) has Meteor Lake-specific BIOS tweaks that **do not apply** to Lunar Lake. Do not blindly copy A1M settings.

## Device Specs

| Component | Detail |
|---|---|
| CPU | Intel Core Ultra 7 258V (Lunar Lake) — 4P + 4E, no HyperThreading |
| GPU | Intel Arc 140V (Xe2 / Battlemage) — 8 Xe2 cores |
| RAM | 32GB LPDDR5x-8533 on-package (not upgradeable) |
| Bandwidth | 136.5 GB/s (quad-channel) |
| Storage | 1TB / 2TB NVMe PCIe 4.0 (M.2 2230, replaceable) |
| WiFi | Killer WiFi 7 BE1750 (Intel BE201) |
| Battery | 80Wh |
| Display | 8" FHD+ 1920x1200, 120Hz, VRR, IPS |
| Target OS | Nobara 43 Steam-Handheld |

## Quick Start

If you just want to get going:

1. Read the [Installation Guide](docs/INSTALL.md) — covers BIOS, partitioning, Ventoy, and dual boot setup
2. Run the [Post-Install Script](scripts/claw8-post-install.sh) — automates controller, WiFi fix, GPU driver, and AI setup with llama.cpp + Vulkan
3. Use the [Model Download Scripts](docs/DOWNLOAD_MODELS.md) — fast parallel downloads of safetensors and GGUF models from Hugging Face
4. Check the [Troubleshooting Guide](docs/TROUBLESHOOTING.md) if something goes wrong

```bash
# After first boot into Nobara, download and run:
chmod +x claw8-post-install.sh
sudo bash claw8-post-install.sh
```

## Post-Install Script Versions

Two versions are provided depending on your AI backend preference:

| Script | Backend | GPU Acceleration | When to Use |
|---|---|---|---|
| **claw8-post-install.sh** | llama.cpp + Vulkan | ✅ Yes (~2-3x faster TG) | **Recommended** — best performance on Arc 140V |
| **claw8-post-install-ollama.sh** | Ollama | ❌ CPU-only (for now) | Future use if Ollama adds Intel Vulkan support |

### Why llama.cpp over Ollama?

Ollama bundles a pre-built llama.cpp backend compiled with **CUDA only** (NVIDIA). On Intel iGPUs, it silently falls back to CPU. By building llama.cpp from source with `-DGGML_VULKAN=ON`, the Arc 140V iGPU is used for inference — giving measurably better token generation speed.

Both expose the same OpenAI-compatible API (`/v1/chat/completions`), so OpenClaw and other tools work identically with either backend.

## What the Post-Install Script Does

| Phase | Action | Interactive? |
|---|---|---|
| 1 | System update via `nobara-sync cli` | No |
| 2 | Check GPU driver (xe vs i915), offer switch | Yes (if i915) |
| 3 | Mask InputPlumber, install HHD for controller | No (skips if installed) |
| 4 | WiFi sleep fix (D3Cold + module reload) | No |
| 5 | Disable hibernate (breaks Quick Resume) | No |
| 6 | Build llama.cpp with Vulkan, install model launcher, download GGUF model | Yes (model choice) |
| 7 | Summary and reboot prompt | Yes |

## Model Launcher

The post-install script installs `~/run-model.sh` — an interactive launcher that auto-discovers GGUF models in `/shared/models/gguf/`:

```
$ ~/run-model.sh

Available models:
───────────────────────────────────────────────────────────────────────────────
  1) Crow-4B-Opus-4.6-Distill-Heretic_Qwen3.5.Q5_K_M.gguf  [3.0G] reasoning OFF | ctx 8k
  2) GLM-4.7-Flash-Q4_K_M.gguf                              [ 18G] reasoning ON  | ctx 32k
  3) LFM2-24B-A2B-Q5_K_M.gguf                               [ 17G] reasoning ON  | ctx 32k
  4) Qwen3.5-4B-UD-Q4_K_XL.gguf                             [2.8G] reasoning OFF | ctx 8k
  5) Qwen3.5-9B-UD-Q4_K_XL.gguf                             [5.6G] reasoning ON  | ctx 32k

Select model (1-5):
```

Features:
- Auto-discovers all `.gguf` files in `/shared/models/gguf/`
- Detects model size from filename (falls back to file size estimate)
- Models ≥9B: reasoning ON, 32k context (agentic/tool-calling ready)
- Models <9B: reasoning OFF, 8k context (small models loop in thinking mode)
- Serves OpenAI-compatible API at `http://127.0.0.1:8080`
- Built-in Web UI at `http://127.0.0.1:8080`
- Drop new GGUF files into the model directory — they auto-appear in the menu

## Real-World Benchmarks (Arc 140V + Vulkan)

All benchmarks measured on the Claw 8 AI+ with llama.cpp built with Vulkan, 8 threads, using `llama-bench`:

### Qwen3.5-4B (Q4_K_XL, 2.7GB) — Full GPU Offload

| Config | PP (tok/s) | TG (tok/s) |
|---|---|---|
| Vulkan ngl=99, 8 threads | **652.26** | **13.06** |
| Vulkan ngl=99, 2 threads | 207.60 | 12.94 |
| CPU only, 8 threads | 420.58 | 9.23 |
| CPU only, 2 threads | 273.70 | 5.38 |

Key takeaways:
- Vulkan gives **~40% faster TG** over CPU (13 vs 9.2 tok/s)
- Thread count dramatically affects PP (3x difference) but not TG
- TG is memory-bandwidth bound; PP is compute-bound

### GLM-4.7-Flash (Q4_K_M, 18GB) — Full GPU Offload

| Config | PP (tok/s) | TG (tok/s) |
|---|---|---|
| Vulkan ngl=99, 8 threads (bench) | **308.76** | **14.18** |
| Vulkan ngl=99, 8 threads (server, warm) | 3.10 | 12.97 |
| Vulkan ngl=99, 8 threads (server, cold) | 1.97 | 11.36 |

Key takeaways:
- 30B MoE model running entirely on iGPU at **14 tok/s** — very usable for chat
- Server PP is slower than bench due to 4 parallel slots competing for resources
- MoE with 3B active params generates tokens **faster** than the dense 4B model

### GPU Memory Usage

Total iGPU shared memory: ~23.7 GB (from 32GB system RAM)

| Model | Weight Size | KV Cache (8k) | Free After Load | Max Context |
|---|---|---|---|---|
| Qwen3.5-4B (2.7GB) | 3.7 GB | 0.3 GB | ~19.5 GB | 32k+ easily |
| Qwen3.5-9B (6GB) | ~7 GB | ~0.5 GB | ~16 GB | 32k |
| LFM2-24B MoE (17GB) | ~18 GB | ~0.4 GB | ~5 GB | 8-16k |
| GLM-4.7-Flash MoE (18GB) | 18.0 GB | 0.4 GB | 5.2 GB | 16-32k |
| Qwen3.5-35B MoE (22GB) | ~23 GB | — | Won't fit | CPU only |

## Model Recommendations for OpenClaw

| Model | Architecture | Total / Active | File Size | Est. TG | Best For |
|---|---|---|---|---|---|
| Qwen3.5-4B Q4_K_M | Dense | 4B / 4B | 3GB | ~15 tok/s | Quick tasks, fastest response |
| Qwen3.5-9B Q4_K_M ★ | Dense | 9B / 9B | 6GB | ~10-12 tok/s | Daily all-rounder, full GPU offload |
| LFM2-24B-A2B Q5_K_M | MoE | 24B / 2B | 17GB | ~10-14 tok/s | On-device MoE, Liquid AI |
| GLM-4.7-Flash Q4_K_M | MoE | 30B / 3B | 18GB | ~13-14 tok/s | Agentic coding, tool calling |
| Qwen3.5-27B Q4_K_M | Dense | 27B / 27B | 16GB | ~3-4 tok/s | Best reasoning, slower |

**GGUF quantization notes:**
- **Q4_K_M** — best balance of quality and speed, most optimized codepath in llama.cpp
- **Q5_K_M** — slightly better quality, ~20% larger, good for smaller models where RAM isn't tight
- **Q4_K_XL** — newer format, less optimized, may have slower TG in some backends
- Always use GGUF format (not GPTQ, AWQ, or EXL2 — those require CUDA/NVIDIA)

## Key Differences from the A1M Guide

| Setting | A1M (Meteor Lake 155H) | Claw 8 AI+ (Lunar Lake 258V) |
|---|---|---|
| CPU topology | Disable LP cores, set 2P+4E | Leave defaults (4P+4E, no HT) |
| HyperThreading | Toggle on/off | Does not exist on Lunar Lake |
| SpeedStep/SpeedShift | Disable SpeedStep | Leave defaults |
| Modern Standby | Disable via secret BIOS | Do not change |
| Secret BIOS unlock | Confirmed (Shift+Ctrl+Alt+F2) | Do not attempt blindly |
| GPU driver | xe optional improvement | xe likely already default |
| WiFi chip | Intel PCH CNVi (8086:7e40) | Intel BE201 (8086:a840) |
| GPU device ID | Meteor Lake Xe-LPG | 8086:64a0 (Xe2 Arc 140V) |

## OpenClaw + llama.cpp Setup

llama.cpp serves the same OpenAI-compatible API as Ollama. Point OpenClaw to `http://127.0.0.1:8080`:

```bash
# Start a model
~/run-model.sh

# Test the API
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}], "temperature": 0.7}' \
  | python3 -m json.tool
```

### Remote Server Setup

For heavier models, run inference on a more powerful machine. Start llama.cpp with `--host 0.0.0.0` on the server, then point OpenClaw to it:

```json
{
  "models": {
    "providers": {
      "remote": {
        "baseUrl": "http://YOUR_SERVER_IP:8080/v1",
        "apiKey": "EMPTY",
        "api": "openai-completions"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "remote/YOUR_MODEL_NAME",
        "fallback": "local/qwen3.5-9b"
      }
    }
  }
}
```

Works with llama.cpp, Ollama, vLLM, or any OpenAI-compatible endpoint on your network.

## BitLocker Warning

Windows 11 on the Claw ships with **BitLocker enabled by default**. When you disable Secure Boot (required for Nobara), BitLocker locks the Windows partition and demands a 48-digit recovery key on every boot.

**Options:**
1. **Decrypt before installing** (recommended) — Settings → Privacy & Security → Device Encryption → Off. Wait for completion, then disable Secure Boot.
2. **Keep BitLocker** — Write down your recovery key (`manage-bde -protectors -get C:` in admin CMD) and accept typing it each time you boot Windows.
3. **Linux only** — If you don't need Windows, Secure Boot + BitLocker are irrelevant.

## Known Issues

| Issue | Status | Workaround |
|---|---|---|
| WiFi dies after sleep | Known Intel iwlwifi bug | D3Cold fix + module reload (script handles this) |
| Sleep/wake hangs | Kernel-level, WIP | Keep kernel updated; avoid hibernate |
| No fan/TDP control (like MSI Center M) | HHD provides partial | Install HHD (script handles this) |
| Ollama doesn't use Intel iGPU | Ollama ships CUDA-only, no Vulkan | Use llama.cpp with Vulkan instead (post-install script handles this) |
| `intel_gpu_top` doesn't work | Only supports i915, not xe driver | Use `nvtop` instead (post-install script installs it) |
| Vulkan PP slower than CPU on large MoE models | Known — MoE routing overhead on Vulkan | TG is still faster with Vulkan; use GPU for generation |
| llama-bench OOM with large models | Default context too large for GPU memory | Add explicit `-c 8192` or lower |
| Small models loop in thinking mode | 4B models waste tokens on bad self-critique | Use `--reasoning-budget 0` (run-model.sh handles this automatically) |
| USB won't boot | Boot order issue | Set USB Hard Disk as Boot Option #1 in BIOS before installing |
| Linux Audio Compatibility missing in BIOS | Claw 8 AI+ may not have this A1M option | Sound should work without it on Lunar Lake |

## Build llama.cpp Manually

If you need to rebuild or didn't use the post-install script:

```bash
# Install dependencies
sudo dnf install cmake gcc gcc-c++ git vulkan-headers vulkan-loader-devel shaderc nvtop

# Clone and build with Vulkan
git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp
cd ~/llama.cpp
cmake -B build -DGGML_VULKAN=ON
cmake --build build --config Release -j$(nproc)

# Verify Vulkan is detected
./build/bin/llama-bench --list-devices

# Run a model
./build/bin/llama-server \
  -m /shared/models/gguf/YOUR_MODEL.gguf \
  -ngl 99 -t 8 -c 8192

# Benchmark
./build/bin/llama-bench \
  -m /shared/models/gguf/YOUR_MODEL.gguf \
  -ngl 99 -t 8
```

**Common build issues on Nobara:**
- `Could NOT find Vulkan (missing: glslc)` → Install `shaderc` package
- GPU shows 0% in system monitor → Normal, GNOME doesn't track Vulkan compute. Use `nvtop`
- `warning: no usable GPU found` → Build didn't include Vulkan. Delete `build/` dir and rebuild with `-DGGML_VULKAN=ON`
- Only 2 threads used by default → Always pass `-t 8` for Lunar Lake (4P + 4E cores)
- KV cache eating 8GB+ RAM → Always set explicit `-c` (e.g., `-c 8192`), don't let it default to training context

## Resources

- [Nobara Wiki](https://wiki.nobaraproject.org)
- [Nobara Downloads](https://nobaraproject.org/download.html)
- [llama.cpp](https://github.com/ggerganov/llama.cpp) — local LLM inference with Vulkan GPU support
- [Hugging Face GGUF Models](https://huggingface.co/models?library=gguf) — pre-quantized models ready to use
- [winesapOS MSI Claw support](https://github.com/winesapOS/winesapOS)
- [CachyOS Handheld](https://github.com/CachyOS/CachyOS-Handheld) (alternative distro)
- [HHD (Handheld Daemon)](https://github.com/hhd-dev/hhd)
- [OpenClaw](https://github.com/openclaw/openclaw)
- [Ollama](https://ollama.com) (alternative backend — currently CPU-only on Intel iGPU)
- [MSI Claw A1M Reddit Guide](https://www.reddit.com/r/MSIClaw/comments/1lnv5m9/) (Meteor Lake — use for reference only)
- [ReignOS](https://github.com/reignstudios/ReignOS) (alternative distro born from MSI Claw work)

## Contributing

This guide was built from real installation experience on a Claw 8 AI+ A2VM in March 2026, including hands-on benchmarking of llama.cpp with Vulkan on the Arc 140V iGPU. If you have corrections, improvements, or additional findings, pull requests are welcome.

## License

MIT
