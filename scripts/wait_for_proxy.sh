#!/usr/bin/env bash
# Wait for mitmweb to be ready by polling its web interface.
set -euo pipefail

PORT="${PROXY_WEB_PORT:-8081}"
TIMEOUT="${PROXY_WAIT_TIMEOUT:-30}"
ELAPSED=0

echo "Waiting for mitmweb on port $PORT..."

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if curl -sf "http://localhost:$PORT" > /dev/null 2>&1; then
        echo "mitmweb is ready."
        exit 0
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

echo "Error: mitmweb did not start within ${TIMEOUT}s" >&2
exit 1
