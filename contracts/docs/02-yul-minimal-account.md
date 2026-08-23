# 02 — Minimal Yul account (no compiler fork required)

`account.yul` is a compact EIP-8141 owner account written in standalone Yul. It uses
`verbatim_*` to emit frame opcodes, so stock solc can compile it. The parallel
`account-builtins.yul` source uses the patched compiler's named builtins.

Both variants implement the same validation contract:

- empty calldata succeeds as a receive-like ETH-funding path;
- non-empty calldata must be the canonical ABI encoding of
  `validate(uint256 signatureIndex)` (selector `0xce4d01a3`);
- that selected entry must resolve to the owner in storage slot 0 and must have signed the
  canonical transaction hash; and
- approval scope is derived from the current frame's `allowed_scope` rather than hardcoded.

There is no initializer. A factory must seed slot 0 or add constructor logic.

## Exact calldata accepted

The validation calldata is exactly 36 bytes (`0x24`):

| Offset | Size | Value |
|---|---:|---|
| `0x00` | 4 | selector `0xce4d01a3` |
| `0x04` | 32 | selected `signatureIndex` |

Trailing calldata, a short argument, or another selector reverts. Empty calldata takes a
separate `STOP` path so plain ETH transfers can fund the account.

The selected index is routing data, not authority by itself. The VERIFY frame's calldata is
part of the frame list covered by `compute_sig_hash(tx)`, so a canonical owner signature
commits to the chosen index. An out-of-range index exceptional-halts at `SIGPARAM` and the
validation fails.

## Validation logic

Conceptually, the runtime does:

```text
if calldata is empty: succeed (funding)
decode signatureIndex from validate(uint256)
signer       := SIGPARAM(signatureIndex, 0x00)
signedThisTx := SIGPARAM(signatureIndex, 0x02) == 0
frameIndex   := TXPARAM(0x0a)
scope        := FRAMEPARAM(frameIndex, 0x06)
if signer == SLOAD(0) && signedThisTx && scope != 0:
    APPROVE(0, 0, scope)
revert
```

The protocol already verified every supported native signature before the frame ran:
`SECP256K1`, `P256`, and this toolkit's non-normative ML-DSA-44 scheme `0x03`. The account
only checks the resulting signer and message selection. Zero for signature parameter `0x02`
is the reserved EVM representation of an empty `msg`, meaning the protocol verified
`compute_sig_hash(tx)` rather than an unrelated explicit digest.

This minimal example does not check the scheme before requesting `resolved_signer`.
All three native schemes can authorize if they resolve to the stored owner. For ML-DSA-44,
slot 0 must contain `low20(keccak256(0x03 || publicKey))`; the exact experimental wire is in
[`10-pq.md`](10-pq.md). Selecting an `ARBITRARY` entry exceptional-halts because that scheme
has no resolved signer, which is a fatal validation failure. The Solidity examples filter
that case explicitly for cleaner control flow.

## One runtime, three approval roles

The account reads `FRAMEPARAM(TXPARAM(0x0a), 0x06)`, which is the current frame's
`flags & 0x3`:

| Role | VERIFY target | Flags / scope | Result |
|---|---|---|---|
| Validate and pay for itself | account, also `tx.sender` | `0x3` (`BOTH`) | Grants execution and pays gas |
| Validate with a paymaster | account, also `tx.sender` | `0x2` (`EXECUTION`) | Grants execution; a later pay frame pays |
| Pay for another account | account, different from `tx.sender` | `0x1` (`PAYMENT`) | Pays after the sender grants execution |

Scope zero is rejected by the final condition. `APPROVE` enforces that the scope is a subset
of the frame flags. Execution approval requires the frame target to resolve to `tx.sender`;
payment-only approval permits a different target but requires `sender_approved` to have
already been set.

The PAYMENT-only role works in the EVM and through private inclusion. It is not eligible for
the public mempool with this implementation: validating the payer owner reads slot 0 of an
account other than `tx.sender`, violating the generic rule against validation-prefix storage
reads outside `tx.sender`.

## Portable and builtin spellings

Portable source, usable with stock solc:

```yul
let signer := verbatim_2i_1o(hex"b4", signatureIndex, 0x00)
let signedThisTx := iszero(verbatim_2i_1o(hex"b4", signatureIndex, 0x02))
let frameIndex := verbatim_1i_1o(hex"b0", 0x0a)
let scope := verbatim_2i_1o(hex"b3", frameIndex, 0x06)
if iszero(scope) { revert(0, 0) }

if and(eq(sload(0), signer), signedThisTx) {
    verbatim_3i_0o(hex"aa", 0, 0, scope)
}
```

Patched-solc source:

```yul
let signer := sigparam(signatureIndex, 0x00)
let signedThisTx := iszero(sigparam(signatureIndex, 0x02))
let scope := frameparam(txparam(0x0a), 0x06)
if iszero(scope) { revert(0, 0) }

if and(eq(sload(0), signer), signedThisTx) {
    approvetx(0, 0, scope)
}
```

The builtin is `approvetx`, not `approve`, so Solidity and Yul remain free to use the common
ERC-20 method name.

## Verbatim argument order

For `verbatim_Ni_Mo`, the first argument is on top of the EVM stack when the opcode runs.
The source argument list therefore matches the spec's top-first stack tables:

- `verbatim_2i_1o(hex"b4", signatureIndex, param)` emits `SIGPARAM` with the index on top;
- `verbatim_2i_1o(hex"b3", frameIndex, param)` emits `FRAMEPARAM` with the index on top; and
- `verbatim_3i_0o(hex"aa", offset, length, scope)` emits `APPROVE` with the offset on top.

For example, `verbatim_3i_0o(hex"aa", 0, 0, scope)` and
`approvetx(0, 0, scope)` have identical operand meaning.

`SIGDATACOPY` follows the same convention:
`sigdatacopy(memOffset, dataOffset, length, signatureIndex)`.

## Compiling

Portable version:

```bash
cd contracts/src/accounts
solc --strict-assembly --bin account.yul
```

Builtin version:

```bash
../../../solidity/build/solc/solc \
  --strict-assembly --experimental --evm-version @future --bin account-builtins.yul
```

The two runtimes need not be byte-identical. The patched compiler knows that `approvetx`
terminates the frame and can remove unreachable code; `verbatim` is opaque to the optimizer.
Measure bytecode with the exact compiler and flags used for deployment rather than relying
on a fixed size quoted in documentation.

## Testing

`test/YulAccount.t.sol` defines one `AccountTestSuite`-based test base and runs it against
both the portable-verbatim and patched-builtin runtimes. Each inherits the three role tests,
shifted selected-index routing, exact-scope checks, and empty-calldata funding coverage, in
addition to Yul-specific signer, explicit-digest, wrong-selector, malformed-length,
trailing-calldata, and out-of-range-index cases.

## Deliberate omissions

- Exactly one selected signature is supported; use `MultisigAccount` for multi-signature
  aggregation or a custom Solidity account for richer policy.
- There is no owner rotation or `execute()` function. `SENDER` frames call operation targets
  directly with `caller == tx.sender`.
- There is no explicit max-cost policy. A selected owner signature covers the fees and frame
  limits, and the requested PAYMENT scope collects the protocol-computed `max_cost`.
- Replay protection is the protocol sender nonce updated by approval, not account storage.
