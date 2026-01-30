#!/bin/bash
# Run all LSP unit tests
# Usage: ./run_tests.sh

set -e

PASS_COUNT=0
FAIL_COUNT=0
TESTS="lsp_utils_test lsp_types_test simba_fs_test simba_env_test"

echo "========================================"
echo "Building and Running LSP Unit Tests"
echo "========================================"
echo

for test in $TESTS; do
    echo "Building $test..."
    if lazbuild "$test.lpi" > /dev/null 2>&1; then
        echo "Running $test..."
        echo
        if "./$test"; then
            ((PASS_COUNT++))
        else
            ((FAIL_COUNT++))
        fi
        echo
    else
        echo "  BUILD FAILED: $test"
        ((FAIL_COUNT++))
    fi
done

echo "========================================"
echo "Test Suites: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "========================================"

if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
else
    exit 0
fi
