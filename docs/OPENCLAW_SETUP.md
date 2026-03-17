# OpenClaw Setup Guide for MSI Claw 8 AI+

Complete guide to installing and configuring OpenClaw on the MSI Claw 8 AI+ with a three-route inference architecture: local llama.cpp, remote DGX Spark, and Anthropic Claude.

## Prerequisites

- MSI Claw 8 AI+ running Nobara (post-install script completed)
- llama.cpp built with Vulkan (`~/llama.cpp/build/bin/llama-server`)
- At least one GGUF model in `/shared/models/gguf/`
- Node.js 22+ (installed by OpenClaw installer)
- Optional: DGX Spark cluster with vLLM for remote inference
- Optional: Anthropic API key for Claude access

## Step 1: Install OpenClaw

The one-liner handles Node.js detection, installation, and onboarding:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

Or install manually via npm:

```bash
# Install Node.js 22+ via nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
source ~/.bashrc
nvm install 22
nvm use 22

# Install OpenClaw
npm install -g openclaw@latest

# Run the onboarding wizard
openclaw onboard --install-daemon
```

The `--install-daemon` flag registers OpenClaw as a systemd service so it starts on boot — important for an always-on handheld agent.

Verify the installation:

```bash
openclaw --version
openclaw doctor        # check for configuration issues
openclaw status        # check gateway status
```

## Step 2: Configure Inference Providers

During onboarding, choose "Custom Provider" for the local llama.cpp endpoint. You can add more providers manually afterwards.

### Option A: Local llama.cpp only (simplest)

Start a model first:

```bash
~/run-model.sh
```

Edit `~/.openclaw/openclaw.json`:

```json
{
  "models": {
    "providers": {
      "local": {
        "baseUrl": "http://127.0.0.1:8080/v1",
        "apiKey": "no-key",
        "api": "openai-completions",
        "models": [
          {
            "id": "lfm2-24b",
            "name": "LFM2-24B-A2B",
            "reasoning": false,
            "contextWindow": 32768,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "local/lfm2-24b"
      }
    }
  }
}
```

### Option B: Three-route setup (recommended)

The full architecture with local, Spark, and Claude:

```json
{
  "env": {
    "ANTHROPIC_API_KEY": "sk-ant-YOUR_KEY_HERE"
  },
  "gateway": {
    "bind": "loopback",
    "port": 18789
  },
  "models": {
    "providers": {
      "local": {
        "baseUrl": "http://127.0.0.1:8080/v1",
        "apiKey": "no-key",
        "api": "openai-completions",
        "models": [
          {
            "id": "lfm2-24b",
            "name": "LFM2-24B-A2B (local)",
            "reasoning": false,
            "contextWindow": 32768,
            "maxTokens": 8192
          },
          {
            "id": "qwen3.5-35b",
            "name": "Qwen3.5-35B-A3B (local)",
            "reasoning": true,
            "contextWindow": 32768,
            "maxTokens": 8192
          }
        ]
      },
      "spark": {
        "baseUrl": "http://192.168.50.121:8888/v1",
        "apiKey": "no-key",
        "api": "openai-completions",
        "models": [
          {
            "id": "qwen3.5-122b",
            "name": "Qwen3.5-122B-A10B (Spark)",
            "reasoning": true,
            "contextWindow": 128000,
            "maxTokens": 16384
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-6",
        "fallbacks": ["spark/qwen3.5-122b", "local/lfm2-24b"]
      },
      "models": {
        "anthropic/claude-sonnet-4-6": {
          "params": {
            "cacheRetention": "short"
          }
        }
      }
    }
  }
}
```

### Important: Start llama.cpp before OpenClaw

OpenClaw expects the local endpoint to be available. Add to your startup flow:

```bash
# Start local model
~/run-model.sh    # select a model

# Then in another terminal, or after model loads:
openclaw gateway
```

Or create a systemd service for auto-start (see Step 6).

## Step 3: Security Hardening

OpenClaw has shell access and file permissions — hardening is essential.

### Bind gateway to loopback

By default, the gateway binds to `0.0.0.0` (accessible from any device on your network). Fix this:

```json
{
  "gateway": {
    "bind": "loopback",
    "port": 18789
  }
}
```

### Enable consent mode

Require approval before write/exec commands:

```bash
openclaw config set tools.allow '["read"]' --strict-json
```

Expand permissions as you gain confidence. For full access:

```bash
openclaw config set tools.allow '["exec","read","write","edit"]' --strict-json
```

### Run security audit

```bash
openclaw doctor
```

Fix any red flags before connecting messaging channels.

## Step 4: Connect Messaging Channels

### Telegram (simplest to start)

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Copy the bot token
3. Configure in OpenClaw:

```bash
openclaw channels add telegram
# Paste your bot token when prompted
```

### WhatsApp

