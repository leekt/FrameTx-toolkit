# 03 — Single-owner smart account (Solidity)

The canonical EIP-8141 account: one owner key in storage, one validation function,
no signature verification code at all.

`OwnerAccount.validate()` is what the `ENTRY_POINT` calls for the `VERIFY` frame. It does
exactly two reads and one approval, through [`FrameTxLib`](07-frametx-library.md):

```solidity
if (FrameTxLib.sigSigner(0) != owner || !FrameTxLib.signedThisTx(0)) revert();
FrameTxLib.approve(FrameTxLib.SCOPE_BOTH);      // APPROVE_EXECUTION_AND_PAYMENT
```

The library is `internal`, so this inlines to the bare opcodes — `sigparam(0, 0x00)` for
the signer, `sigparam(0, 0x02)` for the `msg` field, `approvetx(0, 0, 3)` — with no
dispatch or linking; the disassembly below shows exactly that.

The protocol verified the secp256k1 (or P256) signature against its selected message
**before frame 0 ran**. `SIGPARAM` hands the account the already-verified result. The
account's policy asks both: *do I trust that key, and was the selected message this
transaction's canonical hash?*

## Frame layout

A transaction from this account must look like this. Frame 0 is a `self_verify` frame in
mempool terms; everything after it is the user's actual operation.

| # | Mode        | Flags                                | Target                          | Value  | Data                       | Purpose |
|---|-------------|--------------------------------------|---------------------------------|--------|----------------------------|---------|
| 0 | `VERIFY` (1)| `0x3` (`APPROVE_EXECUTION_AND_PAYMENT`) | `null` (⇒ `tx.sender`) or the account address | 0 | `0x6901f668` (`validate()`) | Checks the owner signed, then `APPROVE(0x3)`: authorises later `SENDER` frames and pays `max_cost` |
| 1 | `SENDER` (2)| `0x0`                                | whatever the user is calling    | amount | the user's calldata        | Runs with `caller == tx.sender == this account` |
| … | `SENDER` (2)| `0x0` or `0x4` (atomic batch)        | …                               | …      | …                          | Any number of further operations |

Envelope fields:

- `sender` = the account address.
- `signatures` = `[[0x1 (SECP256K1), <owner address, 20 bytes>, <empty msg>, v‖r‖s]]`.

  **The `signer` field must carry the owner's address.** An empty `signer` resolves to
  `tx.sender` — which is the *account*, not the owner — and validation would reject it.
  (Empty `signer` is the EOA / default-code case, example 01, where the two are the same
  address.) Leaving `msg` empty is what makes the signature cover
  `compute_sig_hash(tx)`; `sigparam(0, 0x02)` returns 0 for that case, which is the check
  in `validate()`.

- Frame 0's `gas_limit` plus the 2800 gas signature cost must stay under `MAX_VERIFY_GAS`
  (100 000) for public-mempool propagation. `validate()` is one cold `SLOAD` plus a
  handful of 2-gas instructions, so this is not a constraint in practice.

No frame ever calls an `execute()` function on the account: in `SENDER` mode the protocol
*is* the executor, and `msg.sender` for frame 1 is the account itself. Which is also how
`setOwner` is reachable — a `SENDER` frame targeting the account, guarded by
`msg.sender == address(this)`.

## Compiling

```bash
cd contracts
../foundry/target/debug/forge build
```

Compiles with zero errors (one unavoidable warning that this is a pre-release compiler).

Runtime bytecode — **435 bytes** (`cbor_metadata = false`, so no trailing metadata; the
current bytes live in `out/OwnerAccount.sol/OwnerAccount.json` (`deployedBytecode`)).

`validate()`'s body is 60 bytes of it (`5f8054…aa`), dispatch excluded — note there is no
trace of `FrameTxLib` left, just the opcodes:

