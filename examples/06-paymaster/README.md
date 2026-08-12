# 06 — Sponsoring Paymaster (Solidity)

A third party pays the gas for someone else's transaction. This is the other half of
account abstraction: example 03/04/05 show an account approving its own *execution*;
this one shows a different address approving the *payment*.

Source: [`SponsoringPaymaster.sol`](./SponsoringPaymaster.sol)

## What it does

The paymaster holds an ETH balance and knows one authorised **sponsor signer** key. When
its `pay` frame runs it:

1. Reads `SIGPARAM(sigIndex, 0x01)` — the *scheme* of the designated signature entry — and
   requires `SECP256K1` (`0x1`).
2. Reads `SIGPARAM(sigIndex, 0x00)` — the *resolved signer* — and requires it to equal
   `sponsorSigner`.
3. Reads `SIGPARAM(sigIndex, 0x02)` — the *msg* — and requires it to be `0`, meaning the
   entry signs `compute_sig_hash(tx)` rather than an explicit digest.
4. Reads `TXPARAM(0x06)` — the transaction's max cost — and refuses to sponsor above
   `maxSponsoredCost`.
5. Calls `APPROVE(offset=0, length=0, scope=1)` — `approvetx(0, 0, 1)`, PAYMENT scope only.

**It does not run `ecrecover`.** The protocol verifies every `SECP256K1`/`P256` entry in
`tx.signatures` against the canonical signature hash *before any frame executes* (spec,
"Behavior": signatures are validated at step 3, frames start after). A frame that reaches
`SIGPARAM` is therefore looking at metadata that is already proven. The only decision left
to the contract is **whether it trusts that key** — which is a storage/immutable lookup and
one comparison, not a signature check.

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
| 0     | `only_verify` | VERIFY  | `0x2` | `ENTRY_POINT` | Null (sender) | 0     | account-specific                | Account validates the tx and calls `APPROVE(APPROVE_EXECUTION)` → sets `sender_approved = true` |
| 1     | `pay`         | VERIFY  | `0x1` | `ENTRY_POINT` | **this paymaster** | 0 | `sponsorTransaction(uint256 sigIndex)` | Checks the sponsor signature, calls `APPROVE(APPROVE_PAYMENT)` → sets `payer = paymaster`, collects `max_cost` |
| 2     | `user_op`     | SENDER  | `0x0` | sender        | whatever      | any   | the user's call                 | The actual operation, `caller == tx.sender` |

`tx.signatures` must contain at least two entries: the account's own (whatever frame 0
requires) and the sponsor's, at `sigIndex`. The sponsor entry is `scheme = SECP256K1`,
`signer = <sponsorSigner address>`, `msg = <empty>`, signed over `compute_sig_hash(tx)`.

Frame 1 data is a normal ABI call: selector `0x217de4d8` followed by the 32-byte
`sigIndex`. For a two-signature transaction with the account's signature at index 0, that
is `0x217de4d8` + `0x00…01`.

### Ordering requirement — the `pay` frame MUST come after `only_verify`

This is not a style preference, it is enforced by the `APPROVE` opcode. From the spec's
`APPROVE` behavior, for `APPROVE_PAYMENT`:

> - If `payer` was already set, revert the frame.
> - If `resolved_target` has insufficient balance, revert the frame.
> - **If `sender_approved == false`, revert the frame.**

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
- `P256` (`scheme = 0x2`) signatures also carry a resolved signer address and are equally
  protocol-verified, so accepting them would be sound; this example restricts to
  `SECP256K1` only to keep the trusted-key model to one line. If you widen it, keep the
  `msg == 0` check — that one is load-bearing.

## Compiling

```
/Users/taek/worksapce/solidity/build/solc/solc --experimental --evm-version @future \
    --bin-runtime --optimize --no-cbor-metadata SponsoringPaymaster.sol
```

Compiles with **zero errors** (one warning, the standard "this is a pre-release compiler
version" notice). Runtime bytecode is **977 bytes**:

```
60806040526004361061004c575f3560e01c8063217de4d814610057578063331987821461007857806374dd1d9c146100be5780638da5cb5b14610109578063f3fef3a31461013c575f5ffd5b3661005357005b5f5ffd5b348015610062575f5ffd5b50610076610071366004610317565b61015b565b005b348015610083575f5ffd5b506100ab7f000000000000000000000000000000000000000000000000000000000000000081565b6040519081526020015b60405180910390f35b3480156100c9575f5ffd5b506100f17f000000000000000000000000000000000000000000000000000000000000000081565b6040516001600160a01b0390911681526020016100b5565b348015610114575f5ffd5b506100f17f000000000000000000000000000000000000000000000000000000000000000081565b348015610147575f5ffd5b5061007661015636600461032e565b610259565b60018082b490811461018857604051630adf80b360e01b8152600481018290526024015b60405180910390fd5b5f82b4600283b46006b07f00000000000000000000000000000000000000000000000000000000000000006001600160a01b03908116908416146101ea57604051631db137d360e21b81526001600160a01b038416600482015260240161017f565b811561020957604051637737da9760e01b815260040160405180910390fd5b7f000000000000000000000000000000000000000000000000000000000000000081111561024d5760405163c8d8b5f760e01b81526004810182905260240161017f565b60015f5faa5050505050565b336001600160a01b037f000000000000000000000000000000000000000000000000000000000000000016146102a2576040516330cd747160e01b815260040160405180910390fd5b5f826001600160a01b0316826040515f6040518083038185875af1925050503d805f81146102eb576040519150601f19603f3d011682016040523d82523d5f602084013e6102f0565b606091505b505090508061031257604051631d42c86760e21b815260040160405180910390fd5b505050565b5f60208284031215610327575f5ffd5b5035919050565b5f5f6040838503121561033f575f5ffd5b82356001600160a01b0381168114610355575f5ffd5b94602093909301359350505056
```

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
