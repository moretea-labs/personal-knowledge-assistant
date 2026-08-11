#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.local/share/personal-knowledge-assistant"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/.pks"
cp -R "$ROOT/dist" "$ROOT/web" "$ROOT/package.json" "$DEST/"
NODE="$(command -v node)"
LABEL="com.moretea.personal-knowledge-assistant"
LEGACY_LABEL="com.personal-knowledge.pks"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>$LABEL</string><key>ProgramArguments</key><array><string>$NODE</string><string>$DEST/dist/src/server.js</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>EnvironmentVariables</key><dict><key>PKS_CONFIG</key><string>$HOME/.pks/config.json</string></dict><key>StandardOutPath</key><string>$HOME/.pks/server.log</string><key>StandardErrorPath</key><string>$HOME/.pks/server.err.log</string></dict></plist>
PLIST
if [ ! -f "$HOME/.pks/config.json" ]; then cp "$ROOT/pks.config.example.json" "$HOME/.pks/config.json"; sed -i '' "s#~#$HOME#g" "$HOME/.pks/config.json"; fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "PKS installed. UI: http://127.0.0.1:3217"