```
5f 80 54              PUSH0 DUP1 SLOAD              owner, from slot 0
6001600160a01b0316    PUSH1 1 PUSH1 1 PUSH1 a0 SHL SUB AND   the usual address mask
90 80 b4              SWAP1 DUP1 SIGPARAM           sigparam(0, 0x00) -> resolved signer
6001600160a01b0316    (mask again)
14 15 80              EQ ISZERO DUP1                signer != owner
610171 57             PUSH2 0171 JUMPI              short-circuit the || on mismatch
50 6002 5f b4         POP PUSH1 2 PUSH0 SIGPARAM    sigparam(0, 0x02) -> msg
15 15                 ISZERO ISZERO                 msg != 0
5b 15                 JUMPDEST ISZERO               either failure flag, inverted
61017a 57             PUSH2 017a JUMPI              take the approval path if ok
5f 5f fd              PUSH0 PUSH0 REVERT            …otherwise kill the transaction
5b 610184             JUMPDEST PUSH2 0184
6003 80 5f 5f aa      PUSH1 3 DUP1 PUSH0 PUSH0 APPROVE   approvetx(offset=0, length=0, scope=3)
5b 56                 unreachable; APPROVE halts the frame
```

Note the push order at the end: `scope` is pushed first because it is deepest on the
stack, `offset` last because it is on top.

Selectors: `validate()` `0x6901f668`, `owner()` `0x8da5cb5b`, `setOwner(address)`
`0x13af4035`, `frameContext()` `0xde3abbac`.

## Why `validate()` cannot be `view`

`APPROVE` changes transaction-scoped state: it sets `sender_approved`, sets `payer`,
increments the sender's nonce, and collects `max_cost` from the payer. Solidity therefore
classifies `approvetx` as state-modifying, and a `view` (or `pure`) function containing it
does not compile. That is not a quirk of the compiler — it is the point. `APPROVE` is the
*only* instruction allowed to change state from a `VERIFY` frame, because a `VERIFY` frame
executes as a `STATICCALL`: no `SSTORE`, no `LOG`, no state-changing calls, no nonce
bumping of your own. Everything else in the function is necessarily a read.

`frameContext()` is `view`: `TXPARAM`, `FRAMEPARAM`, `FRAMEDATA*` and `SIGPARAM` read
transaction context, so they cannot be `pure`, but they modify nothing.

Rejection is `revert(0, 0)`, not a boolean return code. A reverting `VERIFY` frame makes
the entire transaction invalid — it never lands on chain, and any `APPROVE` already
performed is unrolled. There is no "validation failed but the transaction still executes"
state to encode.

## The introspection surface

`frameContext()` exists purely to show what the account can see. It is not called during
validation:

| Call | Returns |
|------|---------|
| `txparam(0x08)` | the canonical signature hash — the digest every empty-`msg` signature signed |
| `txparam(0x0a)` | the index of the frame currently executing |
| `frameparam(i, 0x02)` | frame `i`'s mode (0 `DEFAULT`, 1 `VERIFY`, 2 `SENDER`) |
| `frameparam(i, 0x03)` | frame `i`'s flags; `& 0x3` is the approval scope the frame may request |
| `sigparam(0, 0x00)` | resolved signer of signature 0 |

Other things a stricter account would reach for, none of which this one needs:

