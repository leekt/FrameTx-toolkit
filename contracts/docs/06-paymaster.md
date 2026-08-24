# 06 — Sponsoring Paymaster (Solidity)

A third party pays the gas for someone else's transaction. This is the other half of
account abstraction: example 03/04/05 show an account approving its own *execution*;
this one shows a different address approving the *payment*.

The storage-backed accounts can also take PAYMENT scope for another sender at the EVM level,
but that private-inclusion role reads policy storage outside `tx.sender`. This dedicated
paymaster keeps its validation policy in immutables, avoiding that particular public-mempool
storage-read violation (while retaining the other caveats below).

Source: [`SponsoringPaymaster.sol`](../src/accounts/SponsoringPaymaster.sol)

## What it does

The paymaster holds an ETH balance and knows one authorised **sponsor signer** key. When
its `pay` frame runs it:

1. Calls `FrameTxLib.sigScheme(sigIndex)` and requires `SECP256K1` (`0x1`).
2. Calls `FrameTxLib.sigSigner(sigIndex)` and requires the resolved signer to equal
   `sponsorSigner`.
3. Calls `FrameTxLib.signedThisTx(sigIndex)` and requires the entry to sign
   `compute_sig_hash(tx)` rather than an explicit digest.
4. Calls `FrameTxLib.maxCost()` (`TXPARAM 0x06`) and refuses to sponsor above
   `maxSponsoredCost`.
5. Calls `FrameTxLib.approve(FrameTxLib.SCOPE_PAYMENT)`, PAYMENT scope only.

**It does not run `ecrecover`.** The protocol verifies every supported native entry against
its selected message *before any frame executes*: `SECP256K1` and `P256`. A frame that
reaches `SIGPARAM` is therefore looking at metadata that is already proven. This particular
contract still requires
`SECP256K1`; it decides **whether it trusts that key and whether the selected message is the
canonical transaction hash** without repeating the cryptography.

