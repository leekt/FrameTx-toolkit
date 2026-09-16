---
title: Foundry and revm
---

# Testing accounts with Foundry

> Current source and support status: [spec baseline](../spec/README.md) and
> [working-tree reproducibility](../VERSIONS.md#reproducibility-status).


Stock Foundry cannot touch this profile: its EVM (revm) has no `0xaa`/`0xb0`–`0xb9`,
EIP-8151's stateful
ECRecover behavior, and its `evm_version` enum rejects `@future`. This toolkit forks revm to
add the protocol behavior and patches Foundry to use that fork.

## Status

This table describes the local working tree. The published gitlinks predate the migration;
see [VERSIONS.md](../VERSIONS.md) for source pins and current verification.

| Capability | State |
|---|---|
| revm executes the seven opcodes | **Done** — covered by interpreter and account tests |
| revm/compiler execute provisional B6-B9 | **Done** — synthetic `setFrameTx` contexts only |
| `forge` built against the patched revm | **Done** — all twelve REVM crates resolve to the local checkout |
| `forge build` compiling `@future` sources natively | **Done** — refreshed foundry-core `f415f6fef0a62f44c7faa83daa8e37b14f0e009b` adds `EvmVersion::Future`; `evm_version = "@future"` plus `experimental = true` drive the patched solc over standard JSON |
| Current-spec checks | See [current verification](../VERSIONS.md#current-verification) |
| `setFrameTx` / `clearFrameTx` cheatcodes | **Done** |
| `forge test` executing frame accounts | **Done** — 295/295 tests across 15 suites, including malformed/wrong signature refusal for supported paths, real Kernel v3.3 and EIP-7702 migration fixtures, all account roles, both rollback paths, and the paymaster matrix |
| anvil accepting baseline type `0x06` transactions | **Done** — explicit opt-in; decode, validate, and execute through the integration suite |
| Post-quantum verification | Not shipped — ML-DSA must use an `ARBITRARY` witness and validation-frame/custom-verifier logic; no verifier, account, paymaster, or raw Anvil path is included |
| Atomic batches and default code in anvil | **Done** — terminator rollback, mid-batch skip, signature-index selection all pinned |
| Frame receipts and receipt trie roots | **Done** — `payer` plus ordered `frameReceipts` over RPC and canonical typed consensus encoding |
| Raw tracing and fork replay | **Done** — `trace_rawTransaction`, `trace_replayTransaction`, raw-block fetches, and transaction-hash replay |
| Canonical expiry verifier | **Done** — installed at `0x8141` after inherited source replay and restored on reset |
| EIP-8151 code-restricted ECRecover | **Done** — separate Ethereum-only opt-in with compiler mutability/formal modeling, VM gas/raw-code checks, reset, replay, overrides, and end-to-end tests |
| EIP-8250 keyed nonces | Current nested-fee envelope, nonce bookkeeping and first-use state charges; pool policy remains incomplete |
| EIP-8272 / EIP-7906 execution | Root frame encoder and assertion fixtures; canonical root verifier and raw POST_TX execution remain pending |
| EIP-8298 SETCODEFROM | Spec tracked; opcode TBD and execution pending |
| Contract `pay` frames over raw RPC | **Done** — default-code and code-bearing sponsors are covered |

## Building

Build solc before running Forge tests — `contracts/foundry.toml` points at it and forge
compiles the frame contracts natively under `evm_version = "@future"` with
`experimental = true`. The complete order is documented in [guides/01-build.md](01-build.md).

```bash
cd revm
cargo test -p revm-interpreter -p revm-bytecode

cd ../foundry
cargo build --locked --bin forge --bin anvil
```

Foundry's twelve REVM patches use the published commit recorded in
[VERSIONS.md](../VERSIONS.md). Its compiler dependency remains at foundry-core
`f415f6fef0a62f44c7faa83daa8e37b14f0e009b`.

> [!warning] Patch every revm crate together
> `foundry/Cargo.toml` patches **all twelve** revm crates to the same published commit.
> Patching a subset puts two versions of `revm-state` and
> `revm-primitives` in the dependency graph and their types stop unifying —
> the build fails in `reth-trie-common` with a confusing `From<&AccountInfo>`
> trait error that names neither revm nor the patch.

Inspect dependency-lock changes after a build:

```bash
git -C foundry diff -- Cargo.lock
```

The lockfile records the published git source for all twelve REVM crates. A locked
build must not introduce dependency changes.

## How the context reaches the EVM

The frame opcodes need a transaction context, and outside a frame transaction there is none,
so they halt. Supplying one turned out to be the whole design problem.

The first attempt put it on revm's `TxEnv` and the `Transaction` trait. Both are shared
types: adding a public field breaks every downstream struct literal, and adding a trait
method returning a reference forces lifetime bounds on every implementor. That broke
`alloy-evm` and `tempo-precompiles`, neither of which has anything to do with EIP-8141, and
would have meant forking both.

What works instead is an `Arc`-backed thread-local slot in `revm-interpreter`, installed by
the cheatcode or scoped to one Anvil frame with an RAII guard. No shared transaction type
changes, so no cascade; nested contexts are restored even on errors and unwinding. The
instructions check the host first and fall back to the slot, leaving native hosts free to
override `Host::frame_context()`.

That kept the runtime/tooling fork count at two (revm and Foundry); patched solc remains the
separate compiler component.

### The cheatcodes

```solidity
struct FrameTxFrame  { uint8 mode; uint8 flags; address target; uint64 gasLimit;
                       uint64 stateGasLimit; uint256 value; bytes data; uint8 status;
                       uint64 executionGasUsed; uint64 stateGasUsed; }
struct FrameTxSignature { uint8 scheme; address signer; bytes32 msgHash; bytes signature; }
struct FrameTxRecentRootReference { bytes32 sourceId; uint64 slot; bytes32 root; }
struct FrameTx { address sender; uint64 nonce; uint64 stateGasLeft; bytes32 sigHash;
                 uint256 maxCost; uint256 maxPriorityFeePerGas;
                 uint256 maxFeePerGas; uint256 maxFeePerBlobGas; uint64 blobCount;
                 uint64 frameIndex; FrameTxFrame[] frames; FrameTxSignature[] signatures;
                 FrameTxRecentRootReference[] recentRootReferences;
                 FrameTxTrace trace; uint64 approvableScopes; }

function setFrameTx(FrameTx calldata frameTx) external;
function clearFrameTx() external;
```

`approvableScopes` mirrors `frame.flags & 0x3`. `APPROVE` reverts for anything outside it,
which is the spec's subset rule, and is how a test pins the exact scope an account asked for:
set the mask to `0x1` and a correct account asking for `0x3` must fail.

> [!note] Not in published forge-std yet
> The fork's generated `cheatcodes.json` and bundled `Vm.sol` include these definitions,
> but published forge-std does not. `contracts/test/FrameTest.sol` therefore declares the
> `IFrameVm` interface inline against `vm`'s address.

## Using anvil with frame transactions

Frame transactions are disabled by default. Start Anvil with
`--enable-frame-transactions`, then submit the baseline type `0x06` through
`eth_sendRawTransaction`. Object-form Frame requests are rejected; this path intentionally
requires the canonical signed envelope. The envelope, canonical signature hash (with
empty-`msg` elision), native secp256k1/P256 entries, frame
execution with correct callers, VERIFY-as-static, the approval context, atomic batches, and
default code are all implemented and covered by `crates/anvil/tests/it/frame_tx.rs` in the
foundry submodule. The integration tests assert on resulting state, payment, typed receipts
and their trie root, raw traces, and fork replay rather than only transaction acceptance.

A raw test puts a codeless secp256k1 multisig owner's signature at index 1, counts it for
multisig execution, and reuses it in the later default PAYMENT frame. Its declared
verification prefix is 65,600 gas; the
test proves the owner paid while the payer EOA's own account nonce did not advance.

The opt-in is supported on Ethereum execution profiles before Amsterdam. OP Stack, Tempo,
Monad, and Amsterdam state-gas profiles reject Frame envelopes at submission. Enabled nodes
install the canonical expiry verifier runtime at `0x8141` after any inherited source
transaction replay; in-memory and fork resets restore the verifier.

Mined RPC receipts expose the paying account as `payer` and ordered nested results as
`frameReceipts`, each containing `status`, `executionGasUsed`, `stateGasUsed`, and `logs`. The same payload is encoded
as the typed consensus receipt and included in the block receipt trie. Parity
`trace_rawTransaction` and `trace_replayTransaction` execute Frame calls and return state
diffs; raw tracing does not commit them. Fork replay fetches and verifies canonical raw bytes,
including for transaction-hash forks whose source block contains type `0x06`.

The real wire path accepts scalar EIP-8141 or keyed EIP-8250 nonces, with no recent-root list or
POST_TX suffix. Keyed nonce state is implemented; canonical recent-root verification, trace
construction, and POST_TX rollback remain pending. Recent-root and POST_TX trace values are available only
as host-supplied `setFrameTx` fixture data.

Frames execute inside one persistent outer REVM journal. Later frames observe earlier writes,
multi-frame atomic batches use journal checkpoints, and the executor commits the cumulative
diff exactly once after settlement. Rejected batches, failed approvals, and exceptional
paths unwind journaled state and logs before that commit.

## Using EIP-8151 code-restricted ECRecover

Start canonical Ethereum Anvil at Prague or later with:

```bash
foundry/target/debug/anvil --hardfork prague --enable-eip8151
```

The flag is off by default, rejected on OP Stack, Tempo, Monad, and other custom execution
profiles, and preserved across `anvil_reset`. Shared Foundry EVM options also expose
`--enable-eip8151` and `enable_eip8151 = true`; the runtime still masks the feature outside
canonical Ethereum execution. Compile Solidity whose `ecrecover` mutability matters with
`--experimental --evm-version @future`, where high-level `ecrecover` is classified `view`
rather than `pure`. The compiler switch does not activate the node.

When active, precompile `0x01` first performs ordinary signature recovery. Malformed recovery
still costs `3000` and returns one zero word without loading an account. Successful recovery
loads and warms the recovered account's raw code, adding `100` gas if warm or `2600` if cold.
The call returns the recovered address only when that raw code is absent/empty or exactly
`0xef0100 || address`, including a zero target. Ordinary code, malformed or trailing
designations, and nonstandard `0xef0101` return one zero word. The implementation never follows
or warms a delegation target, and journal rollback restores warmth after a reverted frame.

The same stateful wrapper is installed for calls, transactions, gas estimation, tracing, fork
replay, Frame execution, Forge/Cast EVMs, and no-context replay. `eth_createAccessList` includes
the recovered account when the canonical wrapper actually loads it, including nested calls,
but excludes the designation target, a fully replaced custom precompile, and a successful
signature-cheat override. An unmatched cheat falls back to the canonical wrapper and therefore
does include the recovered account. No official EEST vectors or final named-fork activation
exist for this draft.

Still open:

| Gap | Notes |
|---|---|
| Contract paymaster path | Default-code and contract sponsors work over raw RPC; canonical-paymaster reservation rules remain pending |
| Mempool rules | The spec's validation-prefix DoS policy is not implemented |
| EIP-8250 activation/pool | No fork-boundary switch/eviction or keyed public-pool replacement policy |
| EIP-8272 recent roots | Current spec adds no wire fields; verifier-frame encoding is supported, but canonical `RECENT_ROOT_CODE` remains TBD upstream |
| EIP-7906 POST_TX | No suffix validation, trace construction, or execution-body rollback; gas remains provisional |
| Amsterdam state gas | Frame transactions are rejected when node-level EIP-2780/EIP-8037 state-gas rules are active; the per-frame `limits.state` pools here meter only EIP-8141's own charge points |
| EIP-8151 activation/vectors | No named-fork activation or official EEST vectors exist; the toolkit uses explicit Prague-or-later opt-in |
| Networking | No public gossip policy or blob-sidecar wrapper for type `0x06` |
