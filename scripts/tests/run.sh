#!/usr/bin/env bash
#
# Run every scripts/tests/test-*.sh. Exits non-zero if any test file fails.
#   scripts/tests/run.sh

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()

for test_file in "$TESTS_DIR"/test-*.sh; do
    echo "== $(basename "$test_file")"
    if ! bash "$test_file"; then
        failed+=("$(basename "$test_file")")
    fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
    printf 'FAILED: %s\n' "${failed[@]}" >&2
    exit 1
fi
echo "All script tests passed."
