#!/bin/bash
set -euo pipefail

leafspan_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$leafspan_root/../.." && pwd)"
source_core="$repo_root/native/pks-core"
output="${1:-$leafspan_root/.build/pks-native/PKSCore.xcframework}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "PKSCore XCFramework generation requires macOS." >&2
  exit 2
fi
if [[ ! -f "$source_core/Cargo.toml" || ! -f "$source_core/include/pks_core.h" ]]; then
  echo "PKS core source is incomplete at $source_core" >&2
  exit 3
fi
if [[ ! -f "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml" ]]; then
  echo "The selected Rust toolchain does not include rust-src, required for macOS 14 build-std." >&2
  exit 4
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
core="$tmp/pks-core"
mkdir -p "$core"
rsync -a --exclude target/ "$source_core/" "$core/"

headers="$tmp/headers"
mkdir -p "$headers"
cp "$core/include/pks_core.h" "$headers/pks_core.h"
cat > "$headers/module.modulemap" <<'MODULEMAP'
module PKSCore {
    header "pks_core.h"
    export *
}
MODULEMAP

export RUSTC_BOOTSTRAP=1

build_target() {
  local triple="$1"
  local arch="$2"
  local target_dir="$tmp/target-$arch"
  local rustflags_var="CARGO_TARGET_$(echo "$triple" | tr '[:lower:]-' '[:upper:]_')_RUSTFLAGS"
  local cflags_var="CFLAGS_$(echo "$triple" | tr '-' '_')"

  env     CARGO_TARGET_DIR="$target_dir"     "$rustflags_var=-C link-arg=-mmacosx-version-min=14.0"     "$cflags_var=-arch $arch -mmacosx-version-min=14.0"     cargo build       -Z build-std=std,panic_abort       --locked       --release       --manifest-path "$core/Cargo.toml"       --target "$triple"

  local library="$target_dir/$triple/release/libpks_core.a"
  test -f "$library"
  lipo "$library" -verify_arch "$arch"
  printf '%s\n' "$library"
}

arm64_lib="$(build_target aarch64-apple-darwin arm64 | tail -1)"
x86_64_lib="$(build_target x86_64-apple-darwin x86_64 | tail -1)"

universal="$tmp/libpks_core.a"
lipo -create "$arm64_lib" "$x86_64_lib" -output "$universal"
lipo "$universal" -verify_arch arm64
lipo "$universal" -verify_arch x86_64

cat > "$tmp/link-smoke.c" <<'C'
#include "pks_core.h"
int main(void) {
    PksHandle *handle = pks_open("/nonexistent/pks.sqlite");
    if (handle) pks_close(handle);
    return 0;
}
C

for arch in arm64 x86_64; do
  binary="$tmp/link-smoke-$arch"
  clang -arch "$arch" -mmacosx-version-min=14.0     -I "$headers" "$tmp/link-smoke.c" "$universal" -o "$binary"
  build_info="$(xcrun vtool -show-build "$binary")"
  echo "$build_info"
  grep -q "minos 14.0" <<<"$build_info" || {
    echo "Expected macOS 14 deployment target for $arch PKSCore link smoke." >&2
    exit 5
  }
done

rm -rf "$output"
mkdir -p "$(dirname "$output")"
xcodebuild -create-xcframework   -library "$universal"   -headers "$headers"   -output "$output" >/dev/null

test -d "$output"
test -f "$output/Info.plist"
echo "PKSCore XCFramework: $output"
lipo -info "$universal"
