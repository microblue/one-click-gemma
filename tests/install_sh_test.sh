#!/usr/bin/env bash
# tests for linux/install.sh — covers flag parsing, --help output, and
# banner rendering. Side-effect-heavy steps (ollama install, sudo, pull)
# are validated separately via the docker smoke harness.

set -eu

SCRIPT="${SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/linux/install.sh}"
[ -x "$SCRIPT" ] || { echo "install.sh not executable at $SCRIPT"; exit 1; }

PASS=0
FAIL=0
CASES=()

# ---------------------------------------------------------------------------
# tiny test harness
# ---------------------------------------------------------------------------
pass() { PASS=$((PASS + 1)); CASES+=("PASS · $1"); }
fail() {
    FAIL=$((FAIL + 1))
    CASES+=("FAIL · $1")
    printf '\n--- FAIL: %s ---\n%s\n--- end ---\n\n' "$1" "${2:-}" >&2
}

assert_contains() {
    # $1 name, $2 needle, $3 haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *)      fail "$1" "expected to contain: $2${NEWLINE}got: $3" ;;
    esac
}

assert_eq_int() {
    # $1 name, $2 expected, $3 actual
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected $2, got $3"
    fi
}

NEWLINE='
'

# ---------------------------------------------------------------------------
# case 1: --help prints usage and exits 0
# ---------------------------------------------------------------------------
out=$("$SCRIPT" --help 2>&1 || true)
rc=$("$SCRIPT" --help >/dev/null 2>&1; echo $?)
assert_contains "help:usage-section"   "Usage:"              "$out"
assert_contains "help:flags-section"   "Flags:"              "$out"
assert_contains "help:--model-line"    "--model <tag>"       "$out"
assert_contains "help:--listen-line"   "--listen <addr>"     "$out"
assert_contains "help:--no-openclaw"   "--no-openclaw"       "$out"
assert_contains "help:--skip-pull"     "--skip-pull"         "$out"
assert_contains "help:--yes"           "--yes"               "$out"
assert_contains "help:--help"          "--help"              "$out"
# no stray shell header leaking into help
case "$out" in
    *"set -eu"*) fail "help:no-set-eu-leak" "help output contains 'set -eu' — sed range drifted" ;;
    *)           pass "help:no-set-eu-leak" ;;
esac
assert_eq_int   "help:exit-code"       "0"                   "$rc"

# -h alias
out_h=$("$SCRIPT" -h 2>&1 || true)
assert_contains "help:-h-alias-works"  "Flags:"              "$out_h"

# ---------------------------------------------------------------------------
# case 2: unknown flag exits 2 and writes to stderr
# ---------------------------------------------------------------------------
err=$("$SCRIPT" --bogus-flag 2>&1 >/dev/null || true)
rc=$("$SCRIPT" --bogus-flag >/dev/null 2>&1; echo $?)
assert_contains "unknown-flag:mentions-flag-name" "--bogus-flag" "$err"
assert_eq_int   "unknown-flag:exit-code"          "2"            "$rc"

# ---------------------------------------------------------------------------
# case 3: script syntax is valid POSIX sh
# ---------------------------------------------------------------------------
if sh -n "$SCRIPT" 2>/tmp/sh-n-err; then
    pass "posix-sh:-n-parse"
else
    fail "posix-sh:-n-parse" "$(cat /tmp/sh-n-err)"
fi

# ---------------------------------------------------------------------------
# case 4: shellcheck clean (only run if installed) — use a dedicated var so
# we don't clobber the help output captured earlier
# ---------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    if sc_out=$(shellcheck -s sh "$SCRIPT" 2>&1); then
        pass "shellcheck:clean"
    else
        fail "shellcheck:clean" "$sc_out"
    fi
else
    CASES+=("SKIP · shellcheck:clean (shellcheck not installed)")
fi

# ---------------------------------------------------------------------------
# case 5: defaults in the help body are the documented ones. Re-capture
# the help output freshly so this test doesn't depend on earlier state.
# ---------------------------------------------------------------------------
help_out=$("$SCRIPT" --help 2>&1 || true)
assert_contains "defaults:model"   "gemma4:e4b"        "$help_out"
assert_contains "defaults:listen"  "127.0.0.1:11434"   "$help_out"

# ---------------------------------------------------------------------------
# case 6: --model=value kv form is accepted by parser (stops on first error)
# we can't run to completion without sudo/network, so we inject a controlled
# failure via an unknown flag AFTER the good one and check error order
# ---------------------------------------------------------------------------
err=$("$SCRIPT" --model=custom:1b --not-a-flag 2>&1 >/dev/null || true)
assert_contains "flag-parser:still-reports-unknown" "--not-a-flag" "$err"

# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
printf '\n========= results =========\n'
for c in "${CASES[@]}"; do printf '%s\n' "$c"; done
printf '\npass=%d  fail=%d  total=%d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"

[ "$FAIL" -eq 0 ]
