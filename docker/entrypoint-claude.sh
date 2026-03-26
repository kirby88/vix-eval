#!/usr/bin/env bash
set -euo pipefail

AGENT_TYPE="claude-code"
source /usr/local/bin/entrypoint-common.sh

# --- Pre-configure Claude Code to skip interactive prompts ---
cat > /root/.claude.json <<'CJSON'
{
  "hasCompletedOnboarding": true,
  "projects": {
    "/workspace": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true
    }
  }
}
CJSON

# Use apiKeyHelper so Claude Code doesn't warn about a custom API key in the env.
echo "$ANTHROPIC_API_KEY" > /root/.claude-api-key
chmod 600 /root/.claude-api-key
cat > /root/.claude/settings.json <<'SJSON'
{
  "apiKeyHelper": "cat /root/.claude-api-key"
}
SJSON
unset ANTHROPIC_API_KEY

# --- Override with user-provided settings if mounted ---
if [ -d /staged-settings ]; then
    echo "Applying user settings from /staged-settings ..."
    cp -r /staged-settings/. /root/.claude/
    # Ensure apiKeyHelper is present in settings.json
    if [ -f /root/.claude/settings.json ]; then
        jq '. + {"apiKeyHelper":"cat /root/.claude-api-key"}' /root/.claude/settings.json > /tmp/settings_merged.json \
            && mv /tmp/settings_merged.json /root/.claude/settings.json
    fi
fi

# --- Record agent version ---
echo "claude-code: $(claude --version 2>/dev/null || echo 'not installed')" > /output/versions.txt

echo -e "${C_CYAN}  ============================================${C_RESET}"
echo ""

# --- Interactive shell (not exec — we need to run cleanup after) ---
bash -l || true

# --- Copy plan ---
PLAN_FILE="$(ls -t /root/.claude/plans/*.md 2>/dev/null | head -1 || true)"
if [ -n "$PLAN_FILE" ]; then
    cp "$PLAN_FILE" /output/plan.md
    echo "Plan written to /output/plan.md"
fi

# --- Generate diff before container exits ---
source /usr/local/bin/entrypoint-cleanup.sh
