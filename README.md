# FrameTx Toolkit

Everything needed to write and run [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141) frame transaction contracts:
a patched **revm/Foundry** that executes them, a patched **solc** that compiles them, and
worked smart accounts with tests.

EIP-8141 is a **draft**. The upstream spec base and each current submodule gitlink are
recorded at exact commits in [VERSIONS.md](VERSIONS.md).

> [!note] Reproducible current stack
> The EIP-8141 stack is published on each fork's default branch: Solidity `develop` at
> `4c6c547d9a35b23807f421692ac65c35f26f3d54`, revm `main` at
> `3c82639a34a104af73d9aea0e9b50b005caace81`, foundry-core `main` at
> `f415f6fef0a62f44c7faa83daa8e37b14f0e009b`, and Foundry `master` at
> `6cfbfd4e76cb275e1974caebfbf3b88d13c70c37`. The real Kernel v3.3 migration fixture uses
> official ZeroDev Kernel commit `cd697c7e21715d015e0643af22310a99aa17433b`. Foundry
> promotion passed 30/30 primitives, 44/44 Anvil unit, and 31/31 Anvil integration tests;
> the contract project passes 324/324 tests across 19 suites. The root gitlinks pin these
> exact published commits, so a fresh recursive clone reproduces the stack. To inspect later
> primary-branch movement without changing those pins, use
> [the fetch-only submodule sync command](.claude/commands/sync-submodules.md).

## Getting started

Nothing gets installed: the patched solc and forge/anvil are built inside the submodules
and invoked by path, so your existing `forge` (`~/.foundry/bin`) and any system solc stay
untouched.

**1. Get the current stack** (the gitlinks pin its exact revm/foundry commits; stale
binaries built from other submodule states will fail):

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
cd FrameTx-toolkit
# or, updating an existing clone:
git pull && git submodule update --init --recursive
```

**2. Build the two patched tools** (once, then incremental). In the current stack,
Foundry's manifest pins the revm fork (all twelve crates) and the foundry-core fork
(compilers with the `@future` EVM version) at exact commits, so cargo fetches the right
sources automatically — you never build them separately unless you are hacking on them:

```bash
# patched solc  ->  solidity/build/solc/solc
cmake -S solidity -B solidity/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build solidity/build --target solc -j 8

