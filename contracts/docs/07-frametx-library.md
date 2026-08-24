# 07 — FrameTxLib (Solidity library)

The frame builtins take raw hex params in a spec-defined operand order that is easy
to get backwards (see the table in [05](05-session-key-account.md)). `FrameTxLib` is
that assembly written once, behind named functions, so an account reads like the
policy it implements — the Solidity examples are all written against it, and the raw
opcodes remain inside this library's own bodies:

```solidity
import {FrameTxLib} from "../src/frame/FrameTxLib.sol";

function validate(uint256 signatureIndex) external {
    if (!FrameTxLib.signedThisTx(signatureIndex)) revert();
    if (FrameTxLib.sigSigner(signatureIndex) != owner) revert();

    uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
    if (scope == FrameTxLib.SCOPE_NONE) revert();
    FrameTxLib.approve(scope); // exits the frame, like RETURN
}
```

Source: [`FrameTxLib.sol`](../src/frame/FrameTxLib.sol)

## Surface

One `internal` function per opcode/param pair, plus allocating conveniences — everything
inlines, nothing needs linking. Rows explicitly labeled "fixture" are host-supplied,
non-normative tooling data; the other rows wrap the pinned upstream EIP-8141
surface or helpers built from it:

| Scope | Functions |
|---|---|
| Normative transaction (`TXPARAM 0x00`-`0x0C`) | `txType` `txNonce` `txSender` `maxPriorityFeePerGas` `maxFeePerGas` `maxFeePerBlobGas` `maxCost` `blobCount` `sigHash` `frameCount` `currentFrameIndex` `signatureCount` `stateGasLeft` |
| Frame (`FRAMEPARAM`, `FRAMEDATALOAD`, `FRAMEDATACOPY`) | `frameTarget` `frameGasLimit` `frameStateGasLimit` `frameMode` `frameFlags` `frameDataLength` `frameStatus` `frameExecutionGasUsed` `frameStateGasUsed` `frameAllowedScope` `frameIsAtomicBatch` `frameValue` `frameDataLoad` `frameDataSlice` `frameData` |
| Expiry | `isExpiryFrame` `expiryDeadline` — recognise the expiry verifier frame and read its 8-byte deadline (see [05](05-session-key-account.md), "Expiry, without reading the clock") |
| Signature (`SIGPARAM`, `SIGDATACOPY`) | `sigSigner` `sigScheme` `sigMsg` `signedThisTx` `sigLength` `sigDataSlice` `sigData` |
| Fixture recent roots (`RECENTROOTREFLOAD`) | `recentRootSourceId` `recentRootSlot` `recentRoot` |
| Fixture POST_TX trace (`TXTRACE`) | `traceBalanceDiffCount` `traceStorageDiffCount` `traceDeploymentCount` `traceBalanceAccount` `traceBalanceBefore` `traceBalanceAfter` `traceStorageAccount` `traceStorageKey` `traceStorageBefore` `traceStorageAfter` `traceDeployedAccount` `traceDeployedCodeHash` `traceEventCount` `traceEventEmitter` `traceEventTopicCount` `traceEventTopic0` `traceEventTopic1` `traceEventTopic2` `traceEventTopic3` `traceEventDataLength` `traceGasPreCharge` `traceGasPayer` |
| Fixture direct POST_TX diff (`TXDIFF`) | `storageValueBefore` `storageValueAfter` `accountBalanceBefore` `accountBalanceAfter` `accountCodeHashBefore` `accountCodeHashAfter` `accountStorageDiffCount` `accountStorageDiffIndex` `accountEventCount` `accountEventIndex` `accountDiffFlags` |
| Fixture POST_TX event data (`EVENTDATACOPY`) | `eventDataSlice` `eventData` |
| Approval (`APPROVE`) | `approve(scope)` `approve(scope, returnData)` |

Constants cover `SCHEME_ARBITRARY`, `SCHEME_SECP256K1`, and `SCHEME_P256`, modes 0-2,
`STATUS_*`, and `SCOPE_*`, plus the non-normative fixture `MODE_POST_TX` and the
`EXPIRY_VERIFIER` predeploy address. EIP-8141 reserves scheme values `0x03` through `0xff`;
the library deliberately defines no constants for them.

`TXPARAM(0x01)` is the scalar EIP-8141 wire nonce. Recent roots, `MODE_POST_TX`, and all
trace/diff/event values are copied from the host fixture; neither the library nor the
cheatcode derives or verifies them. `sigHash`, by contrast, remains the canonical EIP-8141
signature hash, although a synthetic fixture must supply its value.

`sigData`/`sigDataSlice` read an ARBITRARY entry's raw bytes through native `SIGDATACOPY`
(`0xb5`). Native secp256k1 and P256 bytes are inaccessible.

`approve(scope, returnData)` passes the byte array's payload directly to `APPROVE`. Because
`APPROVE` terminates like `RETURN`, a low-level caller receives exactly those raw bytes, not
an ABI-encoded dynamic-`bytes` envelope. `test_approveWithReturnData` pins both successful
approval and byte-for-byte return data.

`accountStorageDiffIndex` and `accountEventIndex` translate an account-local index to the
corresponding global `TXTRACE` index. `accountDiffFlags` returns bit 0 nonce, bit 1 balance,
bit 2 storage and bit 3 code-hash changes. Direct storage, balance, and code-hash selectors
access live host state on both fixture-diff hits and misses. Their provisional 100 gas is the
warm total; only the applicable EIP-2929 cold premium is added for a cold access. On a miss,
the live value is returned for both views.

`eventDataSlice` is intentionally stricter than frame and signature copies: the entire
source range must exist. It exceptional-halts rather than zero-filling an overrun.

## The halt surface is the API's sharp edge

These opcodes halt exceptionally — burning the frame's gas, not reverting — on:

- any of them without an active frame context,
- an out-of-bounds frame or signature index,
- an out-of-bounds recent-root reference,
- `frameStatus` of the current or a later frame,
- `sigSigner` of an ARBITRARY entry (no protocol signer exists),
- `sigData*` of a protocol-verified entry (bytes stay opaque for future aggregation),
- every `TXTRACE`, `TXDIFF` and `EVENTDATACOPY` wrapper outside the current
  `MODE_POST_TX` frame,
- an out-of-bounds global trace index, account-local index or requested event topic,
- `eventDataSlice` when `dataOffset + length` exceeds the event data length.

The library does not guard these — a wrapper that silently swallowed them would hide
policy bugs — it documents each on the function. Validate indices you did not choose
yourself with the corresponding count wrapper first.

## Testing

`test/FrameTxLib.t.sol` runs every wrapper's positive path against the real opcodes through
`FrameTxLibHarness`, compiled natively by the patched forge and executed under patched
revm. The cheatcode copies its non-normative fixture fields without deriving or validating
them. Targeted negative tests cover out-of-range recent-root, frame, signature, global
trace, account-local event/storage, event, and topic indexes;
current-frame status; protocol-signature/ARBITRARY misuse; non-POST_TX mode; strict event-data
bounds; and a representative `TXPARAM` call with no frame context. The suite does not claim
to run every wrapper under every invalid context.
