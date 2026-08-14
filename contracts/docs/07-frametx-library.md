# 07 — FrameTxLib (Solidity library)

Examples 03–06 each hand-roll the same inline assembly: `sigparam` with the operand
order remembered from the spec, `txparam` with a raw hex param, a comment explaining
both. `FrameTxLib` is that assembly written once, behind named functions, so an
account reads like the policy it implements:

```solidity
import {FrameTxLib} from "../src/frame/FrameTxLib.sol";

function validate() external {
    if (
        FrameTxLib.sigSigner(0) != owner          // who provably signed
            || !FrameTxLib.signedThisTx(0)        // and signed THIS transaction
    ) revert();
    FrameTxLib.approve(FrameTxLib.SCOPE_BOTH);    // exits the frame, like RETURN
}
```

Source: [`FrameTxLib.sol`](../src/frame/FrameTxLib.sol)

## Surface

One `internal` function per opcode/param pair, plus allocating conveniences —
everything inlines, nothing needs linking:

| Scope | Functions |
|---|---|
| Transaction (`TXPARAM`) | `txType` `txNonce` `txSender` `maxPriorityFeePerGas` `maxFeePerGas` `maxFeePerBlobGas` `maxCost` `blobCount` `sigHash` `frameCount` `currentFrameIndex` `signatureCount` |
| Frame (`FRAMEPARAM`, `FRAMEDATALOAD`, `FRAMEDATACOPY`) | `frameTarget` `frameGasLimit` `frameMode` `frameFlags` `frameDataLength` `frameStatus` `frameAllowedScope` `frameIsAtomicBatch` `frameValue` `frameDataLoad` `frameDataSlice` `frameData` |
| Signature (`SIGPARAM`) | `sigSigner` `sigScheme` `sigMsg` `signedThisTx` `sigLength` `sigDataSlice` `sigData` |
| Approval (`APPROVE`) | `approve(scope)` `approve(scope, returnData)` |

Constants for every enum the spec defines: `SCHEME_*`, `MODE_*`, `STATUS_*`, `SCOPE_*`.

`sigData`/`sigDataSlice` read an ARBITRARY entry's raw bytes through the `sigdatacopy`
builtin — the copy form of `SIGPARAM`, which stock solc cannot express (see
[guides/03-limitations.md](../../guides/03-limitations.md)).

## The halt surface is the API's sharp edge

These opcodes halt exceptionally — burning the frame's gas, not reverting — on:

- any of them outside a frame transaction,
- an out-of-bounds frame or signature index,
- `frameStatus` of the current or a later frame,
- `sigSigner` of an ARBITRARY entry (no protocol signer exists),
- `sigData*` of a protocol-verified entry (bytes stay opaque for future aggregation).

The library does not guard these — a wrapper that silently swallowed them would hide
policy bugs — it documents each on the function. Validate indexes you did not choose
yourself with `frameCount()` / `signatureCount()` first.

## Testing

`test/FrameTxLib.t.sol` runs every wrapper against the real opcodes through
`FrameTxLibHarness`, compiled by `script/build-frame-accounts.sh` and executed under
the patched revm, including the halt cases above and the zero-fill semantics of the
copy operations.