# patched forge + anvil  ->  foundry/target/debug/{forge,anvil}
cargo build --manifest-path foundry/Cargo.toml --locked --bin forge --bin anvil
```

**3. Build and test — plain forge:**

```bash
cd contracts
../foundry/target/debug/forge test --allow-local-compiler  # trusts the pinned local solc
```

The project's default profile sets `evm_version = "@future"`, `experimental = true`, and
`solc = "../solidity/build/solc/solc"`, so the patched forge compiles `src/accounts`,
`src/frame`, and `src/eips` natively and rebuilds them like any other source. Tests etch
the resulting runtimes (`vm.getDeployedCode`) and drive them through the patched revm via
the `setFrameTx` cheatcode. In this toolkit, `@future` executes as **Osaka**, the last
pre-Amsterdam Ethereum profile. That activates the [EIP-7951 P256VERIFY
precompile](https://eips.ethereum.org/EIPS/eip-7951) at `0x100`, which the WebAuthn
validators need, without enabling Amsterdam's incompatible node-level state-gas rules.
The patched FrameTx host also enables this toolkit's explicitly non-normative native
ML-DSA-44 scheme `0x03`; no EVM precompile or named-fork activation is implied.

For real signed type-`0x06` envelopes, receipts, and state gas, run the patched node:

```bash
foundry/target/debug/anvil --enable-frame-transactions   # plus --enable-eip7819 / --enable-eip7851 / --enable-eip8151 as needed
```

That command is sufficient for the existing frame-transaction examples. To execute a
WebAuthn validator, start Anvil with `--hardfork osaka` as well so precompile `0x100` is
active. The repository does not yet claim a raw-transaction WebAuthn end-to-end test.

**Coexisting with stock Foundry and solc:**

- Stock `forge` still runs the policy layer through the `policy` profile:
  `FOUNDRY_PROFILE=policy forge test --match-path test/FrameAccountPolicy.t.sol`.
  Everything else — `@future` compilation, `setFrameTx`, the frame opcodes — needs the
  patched binaries.
- Don't `foundryup` or `cargo install` the fork — invoking by path is the design. If the
  path gets old: `alias fforge=$PWD/foundry/target/debug/forge` (and `fanvil` likewise).
- The patched forge runs any normal Foundry project unchanged. To use frame opcodes in
  another project, replicate the pattern here: compile the opcode-bearing contracts
  externally with `solidity/build/solc/solc --experimental --evm-version @future`, etch
  the runtime in tests, and declare the `IFrameVm` interface field-for-field (copy
  [`contracts/test/FrameTest.sol`](contracts/test/FrameTest.sol)).
- Sanity checks: [guides/01-build.md](guides/01-build.md) has a probe contract confirming
  you're on the right solc (stock solc lacks `approvetx`; an older fork lacks
  `setdelegate`/`setselfdelegate`).
  [`tools/check-spec-drift.sh`](tools/check-spec-drift.sh) tells you if upstream EIP-8141
  moved off the pin.

Prerequisites and the full build order live in [guides/01-build.md](guides/01-build.md).

## EIP roadmap

| EIP | Change | Target fork | Inclusion status | Toolkit support |
|---|---|---|---|---|
| [EIP-7997](https://forkcast.org/eips/7997) | Deterministic factory contract | [Glamsterdam](https://forkcast.org/upgrade/glamsterdam) | Scheduled (SFI) | Exact factory address/runtime already available in Anvil, plus the `Create2FactoryLib` Solidity helper; fork-gated activation and nonce `1` are not modeled |
| [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141) | Frame transactions | [Bogota milestone](https://github.com/ethereum/execution-specs/milestone/29) | Draft; [implementation tracker #2829](https://github.com/ethereum/execution-specs/issues/2829) open | Compiler, VM, and opt-in Anvil raw-RPC path aligned and tested against the pinned current master, including receipts, traces, and fork replay |
| [EIP-7906](https://forkcast.org/eips/7906) | Transaction assertions via state-diff opcode | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied EVM fixture only; wire and trace construction not implemented |
| [EIP-8250](https://forkcast.org/eips/8250) | Keyed nonces for frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied context only; wire and state integration not implemented |
| [EIP-8272](https://forkcast.org/eips/8272) | Recent roots for frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied context only; wire and root verification not implemented |
| [EIP-7819](https://forkcast.org/eips/7819) | `SETDELEGATE` instruction | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler, REVM, and explicit Anvil opt-in implemented with gas, collision, refund, clearing, nonce, and immediate-effect coverage |
| [EIP-7851](https://forkcast.org/eips/7851) | Code-controlled EOA delegation | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler, REVM, and Ethereum-only Anvil opt-in implemented; upstream leaves the opcode TBD, so the toolkit explicitly uses non-normative `0xf7` |
| [EIP-8151](https://forkcast.org/eips/8151) | Account-code-restricted `ecRecover` | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler mutability/formal modeling, REVM, and Ethereum-only Foundry/Anvil opt-in implemented with raw-code, gas, warmth, replay, and access-list coverage |

EIP-8141's Draft status and open Bogota target are sourced from the official EIP and
[`execution-specs` tracker](https://github.com/ethereum/execution-specs/issues/2829) as of
2026-08-23; the remaining roadmap rows retain their Forkcast 2026-08-16 snapshot. The local
[implementation document](spec/EIP8141.md) has a normative body matching pinned official
master `f767a1e8078e17c9b381a91d35a09492189ede1b`, including the merged native
`SIGDATACOPY` instruction, plus an explicitly non-normative ML-DSA-44 profile at
upstream-reserved scheme `0x03`, and a clearly non-normative appendix for the context-only
EIP-8250/8272/7906 tooling fixture. The
local ML-DSA allocation is experimental and not portable to upstream clients; the appendix
does not define transaction-wire semantics for those fixture extensions.

A fresh recursive clone checks out the exact current compiler, VM, and tooling commits. See
[Building the toolkit](guides/01-build.md) for the required build order and reproducibility
details.

## What EIP-8141 changes

A frame transaction (type `0x06`) decomposes a transaction into a sequence of **frames** —
contract calls that validate the transaction, approve gas payment, and execute the user's
operations. Validity and gas payment become programmable.

The consequence that matters for contract authors: **the protocol verifies native signatures
before your code runs.** Every upstream `SECP256K1`/`P256` entry, and every toolkit-local
ML-DSA-44 (`0x03`) entry, is checked against either the canonical transaction hash (empty
`msg`) or its explicit digest before frame execution begins. A native-signature account does
not repeat the cryptography; it asks which key identity signed, requires the canonical-hash
case when authorizing frames, and applies policy. An
`ARBITRARY` entry is different: the protocol checks its structure but leaves its witness for
contract code to inspect with `SIGDATACOPY`. The WebAuthn examples use that path and call
P256VERIFY themselves because an authenticator signs WebAuthn data, not the raw transaction
hash. Ordinary accounts use `validate(uint256 signatureIndex)` (selector `0xce4d01a3`), so
their VERIFY frame routes exactly one entry from `tx.signatures`. `MultisigAccount` alone
uses `validate(uint256[] signatureIndices)` (selector `0x25b90494`) because threshold policy
must aggregate several entries. Canonical signatures commit to either form of routing
because the VERIFY frame's calldata is part of the transaction hash. The core of a
single-owner validator is:

```solidity
function validate(uint256 signatureIndex) external {
    if (FrameTxLib.sigScheme(signatureIndex) == FrameTxLib.SCHEME_ARBITRARY) revert();
    if (!FrameTxLib.signedThisTx(signatureIndex)) revert();
    if (FrameTxLib.sigSigner(signatureIndex) != owner) revert();

    uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
    if (scope == FrameTxLib.SCOPE_NONE) revert();
    FrameTxLib.approve(scope);
}
```

Deriving the current frame's allowed scope lets the same account validate and pay for
itself (`BOTH`), validate while a paymaster supplies ETH (`EXECUTION`), or pay for another
already-approved sender (`PAYMENT`). The standalone Yul account implements the same
single-index ABI and treats empty calldata as its ETH-funding path. Every current paymaster
likewise receives one routing index through `sponsorTransaction(uint256)` (selector
`0x217de4d8`).

The ML-DSA profile is pure FIPS 204 ML-DSA-44 with an empty context over that existing
32-byte message. Its native field is exactly `2,420-byte signature || 1,312-byte public key`,
and its signer identity is `low20(keccak256(0x03 || publicKey))`. Upstream reserves `0x03`;
the local verifier, 50,000-gas placeholder, audit warning, and dedicated contracts are in
[`contracts/docs/10-pq.md`](contracts/docs/10-pq.md).

Empty-code default accounts remain secp256k1-only. A secp256k1 multisig owner can place its
canonical entry at index 1, let the multisig count that entry for execution, and let a later
default-code PAYMENT frame against the same codeless owner reuse it—one envelope entry and
no second signature. An ML-DSA owner cannot use that default payer path without compatible
account code or delegation.

## Contents

| Path | What |
|---|---|
| [`solidity/`](solidity/) | Submodule — compiles the EIP-8141 opcode surface plus non-normative fixture opcodes |
| [`revm/`](revm/) | Submodule — executes the EIP-8141 opcode surface plus host-supplied fixture context |
| [`foundry-core/`](foundry-core/) | Submodule — teaches Foundry's compiler layer the experimental `@future` EVM target |
| [`foundry/`](foundry/) | Submodule — `forge` with the frame cheatcodes and opt-in Anvil transaction path |
| [`contracts/vendor/kernel-v3.3/`](contracts/vendor/kernel-v3.3/) | Official ZeroDev Kernel v3.3 fixture submodule, pinned for real factory/proxy/ERC-4337 migration tests |
| [`spec/EIP8141.md`](spec/EIP8141.md) | Current-master normative overlay, the local non-normative ML-DSA-44 scheme, and a non-normative tooling-fixture appendix |
| [`contracts/`](contracts/) | The Foundry project: accounts in `src/accounts`, policy in `src/policy`, EIP helper libraries in `src/eips`, **all tests** in `test/` |
| [`guides/`](guides/) | Build, write, and what does not work yet |
| [`tools/check-spec-drift.sh`](tools/check-spec-drift.sh) | Detect whether the spec moved |

## Implementing and testing

There are three useful testing levels. Start with ordinary policy tests, move to the patched
Forge harness for real opcode execution, and use Anvil when transaction encoding, mining,
receipts, or replay matter.

### Policy-only tests

Code under `contracts/src/policy` contains no frame opcodes and works with stock Foundry. This
is the fastest loop for threshold, duplicate-signer, expiry, allowlist, and selector logic:

```bash
cd contracts
forge test --match-path test/FrameAccountPolicy.t.sol
```

This does not execute frame opcodes or model a frame transaction.

### Patched Forge harness

This is the recommended account-development loop. It executes the real opcodes in patched
REVM while the custom `setFrameTx` cheatcode supplies synthetic transaction context. It tests
account validation and approval behavior, but not type-`0x06` wire encoding, pool admission,
nonce transitions, or eventual ETH charging and refunds. Native P256 fixtures supply
already-verified scheme/signer/message metadata and therefore do not cryptographically verify
the envelope signature; native ML-DSA contract fixtures have the same boundary. WebAuthn
fixtures do construct a real assertion and execute
P256VERIFY, although their canonical transaction challenge still comes from synthetic
`setFrameTx` context.

Build patched solc and Forge once. The first Foundry build compiles a large Rust dependency
graph; later builds are incremental.

```bash
# From the repository root
cmake -S solidity -B solidity/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build solidity/build --target solc -j 8
cargo build --manifest-path foundry/Cargo.toml --locked --bin forge
```

Then run the tests; the patched forge compiles the frame contracts natively (the project's
default profile sets `evm_version = "@future"`, `experimental = true`, and the patched solc
path):

```bash
cd contracts
../foundry/target/debug/forge test --allow-local-compiler
```

To add an account:

1. Add `contracts/src/accounts/MyAccount.sol`. Inline assembly can use `approvetx`, `txparam`,
   `frameparam`, `sigparam`, and the other toolkit builtins; forge builds it like any other
   source.
2. Inherit [`contracts/test/AccountTestSuite.sol`](contracts/test/AccountTestSuite.sol) and
   implement `accountUnderTest()` plus `accountAuthorizationSignatures()`. The inherited
   cases exercise self-payment, external
   sponsorship, paying for another sender, shifted signature routing, exact scopes, and ETH
   funding. Add account-specific policy cases alongside them. If the policy trusts keys or
   proof forms not enumerated by the positive signature hook, override
   `accountUnauthorizedSignatures()` with entries the policy is guaranteed to reject.
3. Run the focused test:

```bash
../foundry/target/debug/forge test --allow-local-compiler --match-contract MyAccountTest -vvv
```

Paymaster implementations have the parallel
[`contracts/test/PaymasterTestSuite.sol`](contracts/test/PaymasterTestSuite.sol). Its
four hooks provide the deployed paymaster, one trusted signature, scalar index-selecting
calldata, and accepted max cost; inherited cases require sponsorship of all ten account targets:
`OwnerAccount`, `MultisigAccount`, `SessionKeyAccount` through its owner, the portable and
builtin Yul accounts, `P256Account`, `WebAuthnAccount`, `MLDSAAccount`, the migrated Kernel
v3.3 proxy, and the EIP-7702-delegated EOA. Every case uses one shared, shifted signature
envelope. Sender-specific signature policies can override `_preparePaymasterForAccount(address)`;
a paymaster without signature authorization needs a policy-specific suite.

### Full Anvil transactions

Use this path to test canonical signed type-`0x06` envelopes, admission, execution, receipts,
traces, and replay:

```bash
# From the repository root
cargo build --manifest-path foundry/Cargo.toml --locked --bin anvil
foundry/target/debug/anvil --hardfork prague --enable-frame-transactions
```

Use `--hardfork osaka` instead of `prague` when the validation path executes
`WebAuthnAccount` or `WebAuthnPaymaster`; both call the EIP-7951 precompile at `0x100`.
The Anvil suite includes a raw native-P256 transaction that rejects a corrupted public key,
then mines the valid type-`0x06` envelope through `P256Account` and checks its payer, nonce,
and SENDER-frame effects. It also submits a real 3,732-byte ML-DSA-44 entry through the
production `MLDSAAccount`, rejects a corrupt signature at admission, and checks payer debit,
nonce, and SENDER effects. A second raw case proves the multisig-owner/index-1 default-payer
reuse path. There is currently no equivalent Anvil WebAuthn end-to-end test.

Anvil accepts frame transactions only as signed raw bytes through `eth_sendRawTransaction`.
Object-form `eth_sendTransaction` and `eth_call` do not construct them, and `cast send` does
not yet have a frame-transaction builder. The transaction types and signing examples live in:

- [`foundry/crates/primitives/src/transaction/frame.rs`](foundry/crates/primitives/src/transaction/frame.rs)
- [`foundry/crates/anvil/tests/it/frame_tx.rs`](foundry/crates/anvil/tests/it/frame_tx.rs)

Run the existing end-to-end transaction suite without starting a separate node:

```bash
# From the repository root
cargo test --manifest-path foundry/Cargo.toml --locked -p anvil --test it frame_tx
```

`--enable-frame-transactions` is independent of the experimental proposal flags. Add
`--enable-eip7819`, `--enable-eip7851`, or `--enable-eip8151` when a test also needs those
features.

## Guides

1. **[Building](guides/01-build.md)** — the four-component toolchain build order and artifact generation.
2. **[Writing accounts](guides/02-writing-accounts.md)** — the opcodes, the parameter
   tables, the `APPROVE` scope rules, and the constraints that will bite you.
3. **[Limitations](guides/03-limitations.md)** — what is not implemented and where this
   toolkit knowingly diverges from the spec. **Read this before planning work.**
4. **[Foundry and revm](guides/04-foundry.md)** — the patched Forge, Anvil activation and
   support boundaries, receipts, tracing, and replay.
5. **[Migration](guides/05-migration.md)** — phased ERC-4337 and EOA migration plans,
   rollback controls, nonce/funding boundaries, and counterfactual-address constraints.

## Accounts and paymasters

All under [`contracts/src/accounts`](contracts/src/accounts), each with notes in
[`contracts/docs`](contracts/docs) and tests in [`contracts/test`](contracts/test).

| Contract | Kind | Demonstrates |
|---|---|---|
| `account.yul` / `account-builtins.yul` | Account | The same minimal one-index owner account, emitted through portable `verbatim` or patched builtins |
| `OwnerAccount.sol` | Account | The canonical single-owner starting point |
| `MultisigAccount.sol` | Account | k-of-n over protocol-verified signatures, with no signature parsing |
| `SessionKeyAccount.sol` | Account | Cross-frame constraints for a delegated key, with expiry via the expiry verifier frame |
| `P256Account.sol` | Account | Native protocol-verified P256 metadata, `keccak256(qx || qy)[12:]` signer identity, and self-call key rotation |
| `WebAuthnAccount.sol` | Account | A strict WebAuthn assertion carried as an `ARBITRARY` witness and verified at precompile `0x100` |
| `MLDSAAccount.sol` | Account | Exact toolkit-local native ML-DSA-44 scheme `0x03`, domain-separated signer identity, and self-call key rotation |
| [`KernelV33FrameAccount.sol`](contracts/src/accounts/KernelV33FrameAccount.sol) | Migration adapter | A 1,014-byte, storage-free compatibility shim for an unhooked Kernel v3.3 ECDSA root; it adds Frame validation and delegates the complete legacy surface to the exact prior implementation |
| [`EOA7702FrameAccount.sol`](contracts/src/accounts/EOA7702FrameAccount.sol) | Migration adapter | Same-address EIP-7702 delegation with secp256k1-only Frame approval and a self-only legacy execution path |
| `SponsoringPaymaster.sol` | Paymaster | Third-party sponsorship authorized by a protocol-verified secp256k1 signer |
| `P256Paymaster.sol` | Paymaster | Third-party sponsorship authorized by a protocol-verified native P256 signer |
| `WebAuthnPaymaster.sol` | Paymaster | Third-party sponsorship authorized by a strict WebAuthn assertion |
| `MLDSAPaymaster.sol` | Paymaster | Third-party sponsorship authorized by the exact toolkit-local native ML-DSA-44 scheme |

[`contracts/docs/09-p256-and-webauthn.md`](contracts/docs/09-p256-and-webauthn.md)
documents the two P256 paths, their APIs, exact WebAuthn witness profile, public-mempool
status, and test boundaries. [`contracts/docs/10-pq.md`](contracts/docs/10-pq.md) documents
the non-normative ML-DSA wire, gas, contracts, generic native-policy support, key lifecycle,
and audit boundary. `contracts/docs/01-eoa-default-code.md` covers the no-contract EOA path.
The production adapters and real factory/delegation tests are indexed in
[the migration guide](guides/05-migration.md#executable-migration-examples).

## Two things that will trip you up

**The `APPROVE` builtin is spelled `approvetx`.** The spec calls the opcode `APPROVE`, but
that is the ERC-20 method name and appears in a large share of deployed Solidity; reserving
it as a compiler builtin would break existing contracts. The opcode byte `0xaa` is
unchanged. `approve` stays free for your own code.

**anvil's frame profile is explicit.** Start it with `--enable-frame-transactions`, then
send a raw signed type-`0x06` envelope via `eth_sendRawTransaction`. The default profile
rejects frame transactions, and object-form `eth_call`/`eth_sendTransaction` requests are
not silently downgraded. On supported pre-Amsterdam Ethereum profiles, Anvil validates,
mines, traces, and replays frame transactions, exposes `payer` and `frameReceipts` in the
RPC receipt, and installs the canonical expiry verifier at `0x8141`. `forge test`
additionally exercises accounts in isolation via the `setFrameTx` cheatcode. See
[guides/04-foundry.md](guides/04-foundry.md).

**Experimental proposals have separate opt-ins.** Compile `setdelegate(salt, target)`,
`setselfdelegate(target)`, and contracts whose `ecrecover` mutability matters against solc's
`@future` EVM version. Start Anvil with `--enable-eip7819`, `--enable-eip7851`, or
`--enable-eip8151`; all three stay disabled by default and require Prague-or-later execution
rules. EIP-7851 and EIP-8151 are limited to the canonical Ethereum profile. EIP-7851 uses
toolkit-local opcode `0xf7` while the upstream assignment remains TBD. No flag implies
`--enable-frame-transactions`; see
[guides/04-foundry.md](guides/04-foundry.md).

## When the spec changes

```bash
tools/check-spec-drift.sh
```

Fetches the exact upstream source pin and current `ethereum/EIPs` master, then exits
non-zero and prints their diff if upstream moved. It deliberately does not compare the
local explanatory notes, experimental ML-DSA-44 scheme, or tooling appendix to upstream as
though they should be identical.
[VERSIONS.md](VERSIONS.md) maps each spec area to the code implementing it, so you can go
straight to what a given change affects.

## Status

Proof of concept. Compiler support, synthetic Forge execution, and the opt-in Anvil raw-RPC
path exist in the current pinned toolkit stack, including nested receipts, parity traces,
canonical raw-byte fork replay, and expiry-verifier activation. The
default branches (`develop`, `main`, `main`, and `master`, respectively) for Solidity, revm,
foundry-core, and Foundry contain the pinned stack and reproduce from a fresh recursive clone.
Keyed-nonce/recent-root/POST_TX
wire and state integration, public-pool policy, gossip, and Amsterdam state-gas compatibility
are not implemented. Toolkit-local ML-DSA-44 uses an upstream-reserved scheme value and is
experimental and unaudited. Experimental EIP-7819, EIP-7851, and EIP-8151 compiler/VM and opt-in
Anvil support is also present. Non-Ethereum execution profiles reject frame envelopes and mask
the Ethereum-only proposal flags. Not independently audited; not for production.
