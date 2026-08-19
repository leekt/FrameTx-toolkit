# 05 — Session-key account (Solidity, cross-frame introspection)

`SessionKeyAccount` has two tiers of authority:

- the owner may authorize any frame transaction; and
- a registered session key may authorize only zero-value `SENDER` calls on an allowlist of
  `(target, selector)` pairs, with an expiry no later than the key's `validUntil`.

The account never runs `ecrecover`. The protocol validates every `SECP256K1` and `P256`
entry before frame execution. The account inspects signer metadata, requires the canonical
transaction-hash case, and applies its owner or session policy.

## Shared validation ABI and signature routing

The contract implements:

```solidity
function validate(uint256[] calldata signatureIndices) external;
```

Its selector is `0x25b90494`. `_authorize` examines only the entries named by
`signatureIndices`; it does not scan the full signature envelope. This lets an account and
paymaster share one transaction without relying on fixed envelope positions.

Among selected canonical signatures, the owner wins wherever it appears. Otherwise the
registered session signer with the greatest non-zero `validUntil` supplies the restricted
authority. An unselected owner signature does not upgrade a selected session-key
transaction, and an empty selection authorizes nothing.

The index array is itself authenticated. VERIFY-frame calldata is included in the frame
list covered by `compute_sig_hash(tx)`, so changing the selected entries invalidates the
canonical signatures. Each selected entry still needs policy checks:

- filter `ARBITRARY` before requesting `resolved_signer`;
- require `msg == 0`, the EVM marker for the canonical transaction hash; and
- require the resolved signer to be the owner or a registered session key.

An out-of-range selected index fails the `SIGPARAM` bounds check. An explicit-digest
signature may be protocol-valid, but it does not commit to this transaction and is ignored.

## Why every SENDER frame is checked

Signature selection is narrow, but execution inspection must be complete.
`sender_approved` is one transaction-scoped flag: once execution is approved, every later
`SENDER` frame runs with `caller = tx.sender`. There is no per-operation approval.

For a session key, `_checkSenderFrames()` therefore walks the entire frame list and applies
the allowlist to every `SENDER` frame. Each must:

- have `value == 0`;
- have at least four bytes of data; and
- resolve to an allowed `(target, selector)` pair.

`DEFAULT` and `VERIFY` frames are ignored by this call-policy walk because they do not run
as `tx.sender`. The canonical session signature commits to the complete frame list, so a
relayer cannot replace a checked operation after validation routing was signed.

`FRAMEDATALOAD(0, i)` behaves like `CALLDATALOAD`: the selector is left-aligned in the high
four bytes and short input is zero-padded. Checking `FRAMEPARAM(i, 0x04) >= 4` first prevents
empty calldata from masquerading as selector `0x00000000`. `FRAMEPARAM(i, 0x00)` returns the
resolved target, so a null target is correctly treated as `tx.sender`, not address zero.

## Expiry without reading the clock

`TIMESTAMP` is banned in the validation prefix. A session-key transaction instead begins
with the protocol's expiry verifier at `address(0x8141)`, carrying an eight-byte big-endian
deadline. The protocol admits that frame only at index zero and rejects the transaction once
the deadline passes.

The account requires:

```solidity
if (!FrameTxLib.isExpiryFrame(0)) revert NoExpiryFrame();
uint64 deadline = FrameTxLib.expiryDeadline(0);
if (deadline > validUntil) revert ExpiryBeyondSessionKey(deadline, validUntil);
```

The protocol guarantees the transaction is dead after `deadline`; the account guarantees
`deadline <= validUntil`. Owner-authorized transactions do not need an expiry frame because
the owner authority is not time-bounded.

## One validator, three roles

After authentication and any session restrictions, `validate` reads the current frame's
`allowed_scope` and rejects zero. It does not hardcode `BOTH`.

| Role | VERIFY target | Flags / scope | Result |
|---|---|---|---|
| Validate and pay for itself | session account, also `tx.sender` | `0x3` (`BOTH`) | Grants execution and pays `max_cost` |
| Validate with a paymaster | session account, also `tx.sender` | `0x2` (`EXECUTION`) | Grants execution; a later pay frame pays |
| Pay for another account | session account, different from `tx.sender` | `0x1` (`PAYMENT`) | Pays after that sender grants execution |

`APPROVE` enforces the target and scope rules. A PAYMENT-only frame is legal for a target
different from `tx.sender`, but it must follow the sender's successful execution approval.

If a session key authorizes the payer role, the same expiry and allowlist policy applies to
the other sender's `SENDER` frames. An owner-selected payer signature bypasses those session
restrictions, just as it does when this account is the sender.

The payer role is valid EVM behavior and can be used through private inclusion. This
storage-backed implementation is not eligible for the public mempool when it pays for a
different sender: its reads of `owner`, `sessionKeys`, and `allowedCall` are outside
`tx.sender`, which violates the generic validation-prefix storage rule. Use a public-pool
compatible paymaster for public sponsorship.

