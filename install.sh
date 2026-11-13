#!/usr/bin/env bash
# Pearl AI Companion — Setup & Installation Script
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo "=== Installing Pearl AI Companion on MacBook Neo ==="

# 1. Compile native binaries
echo "-> Compiling native guardrail (pearl-guard)..."
clang -O3 src/guard/pearl-guard.c -o bin/pearl-guard
chmod +x bin/pearl-guard

echo "-> Compiling native Liquid Glass HUD (pearl-hud)..."
swiftc -O -framework AppKit -framework AVFoundation src/hud/PearlHUD.swift -o bin/pearl-hud
chmod +x bin/pearl-hud

# 2. Deploy to ~/.local/bin
echo "-> Deploying executables to ~/.local/bin..."
mkdir -p "$HOME/.local/bin"
cp bin/pearl* "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/pearl"*

# 3. Initialize state directory
echo "-> Initializing ~/.pearl state directory..."
mkdir -p "$HOME/.pearl"
for f in state_template/*; do
    base="$(basename "$f")"
    if [ ! -f "$HOME/.pearl/$base" ]; then
        cp "$f" "$HOME/.pearl/"
        echo "   Initialized ~/.pearl/$base"
    fi
done

# 4. Optional launch agent installation
if [ -f "config/com.rossonerian.pearl-server.plist" ]; then
    echo "-> Installing Pearl HTTP server LaunchAgent..."
    mkdir -p "$HOME/Library/LaunchAgents"
    cp config/com.rossonerian.pearl-server.plist "$HOME/Library/LaunchAgents/"
fi

echo "=== Pearl installation complete! ==="
echo "Try running:"
echo "  pearl 'Pearl, what is your mood right now?'"
echo "  pearl brief"
echo "  pearl diary"
