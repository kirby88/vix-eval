#!/usr/bin/env bash
# Main entrypoint for running a vix-eval test.
# Usage: ./run_test.sh [--agent <name>] [--settings <dir>] <path-to-config.yaml>
# Agent aliases: cc → claude-code
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")")"

# --- Parse args ---
AGENT_FLAG=""
CONFIG_FILE=""
SETTINGS_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --agent|-a)
            AGENT_FLAG="$2"
            shift 2
            ;;
        --settings|-s)
            SETTINGS_DIR="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--agent <name>] [--settings <dir>] <config.yaml>" >&2
            exit 1
            ;;
        *)
            CONFIG_FILE="$1"
            shift
            ;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo "Usage: $0 [--agent <name>] [--settings <dir>] <config.yaml>" >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# --- Load .env ---
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: .env file not found. Copy .env.example to .env and set your API key." >&2
    exit 1
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Error: ANTHROPIC_API_KEY is not set in .env" >&2
    exit 1
fi

# --- Parse config ---
ENV_FILE="/tmp/harness_env_$$"
PARSE_ARGS=("$CONFIG_FILE" --output "$ENV_FILE")
if [ -n "$AGENT_FLAG" ]; then
    PARSE_ARGS+=(--agent "$AGENT_FLAG")
fi

python3 "$SCRIPT_DIR/scripts/parse_config.py" "${PARSE_ARGS[@]}"

set -a
source "$ENV_FILE"
set +a

echo "Test ID: $TEST_ID"

# --- Verify Dockerfile exists for agent type ---
DOCKERFILE="$SCRIPT_DIR/docker/Dockerfile.$AGENT_TYPE"
if [ ! -f "$DOCKERFILE" ]; then
    echo "Error: no Dockerfile for agent type '$AGENT_TYPE': $DOCKERFILE" >&2
    exit 1
fi

# --- Prepare output directory (inside the task's own directory) ---
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="$CONFIG_DIR/results/$AGENT_NAME/$RUN_TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

# --- Stage vix source for in-container build ---
VIX_LOCAL="$HOME/Developer/vix"
VIX_SRC_STAGED=""
if [ "$AGENT_TYPE" = "vix" ]; then
    VIX_SRC_STAGED="$SCRIPT_DIR/.vix-src"
    if [ ! -d "$VIX_LOCAL" ]; then
        echo "Error: local vix source not found at $VIX_LOCAL" >&2
        exit 1
    fi
    echo "Staging vix source from $VIX_LOCAL ..."
    rm -rf "$VIX_SRC_STAGED"
    cp -a "$VIX_LOCAL" "$VIX_SRC_STAGED"
    rm -rf "$VIX_SRC_STAGED/.git" "$VIX_SRC_STAGED/.vix" "$VIX_SRC_STAGED/.claude" "$VIX_SRC_STAGED/evaluation"
fi

# --- Build image (hash-based tag, per agent type) ---
HASH_INPUTS="$DOCKERFILE $SCRIPT_DIR/docker/entrypoint-common.sh $SCRIPT_DIR/docker/entrypoint-cleanup.sh $SCRIPT_DIR/docker/entrypoint-*.sh $SCRIPT_DIR/scripts/wait_for_proxy.sh $SCRIPT_DIR/scripts/redact_flow.py $SCRIPT_DIR/docker/install-languages.sh"
LANG_TAG="${LANGUAGES:-}"
if [ -n "$VIX_SRC_STAGED" ]; then
    VIX_REV="$(git -C "$VIX_LOCAL" rev-parse HEAD 2>/dev/null || echo "no-git")"
    IMAGE_TAG="vix-eval-${AGENT_TYPE}:$(echo "$VIX_REV $LANG_TAG" | cat - $HASH_INPUTS | shasum | cut -c1-12)"
else
    IMAGE_TAG="vix-eval-${AGENT_TYPE}:$(echo "$LANG_TAG" | cat - $HASH_INPUTS | shasum | cut -c1-12)"
fi

echo "Building image $IMAGE_TAG ..."
# Prune dangling images and build cache to avoid "no space left on device"
docker builder prune -f --filter "until=24h" >/dev/null 2>&1 || true
docker image prune -f >/dev/null 2>&1 || true
docker build -t "$IMAGE_TAG" --build-arg "LANGUAGES=$LANG_TAG" -f "$DOCKERFILE" "$SCRIPT_DIR"

# Clean up staged vix source
if [ -n "$VIX_SRC_STAGED" ] && [ -d "$VIX_SRC_STAGED" ]; then
    rm -rf "$VIX_SRC_STAGED"
fi

# --- Capture vix commit for version tracking ---
VIX_COMMIT="$(git -C "$VIX_LOCAL" rev-parse HEAD 2>/dev/null || echo "unknown")"

# --- Run container ---
DOCKER_ARGS=(
    -it --rm
    --env-file "$ENV_FILE"
    -e ANTHROPIC_API_KEY
    -e VIX_COMMIT="$VIX_COMMIT"
    -v "$OUTPUT_DIR:/output"
)

# Mount workspace directory if specified
if [ -n "${WORKSPACE_DIR:-}" ]; then
    if [ ! -d "$WORKSPACE_DIR" ]; then
        echo "Error: workspace directory not found: $WORKSPACE_DIR" >&2
        exit 1
    fi
    DOCKER_ARGS+=(-v "$WORKSPACE_DIR:/staged-files:ro")
    echo "Mounting workspace directory: $WORKSPACE_DIR"
fi

# Mount settings directory if specified
if [ -n "$SETTINGS_DIR" ]; then
    if [ ! -d "$SETTINGS_DIR" ]; then
        echo "Error: settings directory not found: $SETTINGS_DIR" >&2
        exit 1
    fi
    DOCKER_ARGS+=(-v "$(cd "$SETTINGS_DIR" && pwd):/staged-settings:ro")
    echo "Mounting settings directory: $SETTINGS_DIR"
fi

# Publish web UI port if proxy is enabled, finding an open host port
if [ "${PROXY_ENABLED:-false}" = "true" ]; then
    HOST_PORT="${PROXY_WEB_PORT:-8081}"
    while lsof -iTCP:"$HOST_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; do
        echo "Port $HOST_PORT is in use, trying next..."
        HOST_PORT=$((HOST_PORT + 1))
    done
    DOCKER_ARGS+=(-p "$HOST_PORT:${PROXY_WEB_PORT:-8081}" -e PROXY_HOST_PORT="$HOST_PORT")
    if [ "$HOST_PORT" != "${PROXY_WEB_PORT:-8081}" ]; then
        echo "Proxy web UI mapped to host port $HOST_PORT"
    fi
fi

echo "Starting container..."
docker run "${DOCKER_ARGS[@]}" "$IMAGE_TAG" || true

# --- Extract artifacts ---
echo ""
echo "Container exited. Extracting artifacts..."
bash "$SCRIPT_DIR/scripts/extract_artifacts.sh" "$OUTPUT_DIR" "$TEST_ID" "${FLOW_FILENAME:-requests.flow}"

# Cleanup
rm -f "$ENV_FILE"
