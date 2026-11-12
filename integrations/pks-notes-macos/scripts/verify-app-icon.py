#!/usr/bin/env python3
"""Check the selected artwork before installation, packaging, or CI."""
import hashlib
import plistlib
import sys
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    expected_paths = {
        "Resources/LeafspanIcon-master.png",
        "Resources/AppIcon-1024.png",
        "Resources/AppIcon.icns",
    }
    try:
        entries = [line.split() for line in (root / "Resources/AppIcon.sha256").read_text().splitlines() if line.strip()]
        if len(entries) != 3 or any(len(entry) != 2 for entry in entries):
            raise ValueError("Icon manifest must contain exactly three SHA-256 entries")
        if {entry[1] for entry in entries} != expected_paths:
            raise ValueError("Icon manifest does not cover the three canonical assets")
        for expected, relative_path in entries:
            actual = hashlib.sha256((root / relative_path).read_bytes()).hexdigest()
            if actual != expected:
                raise ValueError(f"Selected icon changed: {relative_path}")
        with (root / "Resources/Info.plist").open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIconFile") != "AppIcon":
                raise ValueError("Bundle icon must refer to the selected AppIcon.icns")
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Leafspan icon verification failed: {error}", file=sys.stderr)
        return 1
    print("Leafspan selected icon verified (master, 1024 PNG, ICNS, bundle mapping).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
