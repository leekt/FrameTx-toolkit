#!/usr/bin/env bash
# Check whether EIP-8141 has changed since this toolkit was pinned.
#
# Exit 0: no drift. Exit 1: the spec moved -- see VERSIONS.md for what to re-check.
set -euo pipefail

PINNED_COMMIT="064f49621d05ce25323def867a6a2ed9275d3570"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDORED="$REPO_ROOT/spec/EIP8141.md"
UPSTREAM_URL="https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-8141.md"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Pinned spec commit: $PINNED_COMMIT"
echo "Fetching current EIPS/eip-8141.md from ethereum/EIPs master..."
curl -fsSL "$UPSTREAM_URL" -o "$tmp"

if diff -q "$VENDORED" "$tmp" >/dev/null 2>&1; then
    echo "No drift: the vendored spec matches upstream master."
    exit 0
fi

echo
echo "SPEC HAS CHANGED since this toolkit was pinned."
echo "-----------------------------------------------------------------"
diff -u "$VENDORED" "$tmp" || true
echo "-----------------------------------------------------------------"
echo
echo "See VERSIONS.md -> 'What to re-check when the spec changes' for the"
echo "mapping from spec areas to the code that implements them."
exit 1
