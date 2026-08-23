# 03 — Single-owner smart account (Solidity)

`OwnerAccount` is the canonical EIP-8141 starting point: one owner key in storage, no
`ecrecover`, and no `execute()` wrapper. It implements the ordinary single-index account ABI:

```solidity
function validate(uint256 signatureIndex) external;
```

The selector is `0xce4d01a3`. The VERIFY frame passes one entry in `tx.signatures` for this
account to inspect. That entry must be a protocol-validated signature by `owner` over the
canonical transaction hash.

```solidity
if (FrameTxLib.sigScheme(signatureIndex) == FrameTxLib.SCHEME_ARBITRARY) {
    revert NoTrustedSignature();
}
if (!FrameTxLib.signedThisTx(signatureIndex)) revert NoTrustedSignature();
if (FrameTxLib.sigSigner(signatureIndex) != owner) revert NoTrustedSignature();

uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
if (scope == FrameTxLib.SCOPE_NONE) revert NothingToApprove();
FrameTxLib.approve(scope);
```

The protocol verified every supported native signature before any frame ran: `SECP256K1`,
`P256`, and this toolkit's experimental ML-DSA-44 scheme `0x03`. The contract is deciding
which verified key identity it trusts and whether that key signed `compute_sig_hash(tx)`; it
is not repeating the cryptography. `ARBITRARY` entries are rejected before reading
`resolved_signer`, because that field does not exist for that scheme.

## Why the index is frame input

Several accounts and a paymaster may share one signature envelope. Passing one index in an
ordinary account's VERIFY frame routes its relevant entry without requiring the account to
scan the envelope or assume its signature is entry zero. An owner signature can be at any
envelope position, but it counts only when that position is the supplied `signatureIndex`.
A foreign selected entry or an unselected owner signature does not authorize.

This routing is not unsigned metadata. VERIFY-frame calldata is part of the frame list, and
the frame list is part of the canonical transaction signature hash. Every accepted
empty-`msg` signature therefore commits to the selected index. An out-of-range index fails
when `SIGPARAM` applies its bounds check. Multisig is the deliberate exception: its threshold
entry point receives a signed index array.

## One validator, three roles

The account reads the current frame's `allowed_scope` (`flags & 0x3`) instead of hardcoding
`BOTH`. Consequently the same deployed code supports all three approval roles:

| Role | VERIFY target | Flags / scope | Effect |
|---|---|---|---|
| Validate and pay for itself | this account, also `tx.sender` | `0x3` (`BOTH`) | Grants execution and pays `max_cost` |
| Validate with a paymaster | this account, also `tx.sender` | `0x2` (`EXECUTION`) | Grants execution; a later paymaster frame pays |
| Pay for another account | this account, different from `tx.sender` | `0x1` (`PAYMENT`) | Pays after the sender has already granted execution |

`APPROVE` enforces that the requested scope is non-zero and is a subset of the frame flags.
Execution approval additionally requires `resolved_target == tx.sender`; payment approval
does not. PAYMENT also requires `sender_approved == true`, so a third-party payer frame must
come after the sender's execution validator.

### Self-funded transaction

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x3` | account or null | `validate(ownerSigIndex)` | Authenticate, grant execution, fund gas |
| 1… | `SENDER` | operation flags | user-selected target | operation calldata | Execute with `caller == tx.sender == account` |

### Externally sponsored transaction

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x2` | account or null | `validate(ownerSigIndex)` | Authenticate and grant execution only |
| 1 | `VERIFY` | `0x1` | paymaster | paymaster-specific | Approve payment after execution is approved |
| 2… | `SENDER` | operation flags | user-selected target | operation calldata | User operation |