- `frameparam(i, 0x00)` — frame `i`'s `resolved_target`, and `framedatacopy(memOffset,
  dataOffset, length, i)` / `framedataload(offset, i)` for its calldata. Together these
  let a `VERIFY` frame inspect exactly what it is about to authorise (a session-key or
  paymaster account does this; see examples 05 and 06). This account approves everything
  the owner signed, so it looks at nothing.
- `txparam(0x06)` — `max_cost`, i.e. what approving payment will cost at worst.
- `sigparam(i, 0x01)` — the `scheme`. Not checked here on purpose: a `P256` entry resolves
  to `keccak256(qx‖qy)[12:]`, so hitting a chosen 20-byte owner with a P256 key is as hard
  as hitting it with a secp256k1 key, and an `ARBITRARY` entry has no resolved signer at
  all (`sigparam(i, 0x00)` halts on it).

**Operand order.** Yul's first argument is the top stack item. So the stack tables in the
spec read left-to-right as the Yul argument list — with one trap:
`framedataload(offset, frameIndex)` takes `offset` first (the spec puts `offset` at
`top - 0`), while `frameparam(frameIndex, param)` and `sigparam(signatureIndex, param)`
take their index first. The index is *not* uniformly the first argument.

## Why this is so much smaller than an ERC-4337 account

A 4337 `validateUserOp` has to: hash the user operation itself, `ecrecover` a signature out
of `userOp.signature`, apply the EIP-191 prefix, handle malleability, manage its own nonce
key, and pay or delegate a deposit to the EntryPoint contract. That is 2–4 KB of runtime
code, and every byte of it is consensus-critical logic re-implemented per account.

Here the protocol does all of it before any EVM code runs:

- signature verification (secp256k1 and P256), with low-`s` canonicalisation enforced by
  the validity rules;
- binding the signature to the transaction, via the canonical signature hash;
- replay protection, via the sender's protocol nonce;
- fee collection, via `APPROVE` setting `payer` and pulling `max_cost`.

What is left for the account is a two-term boolean: *the resolved signer is my owner* and
*it signed this transaction's hash*. 435 bytes of code, most of which is ABI dispatch and
the `owner()`/`setOwner`/`frameContext()` accessors — `validate()`'s body is 60 bytes.

The corollary is that an account cannot get signature verification wrong any more. It can
still get *policy* wrong; skipping the `msg` check below is the interesting way to do that.

## Security notes

- **Why the `msg` check matters.** `sigparam(0, 0x02)` returns the signature entry's `msg`
  field. Zero means "signed `compute_sig_hash(tx)`" (the spec makes the explicit all-zero
  digest invalid precisely to reserve zero for this). A non-zero `msg` is an arbitrary
  32-byte digest the owner signed somewhere else, sometime else — an off-chain login
  challenge, a permit, a different chain. Omit this check and any such signature becomes a
  blank cheque over the account, because the envelope's `msg` field is attacker-chosen.
  The default code in the spec makes the same check (`sig.msg == Bytes()`).
- **This account cannot be made to pay for a stranger's transaction.** `APPROVE` reverts
  unless the requested scope is a subset of `frame.flags & 0x3`, and the transaction is
  statically invalid if a frame with `APPROVE_EXECUTION` set has a target other than
  `tx.sender`. `validate()` only ever requests `0x3`, so the only frame it can succeed in
  is one targeting itself as the sender. A `pay`-only frame (`flags == 0x1`) pointed at
  this account by someone else's transaction makes `approvetx(0, 0, 3)` revert, which
  invalidates that transaction rather than costing the owner anything.
- **No `ENTRY_POINT` caller check is needed.** `APPROVE` itself reverts when
  `ADDRESS != resolved_target`, so `validate()` reached through an inner `CALL` from some
  other contract cannot approve anything. An explicit `msg.sender == address(0xaa)` check
  would be redundant; it is left out deliberately so the trust argument stays visible.
- **`receive()` is required.** `APPROVE_PAYMENT` reverts if the payer's balance does not
  cover `max_cost`, so the account has to be able to hold ETH.

## Spec ambiguities encountered

1. **`FRAMEDATALOAD` operand order** is stated as `offset` at `top - 0`, `frameIndex` at
   `top - 1` (spec § `FRAMEDATALOAD`), i.e. `framedataload(offset, frameIndex)` — the
   opposite of `FRAMEPARAM`/`SIGPARAM`, which put the index on top. Some circulating
   summaries list it index-first. The revm implementation in
   `revm/crates/interpreter/src/instructions/frame_tx.rs` pops `offset` first, matching the
   local implementation spec.
   Not used by this example, but stated here because it is easy to get backwards.
2. **Exceptional halt vs. revert in a `VERIFY` frame.** The spec says "if the frame
   reverts, the transaction is invalid". It does not spell out an *exceptional halt* —
   which is what `sigparam(0, 0x00)` on an `ARBITRARY` entry, or an out-of-bounds index,
   produces. The patched revm fixture surfaces both as a failed frame call; the account tests
   rely on that fatal validation outcome. The distinction is otherwise observable only in
   gas accounting for an already-invalid transaction.
3. **`VERIFY` frame data is unconstrained.** The spec's structural rules for `self_verify`
   fix mode, flags, target, and the `APPROVE` scope, but say nothing about `frame.data`.
   The examples in the spec all show empty data. This example puts a 4-byte selector there
   so the account can keep a plain `receive()` for ETH; nothing in the spec forbids it, but
   it is worth knowing the choice is not spelled out either way. Cost: 64 gas of calldata.
4. **A `VERIFY` frame that returns without approving** is not called out as an error at the
   protocol level — the transaction simply fails later when `payer` is still unset (unless
   another frame pays). Only the mempool structural rules require `self_verify` to
   *successfully* call `APPROVE`. `validate()` reverts instead of returning quietly, which
   fails fast and is what the mempool rules expect.