Step 3 is the non-obvious one. `msg == 0` is the EVM-visible marker for "this signature is
over the canonical transaction signature hash". A non-zero `msg` is an explicit 32-byte
digest the sponsor signed over *something else*, which a relayer could staple onto an
unrelated transaction to get free gas. The spec reserves the zero value for exactly this
purpose ("The explicit 32-byte zero digest is invalid. This reserves the zero stack value
as the EVM-visible representation of the transaction signing hash case"), so `0` is
unambiguous.

Because the canonical sig hash covers the whole RLP of the transaction, one sponsor
signature commits to the sender, the nonce, the fee fields, and every frame — including
this paymaster's own frame and the `sigIndex` in its frame data. No per-field checks are
needed to bind the approval to this transaction.

## Frame layout

The transaction must use the public mempool's **Canonical Paymaster** prefix
(`only_verify`, `pay`), followed by the user operation:

| Frame | Subclass      | Mode    | Flags | Caller        | Target        | Value | Data                            | Purpose |
| ----- | ------------- | ------- | ----- | ------------- | ------------- | ----- | ------------------------------- | ------- |
| 0     | `only_verify` | VERIFY  | `0x2` | `ENTRY_POINT` | Null (sender) | 0     | `validate(uint256 accountSignatureIndex)` for an ordinary toolkit account; `validate(uint256[])` for multisig | Account validates its selected entry or threshold set and calls `APPROVE(APPROVE_EXECUTION)` → sets `sender_approved = true` |
| 1     | `pay`         | VERIFY  | `0x1` | `ENTRY_POINT` | **this paymaster** | 0 | `sponsorTransaction(uint256 sigIndex)` | Checks the sponsor signature, calls `APPROVE(APPROVE_PAYMENT)` → sets `payer = paymaster`, collects `max_cost` |
| 2     | `user_op`     | SENDER  | `0x0` | sender        | whatever      | any   | the user's call                 | The actual operation, `caller == tx.sender` |

`tx.signatures` must contain the entries required by the sender account and the sponsor's
entry at `sigIndex`. With separate account and sponsor keys that means at least two entries.
An ordinary account receives its one selected index through frame 0 (multisig receives its
owner-index array); this paymaster receives one selected index through frame 1. Neither
component has to assume signature zero or scan the other component's entries. The sponsor
entry is `scheme = SECP256K1`,
`signer = <sponsorSigner address>`, `msg = <empty>`, signed over `compute_sig_hash(tx)`.

Frame 1 data is a normal ABI call: selector `0x217de4d8` followed by the 32-byte
`sigIndex`. For a two-signature transaction with the account's signature at index 0, that
is `0x217de4d8` + `0x00…01`.

Both pieces of routing are authenticated. The account index (or multisig index array) and
the paymaster's `sigIndex` are frame calldata, hence part of the frame list covered by every
canonical transaction signature. All three current paymasters use the same
`sponsorTransaction(uint256)` ABI and selector `0x217de4d8`.

The algorithm-specific alternatives keep their checks exact:

- [`P256Paymaster`](09-p256-and-webauthn.md#p256paymaster) requires native `P256` scheme
  `0x02`;
- [`WebAuthnPaymaster`](09-p256-and-webauthn.md#webauthnpaymaster) requires its exact
  contract-verified `ARBITRARY` assertion profile.

None widens another paymaster's accepted algorithm merely because all three expose the same
scalar routing ABI.

### Ordering requirement — the `pay` frame MUST come after `only_verify`

This is not a style preference, it is enforced by the `APPROVE` opcode. From the spec's
`APPROVE` behavior, for `APPROVE_PAYMENT`:

> - If `payer` was already set, revert the current call frame.
> - If `resolved_target` has insufficient balance, revert the current call frame.
> - **If `sender_approved == false`, revert the current call frame.**

So a `pay` frame placed first reverts — and because a reverting VERIFY frame makes the
**whole transaction invalid**, the transaction is not merely rejected, it never becomes
includable. The sender must approve execution first; only then may someone else agree to
pay for it. The spec's recognized validation prefixes reflect this: `[only_verify, pay]`
and `[deploy, only_verify, pay]` are the only paymaster shapes the public mempool
recognizes, both with `pay` last.

The other consequence of the ordering: the paymaster commits to paying for a transaction
whose execution has *already* been authorised by the sender, so the sender cannot later
disclaim it.

## Why scope 1 and not 3

`APPROVE_EXECUTION_AND_PAYMENT` (`0x3`) reverts unless `resolved_target == tx.sender`. The
paymaster is a third party, not the sender, so scope 3 is simply illegal for it. Beyond
that, the frame's `flags` are `0x1` and `APPROVE` requires
`scope & ~(frame.flags & APPROVE_SCOPE_MASK) == 0` — asking for 3 from a flags-`0x1` frame
reverts for a second, independent reason. Scope `0x0` approves nothing and also reverts.

Note this means the contract does not need to check that the frame targets itself
(`APPROVE` reverts when `ADDRESS != resolved_target`) or that the flags allow the scope
(`APPROVE` checks that too). It does *not* check the frame's `mode`, and neither does
`APPROVE`: the approval-scope flag bits are "valid with: any mode", so a `DEFAULT`-mode
frame with `flags == 0x1` could also call this function and get payment approved. That is
harmless here — the sponsor's signature commits to the whole frame list either way, and
`APPROVE_PAYMENT` still requires `sender_approved` — and a public-mempool transaction must
use `VERIFY` mode regardless (structural rule 4). Outside a frame transaction entirely,
`TXPARAM`/`SIGPARAM`/`APPROVE` all
cause an exceptional halt, so `sponsorTransaction` is inert if someone calls it from an
ordinary transaction.

## Charging and refunds

`APPROVE(APPROVE_PAYMENT)` collects the transaction's **`max_cost` up front** from the
paymaster — the full `TXPARAM(0x06)` figure, computed at `max_fee_per_gas` with every
frame's whole gas limit consumed, plus intrinsic and signature-verification cost. If the
paymaster's balance is short at that instant, the frame reverts and the transaction is
invalid.

After all frames execute, the spec computes `payer_refund = max_cost - charged_fee` and
returns it to the payer, i.e. to this contract. So the paymaster's working capital must
cover the *worst case* of every in-flight transaction, not the expected cost. The
`maxSponsoredCost` cap is what keeps a single generous `gas_limit` from locking up the
whole balance. `receive()` exists so the balance can be topped up by a plain transfer; the
refund arrives the same way (as a protocol-level balance credit, not a call).

## Mempool caveats — read before deploying anything like this

The public mempool rules in the spec are **not implemented in this toolkit**, so a
transaction using this contract will work in a local/private setting but a real paymaster
faces constraints this example does not satisfy:

- **This is a non-canonical paymaster.** A `pay` frame is exempt from the generic
  validation trace rules only when its target's runtime code *exactly matches* the
  canonical paymaster implementation. This contract is not that code, so it is capped at
  `MAX_PENDING_TXS_USING_NON_CANONICAL_PAYMASTER = 1` pending transaction at a time in the
  public mempool. That is fine for the spec's stated use case (a personal "gas account"),
  useless for one-paymaster-to-many-users sponsorship.
- **No storage reads.** The generic rules reject a validation-prefix frame whose execution
  "reads storage outside `tx.sender`". `sponsorSigner`, `maxSponsoredCost` and `owner` are
  therefore `immutable` — they live in the runtime code, so reading them is not an `SLOAD`.
  The price is that rotating the sponsor key means redeploying. A storage-backed setter
  would be more convenient and would push the contract further out of public-mempool
  eligibility.
- **No `BALANCE`/`SELFBALANCE`, no `TIMESTAMP`.** All three are banned opcodes during the
  validation prefix, so this contract cannot check its own funding or enforce a deadline
  itself. Funding is checked by `APPROVE` (protocol-level); deadlines belong in an
  `expiry_verify` frame at index 0, which is the only place `TIMESTAMP` is permitted.
- The canonical paymaster described in the spec additionally supports timelocked
  withdrawals, so nodes can compute
  `state.balance - reserved_pending_cost - pending_withdrawal_amount`. This example's
  `withdraw` is immediate, which is exactly the behaviour those timelocks exist to prevent
  — an instant withdrawal can invalidate every pending transaction the paymaster is on.

## Frontrunning caveat (ERC-20-settled sponsorship)

This example sponsors for free — the sponsor's signature *is* the business relationship
(off-chain subscription, whitelist, etc.). The other common design is to get paid on-chain
in ERC-20, per the spec's Example 3: add a `user_op` frame that does
`transfer(sponsor, fees)` and an optional `post_op` frame that reconciles the difference.

The spec flags the hole in that design explicitly:

> Note: to be included in the public mempool under the current model, sponsors must accept
> some risk of frontrunning by the sponsee who can zero out their ERC-20 balance before the
> sponsored transaction lands on-chain.

The `pay` frame cannot read the sponsee's token balance (that is storage outside
`tx.sender`), and even if it could, the balance can change between validation and
inclusion. The sponsor pays gas in ETH at `APPROVE` time and only discovers the token
transfer failed afterwards. Mitigations (a deposit held by the paymaster, a pre-authorised
allowance pull, tight expiry) are out of scope here.

## Reusable paymaster conformance suite

`test/SponsoringPaymaster.t.sol` inherits
[`PaymasterTestSuite`](../test/PaymasterTestSuite.sol). A new paymaster test can inherit the
same suite by deploying, configuring, and funding its subject in `setUp()`, then implementing:

```solidity
function _paymasterUnderTest() internal view returns (address);
function _paymasterTestSignature()
    internal view
    returns (IFrameVm.FrameTxSignature memory);
function _paymasterTestCall(uint256 signatureIndex)
    internal view
    returns (bytes memory);
function _paymasterTestMaxCost() internal view returns (uint256);

// Optional: configure a sender allowlist or sender-specific proof fixture.
function _preparePaymasterForAccount(address account) internal;
```

The suite deliberately models a signature-authorized paymaster with exactly one selected
entry. A proof-only or allowlist-only paymaster needs a policy-specific suite instead of
pretending to supply an empty index set. The optional preparation hook defaults to a no-op.

The suite builds one shared, shifted signature envelope and requires the paymaster to sponsor
`OwnerAccount`, `MultisigAccount`, `SessionKeyAccount` through its owner path,
`P256Account`, `WebAuthnAccount`, the
migrated Kernel v3.3 proxy, and the EIP-7702-delegated EOA. It also proves that routing the
paymaster to an account's selected entry is refused. Each fixture invokes
the account's `EXECUTION` path and then the paymaster's
`PAYMENT` path with independently installed synthetic context; `sender_approved` does not
persist between those calls.

`SponsoringPaymasterTest`, `P256PaymasterTest`, and `WebAuthnPaymasterTest` all inherit this
matrix.

These are opcode-level conformance tests: they prove the correct approval path and scope,
not the eventual ETH debit or refund. Transaction-level accounting belongs in the Anvil
raw-transaction suite.

## Ambiguities and surprises in the spec

- The `SIGPARAM` / `FRAMEPARAM` spec tables list `param` in the leftmost column but the
  stack text says `signatureIndex`/`frameIndex` is on **top**. Yul builtins take
  top-of-stack first, so the calls read `sigparam(sigIndex, param)` and
  `frameparam(frameIndex, param)` — index first, the reverse of the table's column order.
  Verified against the emitted bytecode (`5f 82 b4` = `PUSH0`(param) `DUP3`(index)
  `SIGPARAM`).
- `SIGPARAM(0x00)` on an `ARBITRARY` entry is an **exceptional halt**, not a revert. The
  contract therefore checks the scheme before asking for the signer, so a `sigIndex`
  pointing at an `ARBITRARY` entry produces a clean `BadScheme` error instead of burning
  the frame's entire gas limit. This only helps for an in-range index: an out-of-range
  `sigIndex` halts exceptionally on the *first* `SIGPARAM`, because the bounds check
  precedes the `param` dispatch. The spec does not say whether the metadata reads have any
  ordering requirement; this is just defensive sequencing.
- The spec does not define what a `pay` frame should *return*. `APPROVE` follows `RETURN`
  semantics for `(offset, length)`, and nothing consumes a `pay` frame's return data, so
  this example returns empty (`approvetx(0, 0, 1)`). A `post_op` frame could in principle
  want data from it, but there is no defined channel — `FRAMEDATA*` reads a frame's *input*
  `data`, not its output.
- `P256` (`0x2`) signatures also carry a protocol-verified resolved signer. This example
  nevertheless restricts its policy to
  `SECP256K1`; use the dedicated paymaster for an exact alternative rather than silently
  widening a deployed sponsor policy. In every case, keep the `msg == 0` check — that one is
  load-bearing.

## Compiling

```bash
cd contracts
../foundry/target/debug/forge build
```

Compiles with **zero errors** (plus the standard "this is a pre-release compiler
version" notice). The current generated runtime is **878 bytes** (1756 hex characters) in
`out/SponsoringPaymaster.sol/SponsoringPaymaster.json` (`deployedBytecode`). It is built with
`cbor_metadata = false`, so the size excludes a metadata trailer.

The three `pay`-path opcodes are visible in it:

| Bytecode          | Meaning |
| ----------------- | ------- |
| `6001 80 82 b4`   | `PUSH1 0x01`(param=scheme) `DUP1` `DUP3`(sigIndex) `SIGPARAM` — index on top |
| `6006 b0`         | `PUSH1 0x06` `TXPARAM` — max cost |
| `6001 5f 5f aa`   | `PUSH1 0x01`(scope) `PUSH0`(length) `PUSH0`(offset) `APPROVE` — offset on top |

Note the immutables appear as zeroed `PUSH32` placeholders in `--bin-runtime`; they are
filled in from constructor arguments at deploy time. Selectors:

| Selector     | Function |
| ------------ | -------- |
| `0x217de4d8` | `sponsorTransaction(uint256)` |
| `0xf3fef3a3` | `withdraw(address,uint256)` |
| `0x74dd1d9c` | `sponsorSigner()` |
| `0x33198782` | `maxSponsoredCost()` |
| `0x8da5cb5b` | `owner()` |
