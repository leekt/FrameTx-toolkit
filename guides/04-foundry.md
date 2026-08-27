---
title: Foundry and revm
---

# Testing accounts with Foundry

Stock Foundry cannot touch this profile: its EVM (revm) has no `0xaa`/`0xb0`–`0xb9`,
EIP-7819 `0xf6`, the toolkit's provisional EIP-7851 `0xf7`, or EIP-8151's stateful
ECRecover behavior, and its `evm_version` enum rejects `@future`. This toolkit forks revm to
add the protocol behavior and patches Foundry to use that fork.

## Status

This table describes behavior exercised in the reproducible current-spec stack recorded in
[VERSIONS.md](../VERSIONS.md). The four toolchain forks publish it on their default branches:
[Solidity](../solidity/) `develop` at `4c6c547d9a35b23807f421692ac65c35f26f3d54`,
[revm](../revm/) `main` at `21ace0ade666d99f3e1c6e95ba173972164d0ceb`,
[foundry-core](../foundry-core/) `main` at
`f415f6fef0a62f44c7faa83daa8e37b14f0e009b`, and [Foundry](../foundry/) `master` at
`5683db7dc79cace93363fe3465e20792b859bec9`. The root gitlinks pin those exact commits and
the Soldeer lock pins official Kernel v3.3 at
`cd697c7e21715d015e0643af22310a99aa17433b`, so a fresh recursive clone plus
`forge soldeer install` reproduces the toolchain and migration fixture.

| Capability | State |
|---|---|
| revm executes the seven opcodes | **Done** — covered by interpreter and account tests |
| revm/compiler execute provisional B6-B9 | **Done** — synthetic `setFrameTx` contexts only |
| `forge` built against the patched revm | **Done** — Foundry `5683db7dc79cace93363fe3465e20792b859bec9` resolves every revm crate to primary head `21ace0ade666d99f3e1c6e95ba173972164d0ceb` |
| `forge build` compiling `@future` sources natively | **Done** — refreshed foundry-core `f415f6fef0a62f44c7faa83daa8e37b14f0e009b` adds `EvmVersion::Future`; `evm_version = "@future"` plus `experimental = true` drive the patched solc over standard JSON |
| Current-spec Foundry promotion | **Done** — 27/27 primitives, 44/44 Anvil unit, and 30/30 Anvil integration tests pass |
| `setFrameTx` / `clearFrameTx` cheatcodes | **Done** |
| `forge test` executing frame accounts | **Done** — 304/304 tests across 17 suites, including malformed/wrong signature refusal for supported paths, real Kernel v3.3 and EIP-7702 migration fixtures, all account roles, both rollback paths, and the paymaster matrix |
| anvil accepting baseline type `0x06` transactions | **Done** — explicit opt-in; decode, validate, and execute through the integration suite |
| Post-quantum verification | Not shipped — ML-DSA must use an `ARBITRARY` witness and validation-frame/custom-verifier logic; no verifier, account, paymaster, or raw Anvil path is included |
| Atomic batches and default code in anvil | **Done** — terminator rollback, mid-batch skip, signature-index selection all pinned |
| Frame receipts and receipt trie roots | **Done** — `payer` plus ordered `frameReceipts` over RPC and canonical typed consensus encoding |
| Raw tracing and fork replay | **Done** — `trace_rawTransaction`, `trace_replayTransaction`, raw-block fetches, and transaction-hash replay |
| Canonical expiry verifier | **Done** — installed at `0x8141` after inherited source replay and restored on reset |
| EIP-7819 `SETDELEGATE` | **Done** — separate explicit Anvil opt-in with compiler, VM, reset, and four end-to-end activation/semantics tests |
| EIP-7851 code-controlled delegation | **Done** — separate Ethereum-only opt-in with compiler, VM, sender/auth validation, reset, and ten end-to-end tests; opcode `0xf7` is explicitly non-normative |
| EIP-8151 code-restricted ECRecover | **Done** — separate Ethereum-only opt-in with compiler mutability/formal modeling, VM gas/raw-code checks, reset, replay, overrides, and eight end-to-end tests |
| EIP-8250/8272/7906 wire integration | Not implemented — fixture/context support is not transaction support |
| Contract `pay` frames over raw RPC | Untested — default-code sponsor payment is covered |

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

Foundry's twelve manifest patches and lockfile resolve to the current REVM commit pinned by
the root repository's `revm` gitlink. Foundry commit
`5683db7dc79cace93363fe3465e20792b859bec9` resolves them to revm
`21ace0ade666d99f3e1c6e95ba173972164d0ceb` and foundry-core
`f415f6fef0a62f44c7faa83daa8e37b14f0e009b`. Both dependency revisions are pushed and the
locked graph resolves from a clean recursive clone.

