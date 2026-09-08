#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
FAILURES=0
PASSED=0
SKIPPED=0
TOTAL=0

run_gate() {
    local label="$1"
    shift
    TOTAL=$((TOTAL + 1))
    echo "========================================"
    echo "Gate: $label"
    echo "========================================"
    if (cd "$CORE_DIR" && "$@"); then
        echo "PASS: $label"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $label"
        FAILURES=$((FAILURES + 1))
    fi
    echo ""
}

# 1. fmt
run_gate "fmt" cargo fmt --all -- --check

# 2. clippy (all features)
run_gate "clippy (all features)" cargo clippy --all-targets --all-features -- -D warnings

# 3. clippy (no default features)
run_gate "clippy (no default features)" cargo clippy --all-targets --no-default-features -- -D warnings

# 4. test (all features)
run_gate "test (all features)" cargo test --all-targets --all-features

# 5. test (no default features)
run_gate "test (no default features)" cargo test --all-targets --no-default-features

# 6. supply chain
if cargo deny --version >/dev/null 2>&1; then
    run_gate "supply chain" cargo deny check advisories bans licenses sources
else
    TOTAL=$((TOTAL + 1))
    SKIPPED=$((SKIPPED + 1))
    echo "========================================"
    echo "Gate: supply chain"
    echo "========================================"
    echo "SKIP: supply chain (cargo-deny is not installed. Install with: cargo install cargo-deny --locked)"
    echo ""
fi

echo "========================================"
echo "Summary:"
echo "Total gates: $TOTAL"
echo "Passed:      $PASSED"
echo "Failed:      $FAILURES"
echo "Skipped:     $SKIPPED"
echo "========================================"

if [ "$FAILURES" -gt 0 ]; then
    exit 1
else
    exit 0
fi
