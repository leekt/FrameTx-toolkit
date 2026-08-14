# 05 — Session-key account (Solidity, cross-frame introspection)

`SessionKeyAccount.sol` is an EIP-8141 account with two tiers of authority:

- the **owner** key may do anything;
- a registered **session key** may only drive calls on an allowlist of
  `(target, selector)` pairs, only with `value == 0`, and only until the key's
  `validUntil` timestamp.

The account never runs `ecrecover`. Every `SECP256K1`/`P256` signature in the
envelope was already verified by the protocol against `compute_sig_hash(tx)`
*before any frame executed*. The account's job is only to ask **which key
signed** — `SIGPARAM(i, 0x00)` — and decide whether it trusts that key.

The interesting part is what happens for a session key: before approving, the
VERIFY frame walks the transaction's *entire* frame list with `TXPARAM`/
`FRAMEPARAM`/`FRAMEDATALOAD` and reverts unless every `SENDER` frame is one this
key is permitted to make. This is cross-frame introspection, the capability that
has no equivalent in ERC-4337 or in a plain EOA.

## Why every frame is checked

From the spec, *Security Considerations → "Execution Approval Authorizes All
Subsequent Sender Frames"*:

> `sender_approved` is a single transaction-scoped flag. Once a frame grants
> `APPROVE_EXECUTION` […] every subsequent `SENDER` frame executes with `caller`
> set to `tx.sender`, not only the frame the approving code inspected.

There is no per-frame approval. Approving execution once authorises *all* later
`SENDER` frames. So a validator that inspects frame 1 and approves has in fact
authorised frames 2, 3, … as well. `_checkSenderFrames()` therefore loops over
`0 .. TXPARAM(0x09) - 1` and applies the policy to every `SENDER` frame, not to
some subset.

The second half of the same caveat is why `_authorize()` skips any signature
whose `msg` is non-zero (`SIGPARAM(i, 0x02) != 0`). Only an empty `msg` means
the signature was checked against `compute_sig_hash(tx)`, which commits to the
whole frame list; an explicit 32-byte digest commits to nothing about the
frames, and accepting one as authority to grant `APPROVE_EXECUTION` would let an
observer replay that approval with a different set of `SENDER` frames.

`DEFAULT` and `VERIFY` frames are deliberately ignored by the walk: they execute
with `caller == ENTRY_POINT`, not as this account, so they cannot spend its
funds or speak in its name. (A `DEFAULT` frame *targeting* this account arrives
with `msg.sender == ENTRY_POINT`, which the `onlyAdmin` modifier rejects.)

## Expiry, without reading the clock

`TIMESTAMP` is banned during validation-prefix execution (spec, *Banned opcodes*),
so the account cannot compare `block.timestamp` to a key's `validUntil` itself —
and the spec's security section explains why a naive `block.timestamp` check
would be a mempool-invalidation grief anyway. The sanctioned mechanism is the
**expiry verifier frame**: a `VERIFY` frame targeting `EXPIRY_VERIFIER`
(`address(0x8141)`) whose data is exactly an 8-byte big-endian deadline. The
protocol admits it only as frame 0 and reverts the whole transaction once
`block.timestamp > deadline`.

That turns expiry into pure introspection. When the signer is a session key,
`_checkExpiry` requires:

```solidity
if (!FrameTxLib.isExpiryFrame(0)) revert NoExpiryFrame();
uint64 deadline = FrameTxLib.expiryDeadline(0);
if (deadline > validUntil) revert ExpiryBeyondSessionKey(deadline, validUntil);
```

The protocol guarantees the transaction dies at `deadline`; the account
guarantees `deadline <= validUntil`; together, the key cannot act after it
expires. A session-key transaction with no expiry frame is refused outright —
it would otherwise be valid forever. Owner-signed transactions carry no such
requirement: the owner's authority is not time-bounded.

`sessionKeys[key]` stores the `validUntil` directly (`0` disables the key), so
registration, expiry, and revocation are one mapping.

## Frame layout

Self-relay layout — the account pays its own gas:

| # | mode         | flags               | target              | value | data                       | purpose |
|---|--------------|---------------------|---------------------|-------|----------------------------|---------|
| 0 | `VERIFY` (1) | `0x0`               | `EXPIRY_VERIFIER` (`0x8141`) | 0 | 8-byte deadline   | Protocol-enforced expiry; required by the account for session keys |
| 1 | `VERIFY` (1) | `0x3` (BOTH)        | `null` or `sender`  | 0     | `0x6901f668` (`validate()`)| Authenticate the signer, check the deadline, walk the SENDER frames, `APPROVE(0x3)` |
| 2 | `SENDER` (2) | `0x0`               | e.g. token address  | 0     | `transfer(...)`            | The restricted operation |
| 3 | `SENDER` (2) | `0x0`               | e.g. token address  | 0     | `approve(...)`             | Another one, also checked by frame 1 |

