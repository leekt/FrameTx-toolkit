# 04 — k-of-n multisig account (Solidity)

`MultisigAccount` is a k-of-n EIP-8141 account with no `ecrecover`, packed signature blob,
or `execute()` dispatcher. It implements the multisig-specific `IMultisigFrameAccount`
entry point:

```solidity
function validate(uint256[] calldata signatureIndices) external;
```

The selector is `0x25b90494`. Each element selects an entry in `tx.signatures` for this
multisig to consider. The contract does not scan unselected envelope entries. This is the
only toolkit account that uses an index array; ordinary accounts implement
`validate(uint256)` with selector `0xce4d01a3`.

## What it does

Before any frame runs, the protocol validates every supported native entry against its
selected message: `SECP256K1`, `P256`, and this toolkit's experimental ML-DSA-44 scheme
`0x03`. The account then applies policy to the selected indices:

1. Require one of those three native schemes; `ARBITRARY` and unknown schemes are skipped.
2. Require an empty `msg`, which means the signer authorized `compute_sig_hash(tx)` and
   therefore this complete frame transaction.
3. Require `resolved_signer` to be a stored owner.
4. Require each counted owner to be strictly greater than the previously counted owner.
5. After at least `threshold` distinct owners count, approve the current frame's
   `allowed_scope`.

Reading the scheme before the signer matters. `ARBITRARY` entries do not have a
`resolved_signer`, and asking for one exceptional-halts. Skipping a selected foreign entry
keeps mixed authentication schemes composable, while omitting foreign and paymaster entries
from `signatureIndices` avoids inspecting them at all.

The common address policy is intentional. A P256 owner is stored as
`low20(keccak256(qx || qy))`; an ML-DSA-44 owner is stored as
`low20(keccak256(0x03 || publicKey))`. A threshold may mix those identities with ordinary
secp256k1 owners without putting raw key or signature bytes in contract calldata. The exact
toolkit-local post-quantum profile is in [`10-pq.md`](10-pq.md).

The empty-`msg` check is equally important. A protocol-valid signature over an explicit
digest does not commit to this sender, nonce, fees, frame list, or index routing and must not
count toward the threshold.

## Selected-index routing

The transaction builder chooses the entries for this account by ABI-encoding their indices
in the VERIFY frame. An owner signature may be anywhere in the envelope. Only selected
entries count, so an unselected owner signature cannot accidentally satisfy the threshold.

The array is signed routing, not an unsigned hint: VERIFY-frame calldata is part of the
canonical transaction hash. Reordering or replacing the selected indices changes the hash
and invalidates every canonical owner signature. Out-of-range selected indices fail the
`SIGPARAM` bounds check.

## Dedup without scratch storage

A VERIFY frame is a `STATICCALL`; it cannot use storage or transient storage as a "seen"
set. This implementation instead requires the *counted selected signers* to appear in
strictly ascending address order:

```solidity
require(signer > prevSigner, "owner sigs not sorted");
prevSigner = signer;
```

Because the loop follows `signatureIndices`, the required order is the order of those
indices, not necessarily the physical order of every entry in the envelope. Non-owners and
other skipped entries do not update `prevSigner`. A builder can therefore leave a shared
signature envelope in any convenient order and pass an owner-index array ordered by owner
address.

Other viable designs include a memory bitmap keyed by stable owner numbers or an O(k²)
memory dedup scan. The sorted-selection rule keeps this example small and requires no extra
owner-index storage.

## One validator, three roles

After reaching threshold, the account approves
`FRAMEPARAM(TXPARAM(0x0A), 0x06)`—the current frame's `flags & 0x3`—rather than a hardcoded
scope.

| Role | VERIFY target | Flags / scope | Result |
|---|---|---|---|
| Validate and pay for itself | multisig, also `tx.sender` | `0x3` (`BOTH`) | Grants execution and pays `max_cost` |
| Validate with a paymaster | multisig, also `tx.sender` | `0x2` (`EXECUTION`) | Grants execution; a later pay frame pays |
| Pay for another account | multisig, different from `tx.sender` | `0x1` (`PAYMENT`) | Pays after the sender grants execution |

Scope zero cannot approve anything and fails. `APPROVE` also enforces that the scope is a
subset of the frame flags, that execution approval targets `tx.sender`, and that payment
approval follows an existing execution approval.

