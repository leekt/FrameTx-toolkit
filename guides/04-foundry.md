---
title: Foundry and revm
---

# Testing accounts with Foundry

Stock Foundry cannot touch EIP-8141: its EVM (revm) has no `0xaa`/`0xb0`–`0xb4`, and
its `evm_version` enum rejects `@future`. This toolkit forks revm to add the
opcodes and patches Foundry to use that fork.

## Status

| Capability | State |
|---|---|
| revm knows the six opcodes | **Done** — declared, implemented, table-wired, 7 behavioural tests |
| `forge` built against the patched revm | **Done** — every revm crate resolves to the fork |
| Frame context available to a test | **Not yet** — needs the cheatcode below |
| `forge test` executing a frame account | Blocked on the cheatcode |
| anvil accepting type `0x06` transactions | Not started — see [what a testnet needs](#what-a-real-testnet-still-needs) |

Today the opcodes are *known* to forge's EVM but halt, because outside a frame
transaction there is no context to report on. That halt is correct spec
behaviour; supplying a context is what the cheatcode does.

## Building

```bash
cd revm    && cargo test -p revm-interpreter -p revm-bytecode   # 49 + 45 pass
cd foundry && cargo build --bin forge --release                 # ~15 min cold
```

The built binary is `foundry/target/release/forge`.

> [!warning] Patch every revm crate together
> `foundry/Cargo.toml` patches **all twelve** revm crates to the fork, not just
> the four that changed. Patching a subset puts two versions of `revm-state` and
> `revm-primitives` in the dependency graph and their types stop unifying —
> the build fails in `reth-trie-common` with a confusing `From<&AccountInfo>`
> trait error that names neither revm nor the patch.

Confirm the patch took:

```bash
grep -A2 'name = "revm-interpreter"' foundry/Cargo.lock   # source = git+.../leekt/revm
```

## The remaining piece: a frame-tx cheatcode

`Host::frame_context()` defaults to `None`, so Foundry's host returns no context
and every frame opcode halts. The fix is to store a context where the `Host` impl
can reach it and let a cheatcode populate it.

### Where it hooks in

`Context` implements `Host` directly at `revm/crates/context/src/context.rs:437`.
The frame context is transaction-scoped, so it belongs on the transaction
environment:

1. `revm/crates/context/src/tx.rs` — add `frame_tx: Option<FrameTxContext>` to
   `TxEnv` and its builder.
2. `revm/crates/context/interface/src/transaction/mod.rs` — add
   `fn frame_tx_context(&self) -> Option<&FrameTxContext> { None }` to the
   `Transaction` trait, plus a `_mut` accessor for recording approvals.
3. `revm/crates/context/src/context.rs` — in the `Host` impl, forward
   `frame_context()` to `self.tx().frame_tx_context()` and `frame_approve()` to
   the mutable accessor.
4. `foundry/crates/cheatcodes/spec/src/vm.rs` — declare the cheatcodes.
5. `foundry/crates/cheatcodes/src/evm.rs` — implement them, writing through
   `ccx.ecx.tx_mut()`. Follow `coinbaseCall` (line 574) as the template; it is
   the same shape.

The types are already defined in `revm/crates/context/interface/src/host.rs`
(`FrameTxContext`, `FrameInfo`, `FrameSigInfo`), and `DummyHost` already carries
a `frame_tx` field showing the wiring.

### Proposed surface

```solidity
struct FrameTxFrame {
    uint8   mode;      // 0 DEFAULT, 1 VERIFY, 2 SENDER
    uint8   flags;
    address target;    // resolved target
    uint64  gasLimit;
    uint256 value;
    bytes   data;
}

struct FrameTxSignature {
    uint8   scheme;    // 0 ARBITRARY, 1 SECP256K1, 2 P256
    address signer;    // resolved signer
    bytes32 msgHash;
    bytes   signature;
}

/// Installs a frame transaction context so the frame opcodes resolve.
function setFrameTx(
    address sender,
    uint64 nonce,
    bytes32 sigHash,
    FrameTxFrame[] calldata frames,
    FrameTxSignature[] calldata signatures
) external;

/// Selects which frame is currently executing, for TXPARAM(0x0A) and the
/// FRAMEPARAM status rule.
function setFrameIndex(uint64 index) external;

/// Scopes APPROVE is permitted to grant, mirroring frame.flags & 0x3.
function setFrameApprovableScopes(uint64 scopes) external;

/// The scope APPROVE actually granted, or 0. Lets a test assert what the
/// account approved rather than only that it did not revert.
function frameApproval() external view returns (uint64);

/// Removes the context; the frame opcodes halt again.
function clearFrameTx() external;
```

A test then reads:

```solidity
function test_ownerApproves() public {
    vm.setFrameTx(sender, 0, sigHash, frames, sigs);
    vm.setFrameApprovableScopes(0x3);
    (bool ok,) = address(account).call("");
    assertTrue(ok);
    assertEq(vm.frameApproval(), 3);   // execution + payment
}
```

> [!tip] Assert the scope, not just success
> `APPROVE` reverting and `APPROVE` granting the wrong scope look identical if a
> test only checks that the call succeeded. Operand order for `APPROVE` is
> `offset, length, scope` with offset on top; getting it backwards silently
> approves the wrong thing. This exact bug appeared in `FRAMEPARAM` during
> development and only a behavioural test caught it.

## Testing today, without the cheatcode

Two things work now:

**Policy logic** — `contracts/` is a normal Foundry project covering the
authorisation logic (thresholds, duplicate signers, session-key expiry,
allowlists, selector extraction) with 14 tests including fuzz. That is where the
bugs are; it needs no frame opcodes. See [contracts/README.md](../contracts/README.md).

**Compiled artifacts** — `contracts/script/build-frame-accounts.sh` compiles the
example accounts with the patched solc. Once the cheatcode lands, `vm.etch` those
runtimes into a test and call them.

## What a real testnet still needs

Executing the opcodes is not the same as executing a frame transaction. anvil
would additionally need:

| Piece | What it involves |
|---|---|
| The `0x06` transaction type | RLP payload, canonical signature hash with elision, secp256k1 `v‖r‖s` and P256 validation |
| The frame execution loop | Mode dispatch, caller selection, `ORIGIN` override, VERIFY-as-STATICCALL |
| Approval context | `payer`, `sender_approved`, nonce increment, `max_cost` collection and settlement |
| Atomic batches | Rollback to the batch start, skip-and-refund for remaining frames |
| Default code | The empty-code account path, which is how EOAs use frame transactions |
| Gas accounting | Intrinsic, per-frame, calldata floor, refunds, payer refund |
| Frame receipts | `[status, gas_used, logs]` per frame, plus the payer |
| Expiry verifier | The `0x8141` predeploy |

All of that exists and is tested in the [go-ethereum
fork](https://github.com/leekt/go-ethereum/tree/fix/eip8141-frame-tx), which is
the only implementation that executes a whole frame transaction today. Porting it
into revm is a substantially larger job than adding the opcodes was — the
opcodes were about 600 lines; this is the rest of the EIP.

Until that lands, the geth fork remains the conformance reference: if revm and
geth disagree, geth is the one written directly against the spec text and covered
by end-to-end frame-execution tests.
