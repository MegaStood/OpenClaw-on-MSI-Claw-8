#!/bin/bash
# refresh-claude-token.sh — Sync Claude OAuth token to OpenClaw config
#
# Usage:
#   ~/refresh-claude-token.sh              # sync token once
#   ~/refresh-claude-token.sh --force      # force API call to refresh token, then sync
#   ~/refresh-claude-token.sh --install    # install as cron job (every 2 hours)
#   ~/refresh-claude-token.sh --uninstall  # remove cron job
#   ~/refresh-claude-token.sh --status     # show current token status
#
# Logic:
#   1. Read token from OpenClaw config (what's actively being used)
#   2. Read token from Claude credentials (source of truth)
#   3. If --force: make a real API call to trigger token refresh
#   4. If tokens differ → update OpenClaw config, restart gateway
#   5. If same → do nothing
#
# WARNING: OAuth tokens may be blocked by Anthropic's client fingerprinting.
# If you consistently get 403 errors, switch to an API key from console.anthropic.com

CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
LOG_FILE="$HOME/.openclaw/token-refresh.log"
CRON_SCHEDULE="0 */2 * * *"  # every 2 hours

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Helper: extract Claude credentials access token
get_claude_token() {
    python3 -c "
import json
with open('$CREDENTIALS_FILE') as f:
    creds = json.load(f)
print(creds.get('claudeAiOauth', {}).get('accessToken', ''))
" 2>/dev/null
}

# Helper: extract OpenClaw config token
get_openclaw_token() {
    python3 -c "
import json
with open('$OPENCLAW_CONFIG') as f:
    config = json.load(f)
print(config.get('env', {}).get('ANTHROPIC_API_KEY', ''))
" 2>/dev/null
}

# ── Install/Uninstall cron ───────────────────────────────────────────────────

if [ "$1" = "--install" ]; then
    SCRIPT_PATH=$(realpath "$0")
    (crontab -l 2>/dev/null | grep -v "refresh-claude-token"; echo "$CRON_SCHEDULE $SCRIPT_PATH --force >> $LOG_FILE 2>&1") | crontab -
    echo "Installed cron job: runs every 2 hours with --force"
    echo "Schedule: $CRON_SCHEDULE"
    echo "Log: $LOG_FILE"
    echo "Remove with: $0 --uninstall"
    exit 0
fi

if [ "$1" = "--uninstall" ]; then
    crontab -l 2>/dev/null | grep -v "refresh-claude-token" | crontab -
    echo "Removed cron job"
    exit 0
fi

# ── Status ───────────────────────────────────────────────────────────────────

if [ "$1" = "--status" ]; then
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        echo "No credentials file found at $CREDENTIALS_FILE"
        echo "Run 'claude auth login' first"
        exit 1
    fi

    CLAUDE_TOKEN=$(get_claude_token)
    OPENCLAW_TOKEN=$(get_openclaw_token)

    CLAUDE_SHORT="${CLAUDE_TOKEN:0:20}..."
    OPENCLAW_SHORT="${OPENCLAW_TOKEN:0:20}..."
    [ -z "$OPENCLAW_TOKEN" ] && OPENCLAW_SHORT="NOT SET"

    echo "OpenClaw token (active):  $OPENCLAW_SHORT"
    echo "Claude token (source):    $CLAUDE_SHORT"

    if crontab -l 2>/dev/null | grep -q "refresh-claude-token"; then
        echo "Cron job: installed"
    else
        echo "Cron job: not installed (run --install to enable)"
    fi

    if [ "$CLAUDE_TOKEN" = "$OPENCLAW_TOKEN" ]; then
        echo "Status: tokens match ✅"
    elif [ -z "$OPENCLAW_TOKEN" ]; then
        echo "Status: OpenClaw has no token ❌ (run this script to sync)"
    else
        echo "Status: tokens DON'T match ⚠️  (run this script to sync)"
    fi

    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "Last 5 log entries:"
        tail -5 "$LOG_FILE"
    fi
    exit 0
fi

# ── Preflight checks ────────────────────────────────────────────────────────

if [ ! -f "$OPENCLAW_CONFIG" ]; then
    log "ERROR: OpenClaw config not found at $OPENCLAW_CONFIG"
    exit 1
fi

if [ ! -f "$CREDENTIALS_FILE" ]; then
    log "ERROR: Claude credentials not found at $CREDENTIALS_FILE"
    log "Run 'claude auth login' first"
    exit 1
fi

# ── Step 1: Force refresh if requested ───────────────────────────────────────
# `claude --version` doesn't touch auth. Only a real API call triggers
# the OAuth refresh flow (using the stored refresh token to get a new
# access token). We send a minimal prompt to force it.

if [ "$1" = "--force" ]; then
    log "Forcing token refresh via API call..."
    if command -v claude &>/dev/null; then
        claude -p "hi" --max-turns 1 &>/dev/null
        sleep 2
        log "API call completed"
    else
        log "WARNING: claude CLI not found, skipping forced refresh"
    fi
fi

# ── Step 2: Read both tokens ────────────────────────────────────────────────

OPENCLAW_TOKEN=$(get_openclaw_token)
CLAUDE_TOKEN=$(get_claude_token)

if [ -z "$CLAUDE_TOKEN" ]; then
    log "ERROR: Could not read token from Claude credentials"
    exit 1
fi

log "OpenClaw token (active):  ${OPENCLAW_TOKEN:0:20}..."
log "Claude token (source):    ${CLAUDE_TOKEN:0:20}..."

# ── Step 3: Compare and sync ────────────────────────────────────────────────

if [ "$OPENCLAW_TOKEN" = "$CLAUDE_TOKEN" ]; then
    log "Tokens already match. Nothing to do."
    log "───────────────────────────────────────────────"
    exit 0
fi

log "Tokens differ — syncing Claude → OpenClaw..."

# Backup config
cp "$OPENCLAW_CONFIG" "${OPENCLAW_CONFIG}.bak"

# Update OpenClaw config with Claude's token
python3 -c "
import json

with open('$OPENCLAW_CONFIG', 'r') as f:
    config = json.load(f)

if 'env' not in config:
    config['env'] = {}

config['env']['ANTHROPIC_API_KEY'] = '''$CLAUDE_TOKEN'''

with open('$OPENCLAW_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)

print('Config updated successfully')
" 2>/dev/null

if [ $? -ne 0 ]; then
    log "ERROR: Failed to update OpenClaw config"
    cp "${OPENCLAW_CONFIG}.bak" "$OPENCLAW_CONFIG"
    log "Restored config from backup"
    exit 1
fi

log "Updated OpenClaw config"

# ── Step 4: Restart gateway ─────────────────────────────────────────────────

log "Restarting OpenClaw gateway..."
systemctl --user restart openclaw-gateway 2>/dev/null

if [ $? -eq 0 ]; then
    log "Gateway restarted successfully"
else
    log "WARNING: Gateway restart failed"
fi

sleep 10

if curl -s --max-time 5 http://127.0.0.1:18789/ &>/dev/null; then
    log "Gateway is reachable ✅"
else
    log "WARNING: Gateway not reachable after restart"
fi

log "Token sync complete"
log "───────────────────────────────────────────────"
