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
NPM="$(command -v npm)"
SERVICE="gui/$(id -u)/$LABEL"

health_ready() {
  /usr/bin/curl -fsS --max-time 2 "http://127.0.0.1:3217/api/status" \
    | "$NODE" -e 'let v="";process.stdin.on("data",x=>v+=x);process.stdin.on("end",()=>{try{const s=JSON.parse(v);process.exit(typeof s.documents==="number"&&typeof s.chunks==="number"&&s.searchEngine==="native"?0:1)}catch{process.exit(1)}})' \
    >/dev/null 2>&1
}

bootstrap_and_wait() {
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || return 1
  # A freshly re-registered KeepAlive job can be launchd-throttled after repeated
  # same-label restarts. kickstart asks launchd to start the registered job now
  # without killing an already-running instance.
  launchctl kickstart "$SERVICE" >/dev/null 2>&1 || true
  for n in {1..60}; do
    if health_ready; then return 0; fi
    sleep 0.5
  done
  return 1
}

test -f "$ROOT/package.json"
test -f "$ROOT/package-lock.json"
test -f "$ROOT/tsconfig.json"
test -f "$ROOT/pks.config.example.json"
test -d "$ROOT/src"
test -d "$ROOT/native/pks-core"
test -f "$ROOT/scripts/build-native-node.sh"
test -f "$ROOT/scripts/forge-provider.mjs"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  service_dirty="$(git -C "$ROOT" status --porcelain --     src forge-adapter native/pks-core package.json package-lock.json tsconfig.json     scripts/build-native-node.sh scripts/forge-provider.mjs)"
  if [[ -n "$service_dirty" ]]; then
    echo "Refusing to install PKS daemon from dirty service source; use a clean commit/archive." >&2
    printf '%s\n' "$service_dirty" >&2
    exit 6
  fi
fi

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/.pks"

build_root="$(mktemp -d "${TMPDIR:-/tmp}/pks-service-build.XXXXXX")"
stage=""
cleanup_temp() {
  if [[ -n "${build_root:-}" && -d "$build_root" ]]; then rm -rf "$build_root"; fi
  if [[ -n "${stage:-}" && -d "$stage" ]]; then rm -rf "$stage"; fi
}
trap cleanup_temp EXIT

mkdir -p "$build_root/scripts" "$build_root/native"
cp "$ROOT/package.json" "$ROOT/package-lock.json" "$ROOT/tsconfig.json" "$build_root/"
cp -R "$ROOT/src" "$build_root/src"
if [[ -d "$ROOT/forge-adapter" ]]; then cp -R "$ROOT/forge-adapter" "$build_root/forge-adapter"; fi
/usr/bin/rsync -a --exclude target "$ROOT/native/pks-core/" "$build_root/native/pks-core/"
cp "$ROOT/scripts/build-native-node.sh" "$build_root/scripts/build-native-node.sh"
cp "$ROOT/scripts/forge-provider.mjs" "$build_root/scripts/forge-provider.mjs"

(
  cd "$build_root"
  "$NPM" ci --ignore-scripts --no-audit --no-fund --prefer-offline
  "$NPM" run build
  bash scripts/build-native-node.sh dist/native/pks.node >/dev/null
)

test -f "$build_root/dist/src/server.js"
test -f "$build_root/dist/src/core/service.js"
test -f "$build_root/dist/src/core/native-search.js"
test -f "$build_root/dist/native/pks.node"
"$NODE" --check "$build_root/dist/src/server.js"
"$NODE" --check "$build_root/dist/src/core/native-search.js"

PKS_NATIVE_ADDON_PATH="$build_root/dist/native/pks.node"   "$NODE" --input-type=module - "$build_root/dist/src/core/service.js" <<'NODE'
import { pathToFileURL } from 'node:url';
const { PKSService } = await import(pathToFileURL(process.argv[2]).href);
const service = new PKSService({
  dataDir: '/tmp/pks-installer-preflight',
  managedStore: '/tmp/pks-installer-preflight-managed',
  port: 0,
  host: '127.0.0.1',
  sourceRoots: [],
  semantic: { provider: 'hash', dimensions: 256 },
  forge: { enabled: false }
});
if (service.searchEngine !== 'native') process.exit(1);
NODE

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
cp -R "$build_root/dist" "$stage/"
cp "$build_root/package.json" "$stage/package.json"
cp "$build_root/scripts/forge-provider.mjs" "$stage/scripts/forge-provider.mjs"
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
for part in dist package.json scripts/forge-provider.mjs; do
  if [[ -e "$DEST/$part" ]]; then mv "$DEST/$part" "$rollback/$part"; fi
  mv "$stage/$part" "$DEST/$part"
done
if ! bootstrap_and_wait; then
  echo "PKS health check failed after launchd bootstrap/kickstart; restoring previous installation." >&2
  launchctl print "$SERVICE" >&2 2>/dev/null || true
  tail -40 "$HOME/.pks/server.err.log" >&2 2>/dev/null || true
  launchctl bootout "$SERVICE" 2>/dev/null || true
  for part in dist package.json scripts/forge-provider.mjs; do
    rm -rf "$DEST/$part"
    if [[ -e "$rollback/$part" ]]; then mv "$rollback/$part" "$DEST/$part"; fi
  done
  if ! bootstrap_and_wait; then
    echo "PKS rollback restored files but the previous daemon did not become healthy." >&2
    launchctl print "$SERVICE" >&2 2>/dev/null || true
    exit 5
  fi
  echo "Previous PKS installation restored and verified healthy." >&2
  exit 4
fi
if [[ -d "$DEST/web" ]]; then rm -rf -- "$DEST/web"; fi
echo "PKS API daemon installed at $DEST; API: http://127.0.0.1:3217/api/status"
echo "Previous binaries retained at $rollback until verified."
