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
arch="$(uname -m)"
case "$arch" in
  arm64) target_triple="aarch64-apple-darwin" ;;
  x86_64) target_triple="x86_64-apple-darwin" ;;
  *) echo "Unsupported macOS architecture: $arch" >&2; exit 2 ;;
esac

target_env="$(echo "$target_triple" | tr '[:lower:]-' '[:upper:]_')"
cflags_env="CFLAGS_$(echo "$target_triple" | tr '-' '_')"
target_dir="$CORE/target"

env   CARGO_TARGET_DIR="$target_dir"   "CARGO_TARGET_${target_env}_RUSTFLAGS=-C link-arg=-mmacosx-version-min=$deployment_target"   "$cflags_env=-mmacosx-version-min=$deployment_target"   cargo build --locked --release --target "$target_triple" --manifest-path "$CORE/Cargo.toml"

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

library="$target_dir/$target_triple/release/libpks_core.a"
test -f "$library"
mkdir -p "$(dirname "$OUT")"
clang -arch "$arch" -bundle -undefined dynamic_lookup   -mmacosx-version-min="$deployment_target"   -I "$node_include"   "$CORE/adapters/node.c"   "$library"   -o "$OUT"

node -e '
const addon = require(process.argv[1]);
if (!addon || typeof addon.search !== "function") process.exit(1);
' "$OUT"

echo "$OUT"