For an owner-signed transaction frame 0 may be omitted and the layout collapses
to the usual `self_verify` prefix.

Frame 0's target must be `null` or `tx.sender`: the spec's static constraints
reject `flags & APPROVE_EXECUTION` on any other target, and `APPROVE` itself
reverts when `resolved_target != tx.sender`. `null` resolves to `tx.sender`, so
either encoding works.

Sponsored layout — a paymaster pays:

| # | mode         | flags                | target             | value | data                        | purpose |
|---|--------------|----------------------|--------------------|-------|-----------------------------|---------|
| 0 | `VERIFY` (1) | `0x2` (EXECUTION)    | `null` or `sender` | 0     | `0x6901f668` (`validate()`) | Same code, `APPROVE(0x2)` |
| 1 | `VERIFY` (1) | `0x1` (PAYMENT)      | paymaster          | 0     | paymaster-specific          | `APPROVE(0x1)` — must come *after* execution approval, since `APPROVE_PAYMENT` reverts while `sender_approved == false` |
| 2 | `SENDER` (2) | `0x0`                | e.g. token address | 0     | `transfer(...)`             | The restricted operation |

The contract supports both without a flag of its own: it approves
`FRAMEPARAM(currentFrame, 0x06)`, the frame's own `flags & 0x3`, rather than
hardcoding `0x3`. Requesting a scope outside `flags & 0x3` reverts, so deriving
it from the frame is both safe and layout-agnostic; `allowed_scope == 0` is
rejected explicitly because `APPROVE_NONE` always reverts.

Signature entry (either layout):

| field       | value                                     |
|-------------|-------------------------------------------|
| `scheme`    | `0x1` (`SECP256K1`) or `0x2` (`P256`)     |
| `signer`    | the owner key or a registered session key (20 bytes; empty means `tx.sender`, which is not what you want here) |
| `msg`       | **empty** — the canonical `compute_sig_hash(tx)` |
| `signature` | `v‖r‖s` (or `r‖s‖qx‖qy` for P256)         |

## Operand order (top of stack first)

The account itself reads everything through [`FrameTxLib`](07-frametx-library.md),
which hides this; the table stays here for anyone dropping to raw assembly. The
first Yul argument is the **topmost** stack item. Verified against
`libevmasm/Instruction.cpp` in the patched solc and against
`core/vm/frame_ops.go` in the patched geth:

| builtin                          | stack, top first                                  |
|----------------------------------|---------------------------------------------------|
| `approvetx(offset, length, scope)` | `offset`, `length`, `scope`                     |
| `txparam(param)`                 | `param`                                           |
| `frameparam(frameIndex, param)`  | `frameIndex`, `param`                             |
| `sigparam(sigIndex, param)`      | `sigIndex`, `param`                               |
| `framedataload(offset, frameIndex)` | `offset`, `frameIndex`                         |

Note the inconsistency, which is easy to get backwards: `FRAMEPARAM` and
`SIGPARAM` take the **index on top**, while `FRAMEDATALOAD` takes the **offset
on top** and the frame index underneath — it is `CALLDATALOAD` with an extra
operand appended below, exactly like `FRAMEDATACOPY`
(`memOffset, dataOffset, length, frameIndex`).

The APPROVE opcode's builtin is spelled **`approvetx`**, not `approve`; the bare
name is left free for the ERC-20 method.

## Two details worth copying

**Selector extraction.** `FRAMEDATALOAD(0, i)` returns the first 32-byte word of
frame `i`'s data with the selector left-aligned in the high 4 bytes, exactly
like `calldataload(0)`. So the selector is the word's high 4 bytes:

```solidity
bytes4 selector = bytes4(FrameTxLib.frameDataLoad(i, 0));
```

Because the load zero-pads past the end of `data` (CALLDATALOAD semantics), a
frame with empty data would read as selector `0x00000000`. The code therefore
requires `FRAMEPARAM(i, 0x04) >= 4` (`len(data)`) before trusting the selector.

**Resolved target.** `FRAMEPARAM(i, 0x00)` returns the *resolved* target: when a
frame's `target` is null it resolves to `tx.sender`. That is what an allowlist
check needs — a raw null target would otherwise look like `address(0)` and slip
past a naive check while actually calling back into the account itself.

## Read-only by construction

A `VERIFY` frame executes as a `STATICCALL`; only `APPROVE` may change state.
Every step before `approvetx` here is a storage read or an introspection opcode,
so the frame is a legal `STATICCALL`:

- `validate()` cannot be `view`, because `approvetx` updates the
  transaction-scoped approval context (and, for the PAYMENT scope, increments
  the nonce and collects `max_cost`);
- the introspection wrappers are `view`, not `pure` — they read transaction
  context but touch no state.

A revert anywhere in this frame makes the **whole transaction invalid**, not
just the frame, which is what makes "revert on a disallowed frame" a real
policy and not a best-effort one.

