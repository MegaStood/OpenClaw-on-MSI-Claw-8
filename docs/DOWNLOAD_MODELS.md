# Downloading Models from Hugging Face

Two scripts for downloading models from Hugging Face Hub to the Claw 8 AI+. Both support **safetensors** (full models for vLLM/transformers) and **GGUF** (quantized models for Ollama/llama.cpp).

> **Which script should I use?**
> - `download_model_fast.sh` — zero-setup, creates its own Python venv automatically. **Start here.**
> - `download_model_fast.py` — if you already have a Python environment with `huggingface_hub` installed.

## Quick Start

```bash
# Make the script executable (once)
chmod +x scripts/download_model_fast.sh

# Download a safetensors model
./scripts/download_model_fast.sh Qwen/Qwen2.5-72B-Instruct

# Download a GGUF quant
./scripts/download_model_fast.sh bartowski/Qwen2.5-72B-Instruct-GGUF --gguf Q4_K_M
```

On first run, the `.sh` script creates a `.dl-model-venv` virtual environment next to itself and installs `huggingface_hub`. Subsequent runs skip this step entirely.

## Where Files Go

| Type | Destination |
|---|---|
| Safetensors | `/shared/models/<model-name>/` |
| GGUF | `/shared/models/gguf/` (flat, no subdirectories) |

> **Note:** `/shared/models` is a symlink to `/home/richardlee/models` — they point to the same location.

## Usage

```
download_model_fast.sh <repo_id> [local_name] [--gguf PATTERN] [--workers N]
```

| Argument | Required | Description |
|---|---|---|
| `repo_id` | Yes | Hugging Face repo (e.g. `Qwen/Qwen2.5-72B-Instruct`) |
| `local_name` | No | Override the output folder name (safetensors only) |
| `--gguf PATTERN` | No | Download only GGUF files matching PATTERN (e.g. `Q4_K_M`) |
| `--workers N` | No | Parallel download threads (default: 8) |

## Examples

### Safetensors (for vLLM / transformers)

```bash
# Default folder name (derived from repo)
./scripts/download_model_fast.sh Qwen/Qwen2.5-72B-Instruct
# → /shared/models/qwen2.5-72b-instruct/

# Custom folder name
./scripts/download_model_fast.sh Qwen/Qwen2.5-72B-Instruct qwen72b
# → /shared/models/qwen72b/
```

### GGUF (for Ollama / llama.cpp)

```bash
# Download a specific quant
./scripts/download_model_fast.sh bartowski/Qwen2.5-72B-Instruct-GGUF --gguf Q4_K_M
# → /shared/models/gguf/Qwen2.5-72B-Instruct-Q4_K_M.gguf

# Max speed with 16 threads
./scripts/download_model_fast.sh bartowski/Llama-3.1-8B-Instruct-GGUF --gguf Q5_K_M --workers 16
# → /shared/models/gguf/Llama-3.1-8B-Instruct-Q5_K_M.gguf
```

If your pattern doesn't match, the script lists all available GGUF files in the repo so you can pick the right one.

### Using a Downloaded GGUF with Ollama

After downloading, create a Modelfile and import:

```bash
# Create a Modelfile
echo 'FROM /shared/models/gguf/Qwen2.5-72B-Instruct-Q4_K_M.gguf' > Modelfile

# Import into Ollama
ollama create qwen2.5-72b-q4 -f Modelfile

# Run it
ollama run qwen2.5-72b-q4
```

## Gated / Private Models

For models that require authentication (e.g. Llama, Gemma), set your Hugging Face token:

```bash
export HF_TOKEN="hf_your_token_here"
./scripts/download_model_fast.sh meta-llama/Llama-3.1-70B-Instruct
```

You can get a token from [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).

To make it persistent, add to your `~/.bashrc`:

```bash
echo 'export HF_TOKEN="hf_your_token_here"' >> ~/.bashrc
```

## Resuming Interrupted Downloads

Both scripts resume automatically. If a download is interrupted (network drop, Ctrl+C, etc.), just run the same command again — it picks up where it left off.

## Requirements

- **Python 3.9+** — the `.sh` script checks for this and prints install instructions if missing
- **Internet connection** — obviously
- **Disk space** — check the model size on the Hugging Face repo page before downloading

If Python is not installed:

```bash
# Nobara / Fedora
sudo dnf install python3

# CachyOS / Arch
sudo pacman -S python

# Ubuntu / Debian
sudo apt install python3 python3-venv
```
