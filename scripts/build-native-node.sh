#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/native/pks-core"
OUT="${1:-$CORE/target/release/pks.node}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-native-node.sh currently supports the macOS PKS service runtime only" >&2
  exit 2
fi

deployment_target="${PKS_MACOS_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | awk -F. '{print $1 "." $2}')}"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export CFLAGS="-mmacosx-version-min=$deployment_target ${CFLAGS:-}"

cargo build --locked --release --manifest-path "$CORE/Cargo.toml"

node_include=""
for candidate in /opt/homebrew/include/node /usr/local/include/node "$(brew --prefix 2>/dev/null)/include/node"; do
  if [[ -f "$candidate/node_api.h" ]]; then
    node_include="$candidate"
    break
  fi
done
if [[ -z "$node_include" ]]; then
  echo "Node-API headers not found" >&2
  exit 3
fi

mkdir -p "$(dirname "$OUT")"
clang -bundle -undefined dynamic_lookup -mmacosx-version-min="$deployment_target"   -I "$node_include"   "$CORE/adapters/node.c"   "$CORE/target/release/libpks_core.a"   -o "$OUT"

node -e '
const addon = require(process.argv[1]);
if (!addon || typeof addon.search !== "function") process.exit(1);
' "$OUT"

echo "$OUT"
