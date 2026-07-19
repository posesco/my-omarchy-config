#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_script in "${TESTS_DIR}"/*_test.sh; do
    printf 'Running %s\n' "$(basename "${test_script}")"
    "${test_script}"
done
