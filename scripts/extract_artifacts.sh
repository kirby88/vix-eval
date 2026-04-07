#!/usr/bin/env bash
# Summarize artifacts from a completed test run.
# Usage: extract_artifacts.sh <output_dir> <test_id> [flow_filename]
set -euo pipefail

OUTPUT_DIR="${1:?Usage: extract_artifacts.sh <output_dir> <test_id> [flow_filename]}"
TEST_ID="${2:?Usage: extract_artifacts.sh <output_dir> <test_id> [flow_filename]}"
FLOW_FILENAME="${3:-cc.flow}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

ok()    { echo -e "  ${GREEN}OK${RESET}    $1"; }
warn()  { echo -e "  ${YELLOW}WARN${RESET}  $1"; }
error() { echo -e "  ${RED}ERROR${RESET} $1"; }

DIFF_OK=false
PLAN_OK=false

echo ""
echo -e "${BOLD}=== Artifacts for: $TEST_ID ===${RESET}"
echo ""

# --- Diff ---
DIFF_FILE="$OUTPUT_DIR/changes.diff"
if [ -f "$DIFF_FILE" ] && [ -s "$DIFF_FILE" ]; then
    PLUS=$(grep -c '^+' "$DIFF_FILE" 2>/dev/null || echo 0)
    MINUS=$(grep -c '^-' "$DIFF_FILE" 2>/dev/null || echo 0)
    FILES=$(grep -c '^diff ' "$DIFF_FILE" 2>/dev/null || echo 0)
    ok "Diff: $FILES file(s), +$PLUS/-$MINUS lines → $DIFF_FILE"
    DIFF_OK=true
else
    warn "No diff (agent made no changes)"
fi

# --- Plan ---
PLAN_FILE="$OUTPUT_DIR/plan.md"
if [ -f "$PLAN_FILE" ] && [ -s "$PLAN_FILE" ]; then
    ok "Plan → $PLAN_FILE"
    PLAN_OK=true
else
    error "No plan file found"
fi

# --- Flow ---
FLOW_FILE="$OUTPUT_DIR/$FLOW_FILENAME"
if [ -f "$FLOW_FILE" ]; then
    FLOW_SIZE=$(wc -c < "$FLOW_FILE" | tr -d ' ')
    ok "Flow: ${FLOW_SIZE} bytes → $FLOW_FILE"
else
    warn "No flow file"
fi

# --- Summary ---
echo ""
echo -e "${BOLD}--- Output ---${RESET}"
echo -e "  $OUTPUT_DIR/"
ls -1 "$OUTPUT_DIR/" | grep -v '^plans$' | sed 's/^/    /'
echo ""

if $DIFF_OK && $PLAN_OK; then
    exit 0
else
    exit 1
fi