### Paying for another sender

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x2` | `tx.sender` account | sender-specific | Sender authenticates and grants execution |
| 1 | `VERIFY` | `0x1` | this funded account | `validate(payerOwnerSigIndex)` | Payer owner authenticates and grants payment |
| 2… | `SENDER` | operation flags | user-selected target | operation calldata | Other sender's operation |

The payer owner's canonical signature covers the other sender, fees, frames, and selected
index, so payment is limited to the exact transaction the owner signed.

This third layout is supported by the EVM and is useful with private inclusion. It is not
eligible for the public mempool with this implementation: reading `owner` performs an
`SLOAD` in an account other than `tx.sender`, while the generic public-pool validation rule
rejects storage reads outside `tx.sender`. Use a paymaster whose policy satisfies those
rules for public-pool sponsorship.

## Signature requirements

For the selected owner entry:

| Field | Requirement |
|---|---|
| `scheme` | Any supported native scheme: `SECP256K1`, `P256`, or toolkit-local `ML_DSA_44`; `ARBITRARY` is rejected |
| `signer` | resolves to the stored owner address |
| `msg` | empty, so the protocol checked `compute_sig_hash(tx)` |
| `signature` | valid for the selected scheme; protocol-checked before frame execution |

An empty `signer` resolves to `tx.sender`. For a contract account whose owner is a separate
key, the envelope should therefore carry the owner address explicitly. A non-empty 32-byte
`msg` is a valid signature over an explicit digest, but it does not commit to this frame
transaction and is deliberately ignored.

For an ML-DSA-44 owner, configure `owner` as
`low20(keccak256(0x03 || publicKey))`, not as the public key or an unrelated EOA address.
The non-normative wire, gas, audit warning, and dedicated scheme-enforcing account are
documented in [`10-pq.md`](10-pq.md).

## No `execute()` function

A `SENDER` frame is the execution mechanism. The protocol calls its target with
`caller = tx.sender`, so the account does not decode or redispatch an operation. Owner
rotation is a `SENDER` frame targeting the account's `setOwner(address)` function;
`msg.sender == address(this)` protects that self-call path.

## Read-only validation and funding

A `VERIFY` frame runs under `STATICCALL` rules. Before approval this function performs only
calldata reads, `SLOAD`, and frame/signature introspection. `APPROVE` is the sole permitted
transaction-state mutation, which is why `validate` cannot be declared `view`. A rejection
reverts the VERIFY frame and invalidates the whole transaction; there is no boolean failure
return.

The account has `receive()` because either `BOTH` or `PAYMENT` approval requires the payer
to hold the full `max_cost` when `APPROVE` executes.

## Introspection helper

`frameContext()` is a read-only demonstration, not part of validation. It reports the
canonical signature hash, current frame index, flags, mode, and signer at envelope index
zero. The validator itself does not use that hardcoded index; it consumes the index passed to
`validate(uint256)`.

## Compiling

```bash
cd contracts
../foundry/target/debug/forge build
```

The metadata-free deployed bytecode is written to
`out/OwnerAccount.sol/OwnerAccount.json`. `FrameTxLib` functions inline to `SIGPARAM`,
`TXPARAM`, `FRAMEPARAM`, and `APPROVE`; there is no linked runtime library.

Selectors:

| Selector | Function |
|---|---|
| `0xce4d01a3` | `validate(uint256)` |
| `0x8da5cb5b` | `owner()` |
| `0x13af4035` | `setOwner(address)` |
| `0xde3abbac` | `frameContext()` |

## Testing

`test/OwnerAccount.t.sol` inherits the reusable
[`AccountTestSuite`](../test/AccountTestSuite.sol). Besides owner-specific rejection cases,
the inherited matrix proves shifted selected-index routing, all three approval roles, exact
scope behavior, and the ETH-funding path. A new account test can obtain the same coverage by
implementing `accountUnderTest()` and `accountAuthorizationSignatures()`.

## Security notes

- Filtering the scheme before requesting `resolved_signer` avoids an exceptional halt on
  selected `ARBITRARY` entries. An out-of-range index still halts at the bounds check and
  makes validation fail.
- The empty-`msg` check is load-bearing. Accepting an explicit digest would let an unrelated
  owner signature authorize a frame list it never committed to.
- `APPROVE` itself checks that the executing code is the resolved frame target, so an inner
  call cannot borrow this account's approval authority.
- Scope zero is rejected explicitly; `APPROVE_NONE` cannot be used as a successful no-op.
