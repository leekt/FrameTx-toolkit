#!/usr/bin/env bash
# Check whether upstream EIP-8141 has changed since this toolkit's source pin.
#
# Exit 0: no drift. Exit 1: the spec moved -- see VERSIONS.md for what to re-check.
set -euo pipefail

PINNED_COMMIT="f767a1e8078e17c9b381a91d35a09492189ede1b"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$REPO_ROOT/spec/EIP8141.md"
PINNED_URL="https://raw.githubusercontent.com/ethereum/EIPs/$PINNED_COMMIT/EIPS/eip-8141.md"
CURRENT_URL="https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-8141.md"

pinned="$(mktemp)"
current="$(mktemp)"
trap 'rm -f "$pinned" "$current"' EXIT

echo "Pinned spec commit: $PINNED_COMMIT"
echo "Local implementation overlay: $OVERLAY"
echo "Comparison: exact upstream pin vs upstream master (overlay excluded)."
echo "Fetching the exact upstream pin and current ethereum/EIPs master..."
curl -fsSL "$PINNED_URL" -o "$pinned"
curl -fsSL "$CURRENT_URL" -o "$current"

if diff -q "$pinned" "$current" >/dev/null 2>&1; then
    echo "No upstream drift since the source pin."
    if ! diff -q "$pinned" "$OVERLAY" >/dev/null 2>&1; then
        echo "The local document differs by design: upstream is preserved as the normative body, with clearly marked toolkit notes, the experimental ML-DSA-44 scheme 0x03, and a tooling appendix."
    fi
    exit 0
fi

echo
echo "SPEC HAS CHANGED since this toolkit was pinned."
echo "-----------------------------------------------------------------"
diff -u "$pinned" "$current" || true
echo "-----------------------------------------------------------------"
echo
echo "See VERSIONS.md -> 'What to re-check when the spec changes' for the"
echo "mapping from spec areas to the code that implements them."
exit 1
