#!/bin/bash
# Quick test of the vix binary build process

VIX_LOCAL="$HOME/Developer/vix"
VIX_BIN_STAGED="/tmp/vix-build-test"

if [ ! -d "$VIX_LOCAL" ]; then
    echo "Error: vix source not found at $VIX_LOCAL"
    exit 1
fi

echo "Testing vix binary build with tree-sitter support..."
rm -rf "$VIX_BIN_STAGED"
mkdir -p "$VIX_BIN_STAGED"

echo "Building in Docker container..."
docker run --rm \
    -v "$VIX_LOCAL:/src" \
    -v "$VIX_BIN_STAGED:/out" \
    -w /src \
    golang:1.26-bookworm \
    bash -c "apt-get update -qq && apt-get install -y -qq gcc && \
             echo 'Building vix...' && \
             go build -o /out/vix ./cmd/vix && \
             echo 'Building vix-daemon...' && \
             go build -o /out/vix-daemon ./cmd/vix-daemon"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Build successful!"
    echo "Binary info:"
    ls -lh "$VIX_BIN_STAGED/"
    file "$VIX_BIN_STAGED/vix"
    file "$VIX_BIN_STAGED/vix-daemon"
    rm -rf "$VIX_BIN_STAGED"
else
    echo "❌ Build failed"
    exit 1
fi
