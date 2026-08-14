#!/usr/bin/env bash
# Compile the EIP-8141 frame-glue contracts, which Foundry cannot build.
#
# Foundry validates `evm_version` against a closed enum and rejects "@future",
# and exposes no passthrough for solc's `experimental` setting. So the contracts
# that use the frame opcodes are compiled here, directly with the patched solc,
# and their artifacts written to out-frame/.
#
# The policy layer in src/ has no frame opcodes and is built and tested by
# `forge test` as normal.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOLC="${SOLC:-$REPO_ROOT/solidity/build/solc/solc}"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/out-frame"

if [[ ! -x "$SOLC" ]]; then
    echo "patched solc not found at $SOLC" >&2
    echo "build it first -- see guides/01-build.md -- or set SOLC=/path/to/solc" >&2
    exit 1
fi

# Confirm this really is the patched compiler before trusting its output.
if ! echo 'contract T{function f() external{assembly{approvetx(0,0,3)}}}' > /tmp/.frame_probe.sol ||
   ! "$SOLC" --experimental --evm-version @future --bin /tmp/.frame_probe.sol >/dev/null 2>&1; then
    echo "$SOLC does not support the EIP-8141 opcodes (approvetx not found)." >&2
    echo "You are probably pointing at a stock solc." >&2
    rm -f /tmp/.frame_probe.sol
    exit 1
fi
rm -f /tmp/.frame_probe.sol

mkdir -p "$OUT"
shopt -s nullglob
found=0
for sol in "$(dirname "${BASH_SOURCE[0]}")/../src/accounts"/*.sol \
           "$(dirname "${BASH_SOURCE[0]}")/../src/frame"/*.sol; do
    name="$(basename "$sol" .sol)"
    echo "compiling $name"
    # --no-cbor-metadata keeps the output reproducible: the CBOR blob encodes the
    # compiler build, so without it the bytecode changes on every rebuild.
    "$SOLC" --experimental --evm-version @future --optimize --no-cbor-metadata \
            --bin --bin-runtime --abi -o "$OUT/$name" --overwrite "$sol" >/dev/null
    found=$((found + 1))
done

if [[ $found -eq 0 ]]; then
    echo "no frame contracts found under contracts/src/accounts" >&2
    exit 1
fi
echo
echo "built $found contract(s) into $OUT"
echo "runtime bytecode is in $OUT/<Name>/<Name>.bin-runtime"
