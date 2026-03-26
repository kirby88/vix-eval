#!/usr/bin/env bash
# Shared entrypoint logic sourced by agent-specific entrypoints.
# Expects AGENT_TYPE to be set by the caller.

set -euo pipefail

# Ensure pipx binaries are on PATH
export PATH="$PATH:/root/.local/bin"

# Set a default git identity for commits inside the container
git config --global user.email "eval@vix-eval.local"
git config --global user.name "vix-eval"

# --- Repository setup ---
if [ "${REPO_ENABLED:-false}" = "true" ] && [ -n "${REPO_URL:-}" ]; then
    echo "Cloning $REPO_URL ..."
    git clone "$REPO_URL" /workspace
    if [ -n "${REPO_COMMIT:-}" ]; then
        echo "Checking out $REPO_COMMIT ..."
        git -C /workspace checkout "$REPO_COMMIT"
    fi
else
    mkdir -p /workspace
fi

# --- Copy staged workspace files ---
if [ -d /staged-files ] && [ "$(ls -A /staged-files 2>/dev/null)" ]; then
    echo "Copying workspace files..."
    cp -r /staged-files/. /workspace/
    # Init a git repo so diffs are captured on exit
    if [ ! -d /workspace/.git ]; then
        git -C /workspace init -q
        git -C /workspace add -A
        git -C /workspace commit -q -m "initial workspace files"
    fi
fi

# Ensure /workspace is always a git repo so diffs are captured on exit
if [ ! -d /workspace/.git ]; then
    git -C /workspace init -q
    git -C /workspace add -A
    git -C /workspace commit -q --allow-empty -m "initial (empty workspace)"
fi

# Tag the baseline so cleanup can diff against it even if the agent makes commits
git -C /workspace tag -f eval-baseline

cd /workspace

# --- Proxy setup ---
if [ "${PROXY_ENABLED:-false}" = "true" ]; then
    LISTEN_HOST="${PROXY_LISTEN_HOST:-127.0.0.1}"
    LISTEN_PORT="${PROXY_LISTEN_PORT:-58000}"
    WEB_PORT="${PROXY_WEB_PORT:-8081}"
    TARGET="${PROXY_TARGET:-https://api.anthropic.com}"
    FLOW="${FLOW_FILENAME:-requests.flow}"

    INTERNAL_WEB_PORT=$((WEB_PORT + 1))

    echo "Starting mitmweb (reverse proxy → $TARGET) ..."
    mitmweb \
        --listen-host "$LISTEN_HOST" \
        --listen-port "$LISTEN_PORT" \
        --web-host 127.0.0.1 \
        --web-port "$INTERNAL_WEB_PORT" \
        --mode "reverse:$TARGET" \
        --save-stream-file "/output/$FLOW" \
        -s /opt/vix-eval/redact_flow.py \
        --set connection_strategy=lazy \
        --no-web-open-browser \
        > /tmp/mitmweb.log 2>&1 &

    # Forward the published port to mitmweb's localhost-only web UI (bypasses auth)
    socat TCP-LISTEN:"$WEB_PORT",fork,reuseaddr TCP:127.0.0.1:"$INTERNAL_WEB_PORT" &

    wait_for_proxy.sh

    export ANTHROPIC_BASE_URL="http://127.0.0.1:$LISTEN_PORT"
    echo "export ANTHROPIC_BASE_URL=\"$ANTHROPIC_BASE_URL\"" >> /root/.bashrc
    echo "Proxy ready: ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
    MITM_URL="http://localhost:${PROXY_HOST_PORT:-$WEB_PORT}"
fi

# --- Banner ---
AGENT_LABEL="${AGENT_TYPE:-claude-code} ${AGENT_VERSION:-latest}"
if [ -n "${AGENT_NAME:-}" ] && [ "$AGENT_NAME" != "${AGENT_TYPE:-}" ]; then
    AGENT_LABEL="$AGENT_NAME ($AGENT_LABEL)"
fi

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'

echo ""
echo -e "${C_CYAN}${C_BOLD}  ============================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}    vix-eval test harness${C_RESET}"
echo -e "${C_CYAN}  ============================================${C_RESET}"
echo -e "  ${C_DIM}Test ID${C_RESET}   ${C_BOLD}${TEST_ID:-unknown}${C_RESET}"
echo -e "  ${C_DIM}Agent${C_RESET}     ${C_GREEN}${AGENT_LABEL}${C_RESET}"
if [ -n "${MITM_URL:-}" ]; then
    echo -e "  ${C_DIM}Proxy${C_RESET}     ${C_GREEN}on${C_RESET} ${C_DIM}|${C_RESET} ${C_YELLOW}${MITM_URL}${C_RESET}"
else
    echo -e "  ${C_DIM}Proxy${C_RESET}     off"
fi