### Self-funded layout

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x3` | multisig or null | `validate([ownerSigA, ownerSigB, ...])` | Reach threshold, approve execution and payment |
| 1… | `SENDER` | operation flags | owner-selected target | operation calldata | Execute the signed batch |

### Externally sponsored layout

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x2` | multisig or null | `validate([ownerSigA, ownerSigB, ...])` | Reach threshold, approve execution only |
| 1 | `VERIFY` | `0x1` | paymaster | paymaster-specific | Approve payment |
| 2… | `SENDER` | operation flags | owner-selected target | operation calldata | Execute the signed batch |

### Paying for another sender

The other sender first approves execution. A later flags-`0x1` VERIFY frame targets this
funded multisig and calls the same `validate(...)`; threshold owners thereby approve this
multisig as payer for the exact signed transaction.

This is valid EVM behavior and can be privately included. It is not public-mempool eligible
with this storage-backed implementation: reading `isOwner` and `threshold` while
`tx.sender` is a different account violates the generic rule against validation-prefix
storage reads outside `tx.sender`. Public-pool sponsorship needs a paymaster policy that
satisfies those rules.

#### Reusing a secp256k1 owner as the default payer

A codeless secp256k1 owner can count toward this account's execution threshold and pay for
the transaction with one signature entry. Put that owner's empty-`msg` `SECP256K1` entry at
index `1`, with an explicit signer equal to the codeless owner. Include `1` in this
multisig's selected array, respecting ascending signer-address order, then place a later
PAYMENT-only VERIFY frame against that signer. Empty-code default validation hard-selects
index `1` for PAYMENT and reuses the same canonical `v || r || s` bytes; no second signature
is required.

An ML-DSA-44 owner may count toward this multisig, but cannot replace that default payer
entry. The protocol's empty-code account remains secp256k1-only, so a post-quantum payer
needs compatible account code or delegation. See
[`01-eoa-default-code.md`](01-eoa-default-code.md#reusing-index-1-with-a-multisig-owner).

## Where did `execute()` go?

A `SENDER` frame is the execution. The protocol calls each target with
`caller = tx.sender`, and the canonical owner signatures cover the complete frame list.
There is no account-side operation decoder or batch dispatcher.

Compared with ERC-4337, the protocol supplies structured signature entries, performs the
native cryptographic verification, binds signatures to the transaction, manages the sender nonce,
and handles payer collection through `APPROVE`. The contract is left with the wallet policy:
which selected verified signers are owners, are they distinct, and do enough of them agree?

## Storage and funding

| Slot | Contents |
|---|---|
| 0 | `mapping(address => bool) isOwner`—owner flag at `keccak256(abi.encode(owner, 0))` |
| 1 | `uint256 threshold` |

`receive()` provides a normal funding path because this account can approve `BOTH` or
`PAYMENT`. At approval time the payer must hold the full `max_cost`.

## Compiling

```bash
cd contracts
../foundry/target/debug/forge build
```

The metadata-free deployed bytecode is written to
`out/MultisigAccount.sol/MultisigAccount.json`. `FrameTxLib` is internal and inlines into
the runtime.

Selectors:

| Selector | Function |
|---|---|
| `0x25b90494` | `validate(uint256[])` |
| `0x2f54bf6e` | `isOwner(address)` |
| `0x42cde4e8` | `threshold()` |

## Verification coverage

`test/MultisigAccount.t.sol` inherits
[`AccountTestSuite`](../test/AccountTestSuite.sol) and executes the account against the real
frame opcodes in patched revm. The inherited matrix covers shifted routing, all three
approval roles, exact scopes, and funding. Multisig-specific cases cover threshold
boundaries, sorted deduplication, selected versus unselected entries, foreign and arbitrary
entries, explicit digests, and mixed secp256k1/P256/ML-DSA-44 scheme filtering. Raw-RPC
frame-transaction behavior is tested separately in Anvil. One raw regression executes the
production ML-DSA account path, and another proves that signature index 1 can count toward
this multisig and be reused by its codeless secp256k1 owner as payer.

## Points worth carrying into production

- The length of `signatureIndices` is bounded by validation gas, not by a Solidity-level
  cap. Add a policy limit if predictable cost matters.
- Duplicate indices cannot count the same owner twice because the second signer is not
  strictly greater than the first.
- Only the three explicitly supported native schemes count. `ARBITRARY` entries and any
  future native scheme remain skipped until the policy is deliberately updated.
- Two ML-DSA-44 signatures consume the current 100,000-gas public validation limit before
  this loop runs. A hybrid ML-DSA-44 plus secp256k1 threshold leaves at most 47,200 gas for
  validation-frame execution; see [`10-pq.md`](10-pq.md#gas-and-transaction-size).
- The contract relies on `APPROVE`'s target and scope checks rather than a separate
  EntryPoint caller check.
