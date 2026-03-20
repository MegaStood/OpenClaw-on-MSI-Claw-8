# Lunar Lake Xe2 140V Compatibility Report

**Status: FULLY COMPATIBLE**

This project was specifically designed and tested for the Intel Lunar Lake platform with the Arc 140V (Xe2) integrated GPU.

## Target Hardware

| Component | Specification |
|-----------|--------------|
| **CPU** | Intel Core Ultra 7 258V (Lunar Lake) — 4P + 4E cores |
| **GPU** | Intel Arc 140V (Xe2 / Battlemage) — 8 Xe2 cores |
| **GPU Device ID** | `8086:64a0` |
| **RAM** | 32GB LPDDR5x-8533 (on-package, shared with iGPU) |
| **Memory Bandwidth** | 136.5 GB/s (quad-channel) |

## Why It Works

1. **Vulkan GPU acceleration** — The correct compute API for Arc 140V iGPU (not CUDA/ROCm)
2. **xe driver support** — Proper kernel driver forcing (`xe.force_probe=64a0`) for Xe2 architecture
3. **llama.cpp from source** — Built with `-DGGML_VULKAN=ON` since Ollama lacks Intel iGPU Vulkan support
4. **Thread tuning** — Configured for Lunar Lake's 4P+4E core topology (8 threads)
5. **Memory-aware** — Models sized for ~24GB usable shared iGPU memory from 32GB system RAM

## Verified Performance (Arc 140V + Vulkan)

| Model | Tokens/sec | VRAM Usage |
|-------|-----------|------------|
| LFM2-24B-A2B | 20.7 tok/s | ~23.7GB |
| Qwen3.5-4B | 11.5 tok/s | ~2.8GB |
| Qwen3.5-35B-A3B | 9.5 tok/s | ~20GB |

## Lunar Lake-Specific Fixes Included

- WiFi D3Cold workaround (Intel iwlwifi bug on Lunar Lake)
- Sleep/wake handling for Lunar Lake kernel issues
- `nvtop` instead of `intel_gpu_top` (incompatible with xe driver)
- Correct BIOS settings (different from Meteor Lake A1M guides)

---

*Report generated: 2026-03-20*
