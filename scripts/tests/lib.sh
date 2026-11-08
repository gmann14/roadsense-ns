# shellcheck shell=bash
#
# Minimal assertion helpers for scripts/tests/test-*.sh. Source this file.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the test files that source this
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
FAILURES=0
CURRENT_TEST=""

begin_test() {
    CURRENT_TEST="$1"
}

fail() {
    echo "  FAIL [$CURRENT_TEST]: $*" >&2
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "  ok   [$CURRENT_TEST] $*"
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$message"
    else
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (missing '$needle' in: $haystack)"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (unexpected '$needle')"
    fi
}

finish_tests() {
    if [[ "$FAILURES" -gt 0 ]]; then
        echo "$FAILURES assertion(s) failed" >&2
        exit 1
    fi
}