## Frame layouts

### Session key, self-funded

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x0` | expiry verifier (`0x8141`) | 8-byte deadline | Protocol-enforced time bound |
| 1 | `VERIFY` | `0x3` | account or null | `validate([sessionSigIndex])` | Authenticate, enforce policy, approve execution and payment |
| 2… | `SENDER` | operation flags | allowlisted target | allowlisted calldata | Restricted operations |

For an owner-authorized self-funded transaction, omit the expiry frame and place the
flags-`0x3` account validator at index zero.

### Session key, externally sponsored

| # | Mode | Flags | Target | Data | Purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` | `0x0` | expiry verifier | 8-byte deadline | Required time bound |
| 1 | `VERIFY` | `0x2` | account or null | `validate([sessionSigIndex])` | Authenticate, enforce policy, approve execution |
| 2 | `VERIFY` | `0x1` | paymaster | paymaster-specific | Approve payment |
| 3… | `SENDER` | operation flags | allowlisted target | allowlisted calldata | Restricted operations |

For an owner-authorized sponsored transaction, omit the expiry frame and renumber the
remaining frames. The paymaster must remain after execution approval.

### Paying for another sender

The other account first validates with scope `EXECUTION`. A following flags-`0x1` frame
targets this funded session account and calls `validate([payerSigIndex, ...])`. If a selected
session key supplies payer authority, place the expiry verifier first and ensure every later
`SENDER` operation satisfies this account's session policy.

## Read-only validation

A VERIFY frame runs under `STATICCALL` rules. Authentication, expiry checks, allowlist
checks, and frame introspection are reads. `APPROVE` is the one transaction-state mutation
allowed from verification, so `validate` cannot be marked `view`. A revert invalidates the
whole transaction rather than returning a soft failure.

All storage reads are on `tx.sender` in the normal self-funded and externally sponsored
layouts, satisfying that part of the public-mempool policy. The cross-account payer layout
is the exception described above.

## Admin calls and self execution

`setSessionKey` and `setAllowedCall` accept either a direct call from `owner` or a call from
the account itself. The latter is how an owner-authorized `SENDER` frame targeting the
account changes policy. A session-key frame also arrives with
`msg.sender == address(this)`, so do not allowlist either admin selector unless delegating
policy administration is intentional.

`receive()` provides a funding path for `BOTH` and `PAYMENT` roles. The payer must hold the
full `max_cost` when approval occurs.

## Operand order

`FrameTxLib` wraps the raw opcodes. In Yul, their relevant argument order is:

| Builtin | Arguments / stack top first |
|---|---|
| `approvetx(offset, length, scope)` | `offset`, `length`, `scope` |
| `txparam(param)` | `param` |
| `frameparam(frameIndex, param)` | `frameIndex`, `param` |
| `sigparam(signatureIndex, param)` | `signatureIndex`, `param` |
| `framedataload(offset, frameIndex)` | `offset`, `frameIndex` |

The inconsistency worth remembering is that `FRAMEPARAM` and `SIGPARAM` put the index on
top, while `FRAMEDATALOAD` puts the data offset on top.

## Compiling

```bash
cd contracts
../foundry/target/debug/forge build
```

The metadata-free deployed bytecode is written to
`out/SessionKeyAccount.sol/SessionKeyAccount.json`. `FrameTxLib` is internal and inlines into
the runtime.

Selectors:

| Selector | Function |
|---|---|
| `0x25b90494` | `validate(uint256[])` |
| `0x580da310` | `setSessionKey(address,uint64)` |
| `0x2b370b67` | `setAllowedCall(address,bytes4,bool)` |
| `0x8da5cb5b` | `owner()` |
| `0xb7b8d604` | `sessionKeys(address)` |
| `0xc2b418ac` | `allowedCall(address,bytes4)` |

## Testing

`test/SessionKeyAccount.t.sol` inherits
[`AccountTestSuite`](../test/AccountTestSuite.sol). Its inherited owner-authorized matrix
proves shifted routing, self-payment, external sponsorship, payment for another sender,
exact scopes, and funding. The concrete tests add session-key allowlist, expiry, multi-frame,
selected-owner precedence, and explicit-digest coverage.

## Deliberately out of scope

- A session key has no gas budget. In the self-funded layout it can spend the account's ETH
  as gas even though every `SENDER` frame has zero value. A production account should cap
  `TXPARAM(0x06)` or require external sponsorship for session keys.
- There is no spend limit or call counter. State changes belong in a `SENDER` frame because
  VERIFY cannot write storage.
- The allowlist is selector-level, not argument-level. Use `FRAMEDATACOPY` to enforce
  argument policy.
- There is no ERC-1271 support, upgrade path, or batching helper; `SENDER` frames already
  provide transaction-level batching.