All storage this account reads (`owner`, `sessionKeys`, `allowedCall`) lives in
`tx.sender`'s own storage, so the validation prefix also satisfies the public
mempool rule "execution reads storage outside `tx.sender`" → rejected.

## Compiling

```
/Users/taek/worksapce/solidity/build/solc/solc --experimental --evm-version @future \
    --bin-runtime --optimize --no-cbor-metadata SessionKeyAccount.sol
```

Exit code 0; the only output on stderr is the standard "pre-release compiler
version" warning. The current runtime bytecode lives in
`out-frame/SessionKeyAccount/SessionKeyAccount.bin-runtime` (1448 bytes,
`--no-cbor-metadata`). `FrameTxLib` leaves no trace in it — everything inlines —
and you can spot the introspection opcodes: `b0` (`TXPARAM`), `b1`
(`FRAMEDATALOAD`), `b3` (`FRAMEPARAM`), `b4` (`SIGPARAM`), and `aa` (`APPROVE`)
in `805f5faa` — `DUP1 PUSH0 PUSH0 APPROVE`, i.e. the scope duplicated from the
stack, then `offset = 0`, `length = 0` pushed on top of it.

Selectors:

| selector     | function                             |
|--------------|--------------------------------------|
| `0x6901f668` | `validate()`                         |
| `0x580da310` | `setSessionKey(address,uint64)`      |
| `0x2b370b67` | `setAllowedCall(address,bytes4,bool)`|
| `0x8da5cb5b` | `owner()`                            |
| `0xb7b8d604` | `sessionKeys(address)`               |
| `0xc2b418ac` | `allowedCall(address,bytes4)`        |

## Deliberately out of scope

Kept minimal on purpose; each of these is a real requirement for production, and
none is needed to show cross-frame introspection:

- no gas budget for a session key. `value == 0` on every `SENDER` frame stops a
  session key from *transferring* ETH, but in the self-relay layout frame 0 has
  flags `0x3`, so `APPROVE` still collects `max_cost` from the account and a
  session key can drain it as gas at an arbitrary `max_fee_per_gas`. Capping
  that means reading `TXPARAM(0x06)` (max cost) or `TXPARAM(0x04)`
  (`max_fee_per_gas`) in `validate()` when the signer is a session key, or
  refusing the `APPROVE_PAYMENT` bit outright and requiring a sponsor;
- no spend limit or call counter (both need `SSTORE`, which a `VERIFY` frame
  cannot do — they belong in a `SENDER` frame or in an approval-time read-only
  check against pre-written state; per-key *expiry* needs no `SSTORE` and is
  implemented above via the expiry frame);
- no argument-level policy (only `(target, selector)`; `FRAMEDATACOPY` is the
  tool for inspecting arguments);
- no ERC-1271, no batching helper, no upgrade path.

## Spec notes and ambiguities

Where the spec is silent, this example makes a choice and says so rather than
implying the spec mandates it:

1. **`FRAMEDATALOAD` operand order** is stated only in the spec's stack table
   (`top-0 = offset`, `top-1 = frameIndex`), while `FRAMEPARAM` and `SIGPARAM`
   state theirs in prose *and* put the index on top. The table is corroborated
   by the reference implementation (`opFrameDataLoad` pops `offset` first), so
   this example follows `framedataload(offset, frameIndex)`. Worth flagging
   because a reader who assumes index-first everywhere gets silently wrong data
   rather than a halt.
2. **No ordering or uniqueness rule for `signatures`.** The spec does not say a
   signature list may not contain several entries usable by the same account.
   This example scans the whole list and lets the owner win wherever it appears,
   so a transaction carrying both an owner signature and a session-key signature
   is treated as owner-authorised. A different account could reasonably require
   exactly one trusted entry; the spec permits either.
3. **Nothing binds a `VERIFY` frame to "its" account.** Any frame may call
   `validate()`; the protections are that `APPROVE` reverts unless
   `ADDRESS == resolved_target`, and that the static constraints keep
   `APPROVE_EXECUTION` frames pointed at `tx.sender`. This example relies on
   those protocol checks instead of adding its own.
4. **`SIGPARAM(i, 0x00)` on an `ARBITRARY` entry is an exceptional halt**, not a
   revert — so the scheme must be checked before the signer is read. An
   exceptional halt in a `VERIFY` frame invalidates the transaction, and unlike
   a revert it consumes the frame's whole gas allowance.
5. **`msg == 0` as "canonical signature hash"** is explicit in the spec (the
   zero digest is reserved for exactly this), so the `SIGPARAM(i, 0x02) != 0`
   filter is spec-backed, not a heuristic.
6. **`FRAMEPARAM(i, 0x05)` (`status`) is unusable here** — reading the status of
   the current or any later frame is an exceptional halt, and a validation frame
   is by definition ahead of the frames it authorises. There is no way for
   validation code to react to a later frame's outcome; the atomic-batch flag is
   the mechanism the spec offers instead.
