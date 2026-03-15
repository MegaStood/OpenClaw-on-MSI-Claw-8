# MSI Claw 8 AI+ Nobara Linux Dual Boot Guide

Turn your MSI Claw 8 AI+ into a dual boot handheld — with the Steam Deck experience on Nobara Linux and the ability to run OpenClaw and Ollama as your personal AI assistant.

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
2. Run the [Post-Install Script](scripts/claw8-post-install.sh) — automates controller, WiFi fix, GPU driver, and AI setup
3. Use the [Model Download Scripts](docs/DOWNLOAD_MODELS.md) — fast parallel downloads of safetensors and GGUF models from Hugging Face
4. Check the [Troubleshooting Guide](docs/TROUBLESHOOTING.md) if something goes wrong

```bash
# After first boot into Nobara, download and run:
chmod +x claw8-post-install.sh
sudo bash claw8-post-install.sh
```

## What the Post-Install Script Does

| Phase | Action | Interactive? |
|---|---|---|
| 1 | System update via `nobara-sync cli` | No |
| 2 | Check GPU driver (xe vs i915), offer switch | Yes (if i915) |
| 3 | Mask InputPlumber, install HHD for controller | No (skips if installed) |
| 4 | WiFi sleep fix (D3Cold + module reload) | No |
| 5 | Disable hibernate (breaks Quick Resume) | No |
| 6 | Install Ollama + model selection for OpenClaw | Yes (model choice) |
| 7 | Summary and reboot prompt | Yes |

## Model Comparison for OpenClaw

All models tested or estimated on the Claw 8 AI+ with 32GB shared RAM and 136.5 GB/s memory bandwidth:

| Model | Architecture | Total / Active | File Size | Context | Vision | Tool Calling | Est. tok/s | Best For |
|---|---|---|---|---|---|---|---|---|
| qwen3.5:9b ★ | Dense | 9B / 9B | 6.6GB | 256K | ✅ | Good | ~12-15 | Daily all-rounder |
| gpt-oss:20b | MoE | 20B / 3.6B | 12GB | 128K | ❌ | Very reliable | ~20-25 | Proven reliability |
| lfm2:24b | MoE | 24B / 2B | 14GB | 32K | ❌ | Good | ~30-40 | Fastest on-device |
| glm-4.7-flash | MoE | 30B / 3B | 19GB | 198K | ❌ | Excellent | ~25-30 | Agentic coding |
| qwen3-coder:30b | MoE | 30B / 3.3B | 20GB | 256K | ❌ | Excellent | ~22-28 | Code workflows |

**Note:** MoE models activate fewer parameters per token, so they generate tokens *faster* despite larger total size. But all parameters must fit in RAM. Models over 14GB leave limited headroom for OpenClaw's 64K+ context window on 32GB shared memory.

### Real-World Benchmark (glm-4.7-flash on Claw 8 AI+)

```
Simple query:  8.94 tok/s  (prompt eval: 41.36 tok/s)
Code gen:      5.35 tok/s  (prompt eval: 1305.66 tok/s, 4215 tokens output)
```

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

## OpenClaw + Remote Server Setup

For heavier models, run inference on a more powerful machine and point OpenClaw to it:

```json
{
  "models": {
    "providers": {
      "remote": {
        "baseUrl": "http://YOUR_SERVER_IP:8000/v1",
        "apiKey": "EMPTY",
        "api": "openai-completions"
      },
      "ollama-local": {
        "baseUrl": "http://127.0.0.1:11434",
        "apiKey": "ollama-local",
        "api": "ollama"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "remote/qwen3.5-122b",
        "fallback": "ollama-local/qwen3.5:9b"
      }
    }
  }
}
```

Works with Ollama, vLLM, or any OpenAI-compatible endpoint on your network.

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
| Ollama doesn't detect Intel Arc GPU | Expected — Intel isn't CUDA/ROCm | Set `OLLAMA_VULKAN=1` (experimental) |
| Vulkan inference slower than CPU on some Intel iGPUs | Known Ollama issue | Test both, use whichever is faster |
| USB won't boot | Boot order issue | Set USB Hard Disk as Boot Option #1 in BIOS before installing |
| Linux Audio Compatibility missing in BIOS | Claw 8 AI+ may not have this A1M option | Sound should work without it on Lunar Lake |

## Resources

- [Nobara Wiki](https://wiki.nobaraproject.org)
- [Nobara Downloads](https://nobaraproject.org/download.html)
- [winesapOS MSI Claw support](https://github.com/winesapOS/winesapOS)
- [CachyOS Handheld](https://github.com/CachyOS/CachyOS-Handheld) (alternative distro)
- [HHD (Handheld Daemon)](https://github.com/hhd-dev/hhd)
- [OpenClaw](https://github.com/openclaw/openclaw)
- [Ollama](https://ollama.com)
- [Ollama OpenClaw Docs](https://docs.ollama.com/integrations/openclaw)
- [MSI Claw A1M Reddit Guide](https://www.reddit.com/r/MSIClaw/comments/1lnv5m9/) (Meteor Lake — use for reference only)
- [ReignOS](https://github.com/reignstudios/ReignOS) (alternative distro born from MSI Claw work)

## Contributing

This guide was built from real installation experience on a Claw 8 AI+ A2VM in March 2026. If you have corrections, improvements, or additional findings, pull requests are welcome.

## License

MIT
