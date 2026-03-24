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

### Telegram

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram
2. Copy the bot token
3. Add the channel:

```bash
openclaw channels add
# Select: Telegram (Bot API)
# Paste your bot token when prompted
```

**Note:** Telegram requires outbound HTTPS to `api.telegram.org`. If you use a VPN, Telegram polling may be blocked — ensure the VPN allows this traffic or use a split tunnel (see Step 8).

### WhatsApp (tested and working)

WhatsApp connects via QR code — simpler than Telegram for VPN setups since it uses WebSocket.

```bash
openclaw channels add
# Select: WhatsApp (QR link)
# Select: default (primary)
```

1. A QR code appears in the terminal
2. On your phone: WhatsApp → Settings → Linked Devices → Link a Device
3. Scan the QR code
4. Select "This is my personal phone number"
5. Enter your phone number for allowlisting

The config will look like:

```json
"channels": {
    "whatsapp": {
        "enabled": true,
        "dmPolicy": "allowlist",
        "allowFrom": ["+852XXXXXXXX"]
    }
}
```

**Note:** If `groupPolicy` is "allowlist" but `groupAllowFrom` is empty, all group messages are silently dropped. Add group IDs to `groupAllowFrom` if you need group support.

### Discord

Follow the [OpenClaw Discord guide](https://docs.openclaw.ai/channels/discord) to create a bot and configure channel access.

## Step 4.5: Configure Web Search

OpenClaw supports five search providers. **Gemini is recommended** (free tier: 60 requests/min, 1,000/day).

Get your API key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey), then configure:

```json
"tools": {
    "web": {
        "search": {
            "enabled": true,
            "provider": "gemini",
            "apiKey": "AIza..."
        }
    }
}
```

Available providers: `brave`, `perplexity`, `grok`, `gemini`, `kimi`. Tavily is **not supported** despite being popular with other agent frameworks.

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

## Step 8: WireGuard VPN (optional)

If you need a VPN for Telegram or other services, WireGuard works well on Nobara. Surfshark Linux doesn't support split tunneling, so WireGuard CLI is recommended.

### Install and configure

```bash
sudo dnf install wireguard-tools
```

Get a WireGuard config from your VPN provider (e.g., Surfshark dashboard), save it to `/etc/wireguard/wg0.conf`, then add local network exclusion to keep SSH working:

```ini
[Interface]
Address = 10.14.0.2/16
PrivateKey = YOUR_PRIVATE_KEY
DNS = 162.252.172.57, 149.154.159.92
PostUp = ip route add 192.168.0.0/16 via $(ip -4 route show default dev wlo1 | awk '{print $3}') dev wlo1
PreDown = ip route del 192.168.0.0/16 2>/dev/null || true

[Peer]
PublicKey = YOUR_PEER_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = your-vpn-server:51820
```

The `PostUp` line auto-detects your WiFi gateway and keeps all `192.168.x.x` traffic local (SSH, LAN access). Works on any WiFi network.

### Start and enable

```bash
sudo wg-quick up wg0        # start VPN
curl ifconfig.me             # verify VPN IP
sudo systemctl enable wg-quick@wg0  # auto-start on boot
```

### Stop

```bash
sudo wg-quick down wg0
```

**Note:** If WireGuard starts before WiFi connects on boot, the gateway detection fails. Restart manually: `sudo wg-quick down wg0 && sudo wg-quick up wg0`.

## Step 9: Claude OAuth Token Management (optional)

If you use a Claude Max subscription instead of an API key, you can authenticate via OAuth token. This is less reliable than an API key but included in your subscription.

### Initial setup

```bash
# Install Claude Code CLI
curl -fsSL https://claude.ai/install.sh | bash

# Login with your Max account
claude auth login
# Follow browser prompts, paste auth code

# Extract the token
grep accessToken ~/.claude/.credentials.json
```

Copy the `sk-ant-oat01-...` token into your OpenClaw config under `env.ANTHROPIC_API_KEY`.

### Token refresh script

OAuth tokens expire frequently. A refresh script is provided:

```bash
# Sync token from Claude credentials to OpenClaw (after manual login)
~/refresh-claude-token.sh

# Force refresh via API call, then sync
~/refresh-claude-token.sh --force

# Check status
~/refresh-claude-token.sh --status

# Auto-refresh every 2 hours
~/refresh-claude-token.sh --install

# Remove auto-refresh
~/refresh-claude-token.sh --uninstall
```

The `--force` flag sends a real API call (`claude -p "hi"`) to trigger the OAuth refresh flow using the stored refresh token.

### Known limitations

- OAuth tokens expire every few hours — requires regular refresh
- Anthropic's client fingerprinting may reject requests with 403 errors
- `--force` only works if the refresh token is still valid (weeks/months)
- When the refresh token expires, you must run `claude auth login` manually
- **Recommendation:** Use an Anthropic API key ($5 gets you started) for reliable, permanent access

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

### Tool calls work — confirmed with --jinja

Tool calling works correctly when llama.cpp is started with the `--jinja` flag. The `run-model.sh` script enables this automatically. Verified via curl:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role":"user","content":"Run the command: hostname"}],
    "tools": [{"type":"function","function":{"name":"exec","description":"Run a shell command","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}],
    "tool_choice": "auto"
  }' | python3 -m json.tool
```

Returns `"finish_reason": "tool_calls"` with proper JSON format.

**Note:** OpenClaw may still not intercept tool calls from the local model in some configurations. If the agent shows raw `[exec(...)]` text instead of executing commands, check that the model alias and provider config match. Claude API tool calling works natively without issues.

### OpenClaw context window shows 16k instead of 32k

The onboarding wizard defaults to 16k. Fix in `~/.openclaw/openclaw.json`:

```json
"models": [{
    "id": "Qwen3.5-35B-A3B",
    "contextWindow": 32000,
    "maxTokens": 8192
}]
```

### OpenClaw doesn't fall back on auth errors

OpenClaw only falls back on connection errors and timeouts, **not** on auth errors (401/403). If Claude returns 401, the local model is not tried — OpenClaw assumes your credentials are wrong. Switch primary to local if Claude auth is broken:

```json
"primary": "local/Qwen3.5-35B-A3B"
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
