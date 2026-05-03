#!/usr/bin/env bash
# Verifies android/core-fixtures/ is byte-for-byte identical to
# ios/Tests/RoadSenseNSBootstrapTests/Fixtures/. Doc 12 mandates the copy
# (not symlink) so Windows contributors aren't gated on symlink permissions,
# but parity must be enforced in CI to keep cross-platform scoring honest.
#
# Exit 0: identical. Exit 1: drift detected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IOS_DIR="$REPO_ROOT/ios/Tests/RoadSenseNSBootstrapTests/Fixtures"
ANDROID_DIR="$REPO_ROOT/android/core-fixtures"

if [ ! -d "$IOS_DIR" ]; then
    echo "iOS fixtures dir missing: $IOS_DIR" >&2
    exit 1
fi
if [ ! -d "$ANDROID_DIR" ]; then
    echo "Android fixtures dir missing: $ANDROID_DIR" >&2
    exit 1
fi

drift=0
for src in "$IOS_DIR"/*.csv "$IOS_DIR"/*.expected.json; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    dst="$ANDROID_DIR/$name"
    if [ ! -f "$dst" ]; then
        echo "MISSING $dst" >&2
        drift=1
        continue
    fi
    if ! cmp -s "$src" "$dst"; then
        echo "DRIFT  $name" >&2
        drift=1
    fi
done

# Catch the reverse: extras in android/core-fixtures that aren't in iOS.
for dst in "$ANDROID_DIR"/*.csv "$ANDROID_DIR"/*.expected.json; do
    [ -e "$dst" ] || continue
    name="$(basename "$dst")"
    src="$IOS_DIR/$name"
    if [ ! -f "$src" ]; then
        echo "ORPHAN $name (in android/ but not ios/)" >&2
        drift=1
    fi
done

if [ "$drift" -ne 0 ]; then
    echo
    echo "android/core-fixtures has drifted from ios/Tests/.../Fixtures." >&2
    echo "Re-copy with: cp $IOS_DIR/*.csv $IOS_DIR/*.expected.json $ANDROID_DIR/" >&2
    exit 1
fi

echo "android/core-fixtures parity OK"
