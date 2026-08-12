# Writing EIP-8141 accounts

## The one idea to internalise

**The protocol verifies signatures before any of your code runs.**

Every `SECP256K1` and `P256` entry in the transaction envelope is checked against the
canonical signature hash before frame execution begins. If any is invalid, the transaction
is invalid and your account is never called.

So an account does not do elliptic-curve work. It asks *which key signed* and decides
whether it trusts that key:

```solidity
let signer := sigparam(0, 0x00)   // resolved_signer of signature entry 0
if eq(signer, sload(0)) { approvetx(0, 0, 3) }
```

That is the whole validation path for a single-owner account. Compare with ERC-4337, where
the account parses a signature blob and runs `ecrecover` itself. The complexity moved into
the protocol.

## The opcodes

Stack listed **top first**, matching the spec's tables and the order you write arguments in
Yul.

| Opcode | Byte | Builtin | Stack | Returns |
|---|---|---|---|---|
| `APPROVE` | `0xaa` | **`approvetx`** | offset, length, scope | — (exits the frame) |
| `TXPARAM` | `0xb0` | `txparam` | param | value |
| `FRAMEDATALOAD` | `0xb1` | `framedataload` | frameIndex, offset | word |
| `FRAMEDATACOPY` | `0xb2` | `framedatacopy` | memOffset, dataOffset, length, frameIndex | — |
| `FRAMEPARAM` | `0xb3` | `frameparam` | frameIndex, param | value |
| `SIGPARAM` | `0xb4` | `sigparam` | signatureIndex, param | value |

> **`approvetx`, not `approve`.** The spec calls the opcode `APPROVE`, but `approve` is the
> ERC-20 method name and appears in a large share of deployed Solidity. Reserving it as a
> builtin would break existing contracts, so this fork spells it `approvetx`. The opcode
> byte `0xaa` is unchanged. `approve` remains free for your own functions and variables.

### Parameter tables

`TXPARAM`: `0x00` tx type · `0x01` nonce · `0x02` sender · `0x03`–`0x05` fee fields ·
`0x06` max cost · `0x07` blob count · `0x08` **canonical signature hash** · `0x09` frame
count · `0x0A` current frame index · `0x0B` signature count.

`FRAMEPARAM`: `0x00` resolved_target · `0x01` gas_limit · `0x02` mode · `0x03` flags ·
`0x04` len(data) · `0x05` status (halts for the current or a later frame) · `0x06`
allowed_scope · `0x07` atomic_batch · `0x08` value.

`SIGPARAM`: `0x00` resolved_signer · `0x01` scheme · `0x02` msg · `0x03` len(signature) ·
`0x04` copy `ARBITRARY` signature bytes to memory.

> `SIGPARAM` param `0x04` takes **five** operands and returns none, unlike the others.
> solc's instruction model is fixed-arity and cannot express an operand-dependent stack
> effect, so it is not exposed as a builtin. Use `verbatim_5i_0o(hex"b4", sigIdx, 4,
> memOffset, dataOffset, length)` in standalone Yul.

## APPROVE scopes

| Scope | Meaning | Requires |
|---|---|---|
| `0x0` | nothing | — |
| `0x1` | PAYMENT | `sender_approved` already true; payer holds `max_cost` |
| `0x2` | EXECUTION | `resolved_target == tx.sender` |
| `0x3` | both | `resolved_target == tx.sender`; holds `max_cost` |

The requested scope must be a **subset** of the frame's `flags & 0x3`, or `APPROVE` reverts.
Setting flags to `0x3` and calling `approvetx(0, 0, 1)` is fine; the reverse is not.

## Constraints that will bite you

**A VERIFY frame is a STATICCALL.** No `SSTORE`, no `TSTORE`, no logs, no state-changing
calls. `APPROVE` is the sole exception. Any validation that wants scratch storage has to be
restructured — the multisig example works around exactly this.

**A reverting VERIFY frame invalidates the entire transaction**, not just that frame. There
is no partial success and no receipt to inspect.

**`sender_approved` is transaction-scoped, not per-frame.** Once granted, *every* subsequent
`SENDER` frame runs as `tx.sender` — not just the one the validator looked at. A validator
that approves without committing to the full frame list authorises an open-ended set of
calls. Either verify against the canonical signature hash (which covers the whole frame
list) or walk every frame yourself. The session-key example does the latter.

**A function calling `approvetx` cannot be `view`.** It changes state: it bumps the sender's
nonce, sets the payer and collects `max_cost`. Functions using only the introspection
opcodes cannot be `pure` but can be `view`.

**Frame gas limits must cover state gas.** On this geth branch a fresh storage slot costs
`64 × 1530 = 97,920` state gas. A frame doing one `SSTORE` to a new slot needs a limit
comfortably above 100,000; `100_000` fails with a bare out-of-gas that reads like a logic
error.

## Compiling

```bash
solidity/build/solc/solc --experimental --evm-version @future --bin-runtime --optimize Account.sol
```

Standalone Yul, which works on **stock** solc too via `verbatim`:

```bash
solidity/build/solc/solc --strict-assembly --bin account.yul
```

`verbatim` argument order: the **first** argument ends up on **top** of the stack, so the
argument list reads in the same order as the spec's stack table. Verified —
`verbatim_3i_0o(hex"aa", 0x11, 0x22, 0x33)` compiles to `6033 6022 6011 aa`.

> `verbatim` is **not** available inside Solidity `assembly {}` blocks on any solc, stock or
> forked — it is a Yul-dialect builtin only. That limitation is the entire reason this fork
> exists.

## Testing an account

There is no txpool or RPC, so accounts are exercised through the Go test harness. Copy the
pattern in `go-ethereum/core/eip8141_test.go`:

```go
sdb := mkState(types.GenesisAlloc{
    accountAddr: {Balance: newGwei(1_000_000_000), Code: compiledRuntime,
                  Storage: map[common.Hash]common.Hash{{}: common.BytesToHash(owner.Bytes())}},
})
tx := /* frames: selfVerifyFrame(...), senderFrame(target, gas, 0) */
res, err := applyFrameTx(t, sdb, tx)
```

`TestFrameTxYulSmartAccount` runs both a Yul-compiled and a Solidity-compiled account this
way and is the template to copy.

Two gotchas when building transactions by hand:

- **Signature byte order is `v || r || s`.** Go's `crypto.Sign` returns `r || s || v`, and
  `v` is the recovery id `0`/`1`, not `27`/`28`.
- **The canonical signature hash elides empty-`msg` signature bytes**, so for those entries
  the hash is the same before and after you fill in the signature. Entries with an explicit
  32-byte `msg` *do* commit to their bytes, so compute the hash last.

## Reproducible bytecode

The examples compile with `--no-cbor-metadata`. Without it solc appends a CBOR blob encoding
the compiler build, so the bytecode changes whenever the compiler is rebuilt — which makes
any hex string quoted in documentation go stale immediately. Stripping it makes the output
deterministic and lets the examples pin exact bytes:

```bash
solc --experimental --evm-version @future --bin-runtime --optimize --no-cbor-metadata Account.sol
```

For deployment you generally *want* the metadata; it is only omitted here so the documented
bytecode stays verifiable.
