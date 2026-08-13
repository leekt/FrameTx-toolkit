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
| revm executes the six opcodes | **Done** — 8 behavioural tests |
| `forge` built against the patched revm | **Done** — every revm crate resolves to the fork |
| `setFrameTx` / `clearFrameTx` cheatcodes | **Done** |
| `forge test` executing frame accounts | **Done** — 53 tests in `contracts/` |
| anvil accepting type `0x06` transactions | Not started — see [what a node still needs](#what-a-node-still-needs) |

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

## How the context reaches the EVM

The frame opcodes need a transaction context, and outside a frame transaction there is none,
so they halt. Supplying one turned out to be the whole design problem.

The first attempt put it on revm's `TxEnv` and the `Transaction` trait. Both are shared
types: adding a public field breaks every downstream struct literal, and adding a trait
method returning a reference forces lifetime bounds on every implementor. That broke
`alloy-evm` and `tempo-precompiles`, neither of which has anything to do with EIP-8141, and
would have meant forking both.

What works instead is a thread-local slot in `revm-interpreter`, installed by the cheatcode.
No shared revm type changes, so no cascade. The instructions check the host first and fall
back to the slot, so a host that models frame transactions natively — anvil, eventually —
overrides `Host::frame_context()` and ignores the slot entirely.

That kept the fork count at two.

### The cheatcodes

```solidity
struct FrameTxFrame  { uint8 mode; uint8 flags; address target; uint64 gasLimit;
                       uint256 value; bytes data; uint8 status; }
struct FrameTxSignature { uint8 scheme; address signer; bytes32 msgHash; bytes signature; }
struct FrameTx { address sender; uint64 nonce; bytes32 sigHash; uint256 maxCost;
                 uint64 frameIndex; uint64 approvableScopes;
                 FrameTxFrame[] frames; FrameTxSignature[] signatures; }

function setFrameTx(FrameTx calldata frameTx) external;
function clearFrameTx() external;
```

`approvableScopes` mirrors `frame.flags & 0x3`. `APPROVE` reverts for anything outside it,
which is the spec's subset rule, and is how a test pins the exact scope an account asked for:
set the mask to `0x1` and a correct account asking for `0x3` must fail.

> [!note] Not in published forge-std yet
> `contracts/test/FrameTest.sol` declares the `IFrameVm` interface inline against `vm`'s
> address. Regenerating Foundry's `cheatcodes.json` and bundled `Vm.sol` would remove that.

## What a node still needs

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

Each piece is independent of the others, and none of it is needed to test an account: the
`setFrameTx` cheatcode supplies the context directly, which is what `contracts/test` uses.

Porting them is substantially larger than adding the opcodes was -- the opcodes were about
600 lines, this is the rest of the EIP. When it lands, anvil should implement
`Host::frame_context()` natively; the instructions prefer the host over the tooling slot, so
no test written today will need changing.
