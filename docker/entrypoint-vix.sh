#!/usr/bin/env bash
set -euo pipefail

AGENT_TYPE="vix"
source /usr/local/bin/entrypoint-common.sh

# --- Override with user-provided settings if mounted (before daemon starts) ---
if [ -d /staged-settings ]; then
    echo "Applying user settings from /staged-settings ..."
    cp -r /staged-settings/. /root/.vix/
fi

# --- Start vix-daemon (after proxy so it inherits ANTHROPIC_BASE_URL) ---
VIX_DAEMON_LOG="/output/vix-daemon.log"
echo "Starting vix-daemon (workdir: /workspace) ..."
vix-daemon > "$VIX_DAEMON_LOG" 2>&1 &
VIX_DAEMON_PID=$!
echo -e "  ${C_DIM}Daemon${C_RESET}    ${C_GREEN}on${C_RESET} ${C_DIM}|${C_RESET} PID ${VIX_DAEMON_PID} ${C_DIM}|${C_RESET} tail -f /output/vix-daemon.log"
echo -e "${C_CYAN}  ============================================${C_RESET}"
echo ""

# --- Record agent version ---
echo "vix: ${VIX_COMMIT:-unknown}" > /output/versions.txt

# --- Interactive shell (not exec — we need to run cleanup after) ---
bash -l || true

# --- Copy plan ---
PLAN_FILE="$(ls -t /workspace/.vix/plans/*.md /root/.vix/plans/*.md 2>/dev/null | head -1 || true)"
if [ -n "$PLAN_FILE" ]; then
    cp "$PLAN_FILE" /output/plan.md
    echo "Plan written to /output/plan.md"
fi

# --- Generate diff before container exits ---
source /usr/local/bin/entrypoint-cleanup.sh
