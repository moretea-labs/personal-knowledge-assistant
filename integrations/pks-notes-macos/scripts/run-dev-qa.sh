#!/bin/bash
set -euo pipefail
echo "The alternate PKS Notes QA Fixture.app launcher is retired: it would create a second app identity." >&2
echo "Run static tests and build on the canonical branch; for native GUI install only ~/Applications/Leafspan.app via scripts/install-macos.sh after closing existing PKS/Leafspan instances safely." >&2
exit 64
