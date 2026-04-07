#!/usr/bin/env bash
# Sourced at the end of agent entrypoints to generate the diff artifact.

echo ""
echo "Generating artifacts..."

if [ -d /workspace/.git ]; then
    DIFF_FILE="/output/changes.diff"
    # Stage everything and diff against the baseline tag to capture all changes,
    # including files the agent may have already committed.
    git -C /workspace add -A
    git -C /workspace diff --cached eval-baseline -- . ':!.claude' ':!.vix' > "$DIFF_FILE"

    if [ -s "$DIFF_FILE" ]; then
        echo "Diff written to /output/changes.diff"
    else
        rm -f "$DIFF_FILE"
        echo "No changes detected."
    fi
else
    echo "No git repo in /workspace, skipping diff."
fi
echo "Done."
