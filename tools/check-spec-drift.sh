#!/usr/bin/env bash
# Check all tracked sources; pass EIP numbers to narrow the check.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check_spec_drift.py" "$@"