> [!warning] Patch every revm crate together
> `foundry/Cargo.toml` patches **all twelve** revm crates to the same immutable fork revision.
> Patching a subset puts two versions of `revm-state` and
> `revm-primitives` in the dependency graph and their types stop unifying —
> the build fails in `reth-trie-common` with a confusing `From<&AccountInfo>`
> trait error that names neither revm nor the patch.

Confirm the dependency lock is unchanged after a build:

```bash
git -C foundry diff -- Cargo.lock
```

An empty diff confirms the locked immutable dependency set was preserved.

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

The real wire path has the pinned scalar nonce and no keyed-nonce list, recent-root list, or
POST_TX suffix. It does not implement keyed state, recent-root verification, trace
construction, or POST_TX rollback. Recent-root and POST_TX trace values are available only
as host-supplied `setFrameTx` fixture data.

Frames execute inside one persistent outer REVM journal. Later frames observe earlier writes,
multi-frame atomic batches use journal checkpoints, and the executor commits the cumulative
diff exactly once after settlement. Rejected batches, failed approvals, and exceptional
paths unwind journaled state and logs before that commit.

## Using EIP-7819 `SETDELEGATE`

EIP-7819 is independent of the Frame transaction profile. Compile inline assembly or Yul with
patched solc's `--experimental --evm-version @future`, then start the patched node with:

```bash
foundry/target/debug/anvil --hardfork prague --enable-eip7819
```

`--enable-eip7819` is off by default and requires Prague-or-later execution rules because the
delegation indicator reuses EIP-7702 behavior. The setting survives `anvil_reset`. The Yul
builtin is `location := setdelegate(salt, target)`: it installs exact code
`0xef0100 || low160(target)` at
`keccak256(0xef0100 || address(this) || bytes32(salt))[12:]`, or clears that code for a zero
target. The implementation preserves balance/storage/nonzero nonce, sets nonce `0` to `1`,
warms only the derived location, applies the existing-account refund, rejects ordinary-code
collisions and static mode, and makes a new delegation callable by the next opcode.

The integration tests in `foundry/crates/anvil/tests/it/anvil.rs` cover default and pre-Prague
rejection, installation/update/refund/clearing, reset preservation, collision/static behavior,
and same-execution delegation. This activation is experimental and does not claim that EIP-7819
has a final named-fork assignment.

## Using EIP-7851 code-controlled delegation

Compile `success := setselfdelegate(target)` with patched solc's
`--experimental --evm-version @future`, then start Anvil with:

```bash
foundry/target/debug/anvil --hardfork prague --enable-eip7851
```

The flag is off by default, requires Prague-or-later rules, and is limited to Anvil's canonical
Ethereum execution profile. Exact code `0xef0101 || address` delegates calls like EIP-7702's
`0xef0100 || address`, but disables protocol ECDSA authority. `SETSELFDELEGATE` updates only the
current execution-context authority, costs `9500`, preserves its nonce, and can move an exact
version-0 or version-1 designation only to version 1. Zero targets and ordinary raw code return
failure without mutation; static execution halts and ordinary journal reverts undo updates.

Signed Ethereum envelopes from a version-1 authority and EIP-7702 authorization tuples signed
by it are rejected or skipped. Object-form simulation, impersonation, and Frame transactions
remain usable because they have non-ECDSA authentication; EIP-7851 delegation resolution stays
active in those calls. EIP-7819 cannot overwrite a version-1 designation. The setting survives
`anvil_reset`.

The pinned EIP still declares its opcode TBD. This toolkit uses local `0xf7` because EIP-7819
already occupies `0xf6`; compiler, VM, and tests label the allocation non-normative. Bytecode
using it must be regenerated when upstream assigns the canonical opcode.

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
designations, and EIP-7851's `0xef0101` return one zero word. The implementation never follows
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
| Contract paymaster path | A default-code sponsor works over raw RPC; the contract `pay` layout and canonical-paymaster reservation rules are not covered end to end |
| Mempool rules | The spec's validation-prefix DoS policy is not implemented |
| EIP-8250 keyed nonces | No wire fields, nonce-manager state, first-use charge, or keyed pool identity |
| EIP-8272 recent roots | No wire fields, pre-execution verification, or system contract; `RECENT_ROOT_CODE` remains TBD upstream |
| EIP-7906 POST_TX | No suffix validation, trace construction, or execution-body rollback; gas remains provisional |
| Amsterdam state gas | Frame transactions are rejected when node-level EIP-2780/EIP-8037 state-gas rules are active; the per-frame `limits.state` pools here meter only EIP-8141's own charge points |
| EIP-7851 opcode assignment | Upstream remains TBD; the current pinned stack consistently uses non-normative `0xf7` |
| EIP-8151 activation/vectors | No named-fork activation or official EEST vectors exist; the toolkit uses explicit Prague-or-later opt-in |
| Networking | No public gossip policy or blob-sidecar wrapper for type `0x06` |
