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
| anvil accepting type `0x06` transactions | **Done** — decode, validate, execute; 11 integration tests |
| Atomic batches and default code in anvil | **Done** — terminator rollback, mid-batch skip, signature-index selection all pinned |
| Per-frame receipts over RPC | Not exposed yet |
| Paymaster (`pay`) frames end to end | Untested |

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

## Using anvil with frame transactions

anvil accepts type `0x06` via `eth_sendRawTransaction`. The envelope, canonical
signature hash (with empty-`msg` elision), `v‖r‖s` secp256k1 entries, frame
execution with correct callers, VERIFY-as-static, the approval context, atomic
batches and default code are all implemented and covered by
`crates/anvil/tests/it/frame_tx.rs` in the foundry submodule — 11 integration
tests that assert on resulting *state* (storage written, nonce incremented,
batches rolled back), not merely on receipts.

Anvil has no journal at the frame boundary — frames commit to the database so
later frames can observe earlier writes — so batch rollback is implemented as a
first-touch snapshot that replays prior values on failure. The rationale is
documented in `crates/anvil/src/eth/backend/frame_tx.rs`.

Still open:

| Gap | Notes |
|---|---|
| Per-frame receipts | `[status, gas_used, logs]` per frame is not exposed over RPC |
| Paymaster path | The `[only_verify, pay]` layout is untested end to end |
| Expiry verifier | The `0x8141` predeploy is not installed in anvil's genesis |
| Mempool rules | The spec's validation-prefix DoS policy is not implemented |
