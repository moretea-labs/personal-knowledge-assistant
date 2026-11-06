#!/usr/bin/env bash
# Installs exactly one standalone PKS daemon. Forge's external plugin
# registration is managed separately through the Forge plugin authority.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/.local/share/personal-knowledge-system"
LABEL="com.personal-knowledge.pks"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$HOME/.pks/config.json"
NODE="$(command -v node)"
SERVICE="gui/$(id -u)/$LABEL"

test -f "$ROOT/dist/src/server.js"
test -f "$ROOT/package.json"
test -f "$ROOT/scripts/forge-provider.mjs"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/.pks"

if [[ -e "$PLIST" ]]; then
  configured="$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$PLIST")"
  if [[ "$configured" != "$DEST/dist/src/server.js" ]]; then
    echo "Existing PKS LaunchAgent uses a different executable; refusing to create a second path." >&2
    exit 2
  fi
else
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$NODE</string><string>$DEST/dist/src/server.js</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict><key>PKS_CONFIG</key><string>$CONFIG</string></dict>
  <key>StandardOutPath</key><string>$HOME/.pks/server.log</string>
  <key>StandardErrorPath</key><string>$HOME/.pks/server.err.log</string>
</dict></plist>
PLIST
fi

if [[ ! -f "$CONFIG" ]]; then
  cp "$ROOT/pks.config.example.json" "$CONFIG"
  sed -i '' "s#~#$HOME#g" "$CONFIG"
fi

stage="$(mktemp -d "$DEST/.stage-XXXXXX")"
rollback="$(mktemp -d "$DEST/.rollback-XXXXXX")"
mkdir -p "$stage/scripts"
cp -R "$ROOT/dist" "$ROOT/web" "$stage/"
cp "$ROOT/package.json" "$stage/package.json"
cp "$ROOT/scripts/forge-provider.mjs" "$stage/scripts/forge-provider.mjs"
"$NODE" --check "$stage/dist/src/server.js"
"$NODE" --check "$stage/scripts/forge-provider.mjs"

launchctl bootout "$SERVICE" 2>/dev/null || true
for n in {1..15}; do
  if ! /usr/sbin/lsof -nP -iTCP:3217 -sTCP:LISTEN | grep -q node; then break; fi
  sleep 0.2
done
if /usr/sbin/lsof -nP -iTCP:3217 -sTCP:LISTEN | grep -q node; then
  echo "Port 3217 is still in use, refusing to overwrite the installed daemon." >&2
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  exit 3
fi

mkdir -p "$rollback/scripts" "$DEST/scripts"
for part in dist web package.json scripts/forge-provider.mjs; do
  if [[ -e "$DEST/$part" ]]; then mv "$DEST/$part" "$rollback/$part"; fi
  mv "$stage/$part" "$DEST/$part"
done
healthy=0
if launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  for n in {1..20}; do
    if /usr/bin/curl -fsS --max-time 2 "http://127.0.0.1:3217/api/status" \
        | "$NODE" -e 'let v="";process.stdin.on("data",x=>v+=x);process.stdin.on("end",()=>{try{const s=JSON.parse(v);process.exit(typeof s.documents==="number"&&typeof s.chunks==="number"?0:1)}catch{process.exit(1)}})' >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 0.5
  done
fi
if [[ "$healthy" -ne 1 ]]; then
  echo "PKS health check failed; restoring previous installation." >&2
  launchctl bootout "$SERVICE" 2>/dev/null || true
  for part in dist web package.json scripts/forge-provider.mjs; do
    rm -rf "$DEST/$part"
    if [[ -e "$rollback/$part" ]]; then mv "$rollback/$part" "$DEST/$part"; fi
  done
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  exit 4
fi
echo "PKS standalone installed at $DEST; http://127.0.0.1:3217"
echo "Previous binaries retained at $rollback until verified."
