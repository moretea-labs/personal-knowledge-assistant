#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CARGO_TARGET_DIR="$tmp/target"
export RUSTC_BOOTSTRAP=1

node_include="${NODE_INCLUDE:-$(brew --prefix)/include/node}"
arch="$(uname -m)"
case "$arch" in
  arm64) target_triple="aarch64-apple-darwin" ;;
  x86_64) target_triple="x86_64-apple-darwin" ;;
  *) echo "Unsupported macOS architecture: $arch" >&2; exit 1 ;;
esac
swift_target="$arch-apple-macosx14.0"
target_env="$(echo "$target_triple" | tr '[:lower:]-' '[:upper:]_')"
cflags_env="CFLAGS_$(echo "$target_triple" | tr '-' '_')"

env "CARGO_TARGET_${target_env}_RUSTFLAGS=-C link-arg=-mmacosx-version-min=14.0"     "$cflags_env=-mmacosx-version-min=14.0"     cargo build -Z build-std=std,panic_abort --locked --release --target "$target_triple"

lib="$CARGO_TARGET_DIR/$target_triple/release/libpks_core.a"
test -f "$lib"

cat > "$tmp/index-smoke.c" <<'C'
#include "pks_core.h"

int main(int argc, char **argv) {
    if (argc != 2) return 64;

    PksHandle *handle = pks_open_embedded(argv[1]);
    if (!handle) return 65;

    const char *document =
        "{\"contractVersion\":1,"
        "\"sourceId\":\"smoke\","
        "\"sourceType\":\"local\","
        "\"sourceName\":\"Smoke\","
        "\"rootUri\":\"/tmp\","
        "\"uri\":\"/tmp/Alpha.md\","
        "\"title\":\"Alpha\","
        "\"text\":\"alpha searchable body\","
        "\"documentType\":\"note\"}";

    char *result = pks_index_document_json(handle, document);
    if (!result) {
        pks_close(handle);
        return 66;
    }

    pks_string_free(result);
    pks_close(handle);
    return 0;
}
C

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation

let database = URL(fileURLWithPath: CommandLine.arguments[1])
let request = try JSONSerialization.data(withJSONObject: [
    "contractVersion": 1,
    "query": "Alpha",
    "mode": "auto",
    "limit": 5
])
let response = try PKSNative.search(database: database, request: request)
let object = try JSONSerialization.jsonObject(with: response) as! [String: Any]
guard object["contractVersion"] as? Int == 1,
      let results = object["results"] as? [[String: Any]],
      results.contains(where: { $0["title"] as? String == "Alpha" }) else {
    fatalError("Swift adapter did not return Alpha")
}
SWIFT

{
  clang -arch "$arch" -mmacosx-version-min=14.0     -I include "$tmp/index-smoke.c" "$lib" -o "$tmp/index-smoke"
  clang -bundle -undefined dynamic_lookup -mmacosx-version-min=14.0     -I "$node_include" adapters/node.c "$lib" -o "$tmp/pks.node"
  swiftc -target "$swift_target" -I adapters     adapters/PKSNative.swift "$tmp/main.swift" "$lib"     -o "$tmp/swift-smoke"
} 2> "$tmp/link.log"

if grep -q "built for newer 'macOS' version" "$tmp/link.log"; then
  cat "$tmp/link.log" >&2
  echo "Native archive contains objects above the macOS 14 deployment target" >&2
  exit 1
fi
cat "$tmp/link.log" >&2

"$tmp/index-smoke" "$tmp/golden.sqlite"

node -e '
const addon = require(process.argv[1]);
const db = process.argv[2];
const response = JSON.parse(addon.search(db, JSON.stringify({
  contractVersion: 1, query: "Alpha", mode: "auto", limit: 5
})));
if (response.contractVersion !== 1) throw new Error("bad contract version");
if (!response.results.some(result => result.title === "Alpha")) {
  throw new Error("Node adapter did not return Alpha");
}
' "$tmp/pks.node" "$tmp/golden.sqlite"

"$tmp/swift-smoke" "$tmp/golden.sqlite"

for binary in "$tmp/index-smoke" "$tmp/pks.node" "$tmp/swift-smoke"; do
  build_info="$(xcrun vtool -show-build "$binary")"
  echo "$build_info"
  grep -q "minos 14.0" <<<"$build_info" || {
    echo "Expected macOS 14 deployment target for $binary" >&2
    exit 1
  }
done

echo "Node and Swift adapters passed positive in-process search with macOS 14 deployment target"