Requires WhatsApp Business API or a bridge like Baileys. Follow the [OpenClaw WhatsApp guide](https://docs.openclaw.ai/channels/whatsapp).

### Discord

Follow the [OpenClaw Discord guide](https://docs.openclaw.ai/channels/discord) to create a bot and configure channel access.

## Step 5: Recommended Skills

OpenClaw's ClawHub has 5,700+ skills. Here are the most useful ones for the MSI Claw setup:

### Essential skills

| Skill | What it does | Install |
|-------|-------------|---------|
| **exec** | Run shell commands | Built-in |
| **read/write** | File system access | Built-in |
| **browser** | Web browsing via CDP | Built-in |
| **cron** | Scheduled tasks | Built-in |

### Recommended for daily use

| Skill | What it does | Why useful on the Claw |
|-------|-------------|----------------------|
| **web-search** | Search the web | Research without opening a browser |
| **calendar** | Google/Outlook calendar | Manage schedule via chat |
| **email** | Gmail/SMTP integration | Read and send email hands-free |
| **git** | Git operations | Manage your repos from Telegram |
| **system-monitor** | CPU/memory/GPU stats | Monitor Claw health remotely |

### For coding workflows

| Skill | What it does | Best model |
|-------|-------------|-----------|
| **code-review** | Review diffs and PRs | Claude or Spark (complex) |
| **test-gen** | Generate test cases | Spark (routine) |
| **refactor** | Code restructuring | Claude (hard tasks) |

Install skills via the TUI or CLI:

```bash
openclaw skills install web-search
openclaw skills install calendar
```

## Step 6: Auto-start on Boot

### llama.cpp as a systemd service

Create `/etc/systemd/system/llama-server.service`:

```ini
[Unit]
Description=llama.cpp inference server
After=network.target

[Service]
Type=simple
User=nobara-user
ExecStart=/home/nobara-user/llama.cpp/build/bin/llama-server \
    -m /shared/models/gguf/LFM2-24B-A2B-Q5_K_M.gguf \
    -ngl 99 -t 8 -c 32768
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable it:

```bash
sudo systemctl enable llama-server
sudo systemctl start llama-server
```

### OpenClaw gateway

The `--install-daemon` flag during onboarding already sets this up. Verify:

```bash
systemctl --user status openclaw
```

## Step 7: Agent Personality and Memory

### Workspace files

OpenClaw reads these files from `~/.openclaw/workspace/` at the start of every session:

| File | Purpose |
|------|---------|
| `SOUL.md` | Agent personality, boundaries, communication style |
| `USER.md` | Information about you — preferences, context |
| `MEMORY.md` | Long-term memory curated by the agent |
| `BOOTSTRAP.md` | First-run onboarding flow |

### First interaction

Send this as your very first message to set up the agent:

```
Hey, let's get you set up. Read BOOTSTRAP.md and walk me through it.
```

This runs the onboarding flow that sets the agent's name, personality, and learns about you.

### Example SOUL.md for the Claw

```markdown
You are a helpful AI assistant running on an MSI Claw 8 AI+ handheld.
You have access to local llama.cpp inference (fast, offline) and
remote DGX Spark inference (powerful, requires network).

Priorities:
- Use local inference for quick tasks and when offline
- Route complex reasoning to the Spark cluster when available
- Be concise — this is a handheld device, screen space is limited
- Proactively check system health (battery, memory, GPU temp)
```

## Troubleshooting

### OpenClaw can't connect to llama.cpp

```bash
# Check if llama-server is running
ps aux | grep llama-server

# Test the endpoint directly
curl http://127.0.0.1:8080/v1/models
```

### Gateway fails to start

```bash
# Check port conflict
lsof -i :18789

# Check logs
journalctl --user -u openclaw -f
```

### Tool calls fail with Qwen3.5 models

Qwen 3.5 tool calling is broken in Ollama but works in llama.cpp. Make sure you're using llama.cpp with the `--jinja` flag:

```bash
~/llama.cpp/build/bin/llama-server \
  -m /shared/models/gguf/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf \
  -ngl 99 -t 8 -c 32768 --parallel 1 --jinja
```

### High token costs with Claude

Context accumulation is the biggest cost driver. Long sessions re-send entire conversation history with every API call. Mitigate by:

- Starting new sessions regularly
- Using `cacheRetention: "short"` in config
- Routing routine tasks to the free Spark or local endpoint
- Setting a spend limit in the Anthropic console

## NemoClaw vs OpenClaw

[NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) is an OpenClaw plugin that adds enterprise-grade security sandboxing via NVIDIA OpenShell. It is **not applicable** to the MSI Claw because:

| Requirement | NemoClaw | MSI Claw 8 AI+ |
|-------------|----------|-----------------|
| OS | Ubuntu 22.04+ | Nobara (Fedora-based) |
| GPU | NVIDIA (CUDA) | Intel Arc 140V (Vulkan) |
| Docker | Required | Not pre-installed |
| OpenShell runtime | Required | Not available for Intel |
| Default models | NVIDIA Nemotron | N/A |
| Status | Alpha (5 stars) | N/A |

NemoClaw is better suited for DGX Spark deployments where you want sandboxed agent execution with network/filesystem isolation. For the Claw, standard OpenClaw with manual security hardening (Step 3) is the right path.

If you run OpenClaw on both the Claw and the Spark, you could use NemoClaw on the Spark side for sandboxed execution while keeping plain OpenClaw on the Claw as the always-on gateway.

## Further Reading

- [OpenClaw Official Docs](https://docs.openclaw.ai)
- [OpenClaw Install Guide](https://docs.openclaw.ai/install)
- [Anthropic Provider Setup](https://docs.openclaw.ai/providers/anthropic)
- [Channel Configuration](https://docs.openclaw.ai/channels)
- [Skills Registry (ClawHub)](https://docs.openclaw.ai/skills)
- [Security Guide](https://docs.openclaw.ai/security)
- [NemoClaw (NVIDIA)](https://github.com/NVIDIA/NemoClaw) — sandboxed OpenClaw for NVIDIA hardware
