#!/usr/bin/env bash
# Install optional languages requested by a task config.
# Usage: install-languages.sh lang1,lang2,...
set -euo pipefail

LANGUAGES="${1:-}"
[ -z "$LANGUAGES" ] && exit 0

IFS=',' read -ra LANGS <<< "$LANGUAGES"

for lang in "${LANGS[@]}"; do
    case "$lang" in
        rust)
            echo "Installing Rust ..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            ;;
        swift)
            echo "Installing Swift ..."
            apt-get update && apt-get install -y --no-install-recommends \
                binutils libc6-dev libcurl4-openssl-dev libedit2 \
                libncurses-dev libsqlite3-0 libxml2-dev libz3-dev \
                && rm -rf /var/lib/apt/lists/*
            ARCH="$(uname -m)"
            case "$ARCH" in
                aarch64|arm64) SWIFT_ARCH="aarch64" ;;
                x86_64)        SWIFT_ARCH="" ;;
                *) echo "Error: unsupported architecture $ARCH for Swift" >&2; exit 1 ;;
            esac
            if [ -n "$SWIFT_ARCH" ]; then
                SWIFT_URL="https://download.swift.org/swift-6.0.3-release/debian12-${SWIFT_ARCH}/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-debian12-${SWIFT_ARCH}.tar.gz"
            else
                SWIFT_URL="https://download.swift.org/swift-6.0.3-release/debian12/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-debian12.tar.gz"
            fi
            curl -fsSL "$SWIFT_URL" -o /tmp/swift.tar.gz \
                && tar xzf /tmp/swift.tar.gz -C /usr/local --strip-components=2 \
                && rm /tmp/swift.tar.gz
            ;;
        typescript)
            echo "Installing TypeScript ..."
            npm install -g typescript ts-node @types/node
            ;;
        pnpm)
            echo "Installing pnpm ..."
            npm install -g pnpm
            ;;
        python)
            echo "Installing Python tooling ..."
            apt-get update && apt-get install -y --no-install-recommends \
                python3-venv python3-dev \
                && rm -rf /var/lib/apt/lists/*
            python3 -m pip install --break-system-packages --upgrade pip setuptools wheel
            ;;
        *)
            echo "Warning: unknown language '$lang', skipping." >&2
            ;;
    esac
done
