# FrameTx Toolkit

Everything needed to write and run [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141) frame transaction contracts:
a patched **revm/Foundry** that executes them, a patched **solc** that compiles them, and
worked smart accounts with tests.

EIP-8141 is a **draft**. The upstream spec base, toolchain gitlinks, and Solidity package
pins are recorded exactly in [VERSIONS.md](VERSIONS.md).

See [the current spec baseline](spec/README.md) for the selected AA proposals and
implementation boundaries. The submodules and Foundry dependency pins record the published
toolchain revisions; build those sources as described below.

## vFrame: testing on a stock EVM

[vFrame](vframe/README.md) is an ordinary Solidity EntryPoint for testing
validation, account execution, sponsorship, keyed nonces, and atomic rollback. It runs
without FrameTx EIPs or patched tools:

```bash
forge test --root vframe -vv
```

It includes an owner account, a sponsor, and a deployment/relay demo. See the
[vFrame guide](vframe/README.md) for dependency setup, operation construction,
and the differences from native protocol execution.

## Getting started with the native toolkit

The patched solc and forge/anvil are built inside the toolchain submodules and invoked by
path, so your existing `forge` (`~/.foundry/bin`) and any system solc stay untouched.
Solidity packages install locally under the ignored `contracts/dependencies/` directory via
Soldeer.

**1. Clone the toolkit and its pinned toolchain.**

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
cd FrameTx-toolkit
# or, updating an existing clone:
git pull && git submodule update --init --recursive
```

**2. Build the two patched tools** (once, then incremental). Foundry pins all twelve
REVM crates to the published revision recorded by the REVM submodule and pins its
foundry-core compiler dependency for `@future`:

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
../foundry/target/debug/forge soldeer install              # restores soldeer.lock exactly
../foundry/target/debug/forge test --allow-local-compiler  # trusts the pinned local solc
```

The project's default profile sets `evm_version = "@future"`, `experimental = true`, and
`solc = "../solidity/build/solc/solc"`, so the patched forge compiles `src/accounts`,
`src/formatters`, `src/frame`, and `src/eips` natively and rebuilds them like any other
source. Tests etch
the resulting runtimes (`vm.getDeployedCode`) and drive them through the patched revm via
the `setFrameTx` cheatcode. In this toolkit, `@future` executes as **Osaka**, the last
pre-Amsterdam Ethereum profile. That activates the [EIP-7951 P256VERIFY
precompile](https://eips.ethereum.org/EIPS/eip-7951) at `0x100`, which the WebAuthn
verification paths need, without enabling Amsterdam's incompatible node-level state-gas rules.

For real signed type-`0x06` envelopes, receipts, and state gas, run the patched node:

```bash
foundry/target/debug/anvil --enable-frame-transactions   # plus --enable-eip8151 as needed
```

That command is sufficient for the existing frame-transaction examples. To execute a
WebAuthn verification path, start Anvil with `--hardfork osaka` as well so precompile `0x100` is
active. The repository does not yet claim a raw-transaction WebAuthn end-to-end test.

**Coexisting with stock Foundry and solc:**

- Stock `forge` still runs the policy layer through the `policy` profile:
  `FOUNDRY_PROFILE=policy forge test --match-path test/FrameAccountPolicy.t.sol`.
  The [vFrame project](vframe/README.md) also runs on stock tools. Native
  `@future` compilation, `setFrameTx`, and frame opcodes need the patched binaries.
- Don't `foundryup` or `cargo install` the fork — invoking by path is the design. If the
  path gets old: `alias fforge=$PWD/foundry/target/debug/forge` (and `fanvil` likewise).
- The patched forge runs any normal Foundry project unchanged. To use frame opcodes in
  another project, replicate the pattern here: compile the opcode-bearing contracts
  externally with `solidity/build/solc/solc --experimental --evm-version @future`, etch
  the runtime in tests, and declare the `IFrameVm` interface field-for-field (copy
  [`contracts/test/FrameTest.sol`](contracts/test/FrameTest.sol)).
- Sanity checks: [guides/01-build.md](guides/01-build.md) has a probe contract confirming
  you're on the right solc (stock solc lacks `approvetx`).
  [`tools/check-spec-drift.sh`](tools/check-spec-drift.sh) tells you if upstream EIP-8141
  moved off the pin.

Prerequisites and the full build order live in [guides/01-build.md](guides/01-build.md).

## EIP roadmap

The selected AA set is EIP-8141 plus **7906, 8250, 8272, 8298, and 8151**. PFI is
eligible; DFI proposals are excluded. Inclusion is pinned as of 2026-09-16.

| EIP | Status | Toolkit support |
|---|---|---|
| [8141](https://eips.ethereum.org/EIPS/eip-8141) Frame transactions | Hegotá SFI; Draft specification | Compiler, REVM, Forge and opt-in Anvil; explicit state-gas and mempool limits |
| [7906](https://eips.ethereum.org/EIPS/eip-7906) Transaction assertions | PFI | Host fixtures; raw POST_TX execution remains pending |
| [8250](https://eips.ethereum.org/EIPS/eip-8250) Keyed nonces | PFI | Nested-fee wire format, nonce bookkeeping and state-gas first-use charges |
| [8272](https://eips.ethereum.org/EIPS/eip-8272) Recent roots | PFI | Verifier-frame tuple encoder; canonical verifier bytecode remains TBD |
| [8298](https://eips.ethereum.org/EIPS/eip-8298) SETCODEFROM | PFI | Spec tracked; opcode remains TBD and execution is not implemented |
| [8151](https://eips.ethereum.org/EIPS/eip-8151) Code-restricted ecRecover | PFI | Compiler semantics and explicit Ethereum-only REVM/Foundry/Anvil opt-in |
| [7997](https://eips.ethereum.org/EIPS/eip-7997) Deterministic factory | Glamsterdam SFI | Exact factory/runtime and Create2FactoryLib; activation nonce/fork gating not modeled |

EIP-7819 and EIP-7851 were DFI'd at [ACDE 245](https://forkcast.org/calls/acde/245/)
and are removed. [Spec sources and migration notes](spec/README.md) record exact revisions,
breaking wire changes, and pending work. EIP-8141's [local document](spec/EIP8141.md)
is now an exact upstream snapshot; historical synthetic fixtures are documented separately.

## What EIP-8141 changes

A frame transaction (type `0x06`) decomposes a transaction into a sequence of **frames** —
contract calls that validate the transaction, approve gas payment, and execute the user's
operations. Validity and gas payment become programmable.

The consequence that matters for contract authors: **the protocol verifies native signatures
before your code runs.** Every `SECP256K1`/`P256` entry is checked against either the
canonical transaction hash (empty `msg`) or its explicit digest before frame execution
begins. A native-signature account does
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
    if (!FrameTxLib.signedThisTx(signatureIndex)) revert();
    if (FrameTxLib.sigSigner(signatureIndex) != owner) revert();

    uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
    if (scope == FrameTxLib.SCOPE_NONE) revert();
    FrameTxLib.approve(scope);
}
```

Deriving the current frame's allowed scope lets the same account validate and pay for
itself (`BOTH`), validate while a paymaster supplies ETH (`EXECUTION`), or pay for another
already-approved sender in sponsor-only mode (`PAYMENT`). The last role uses the account's
normal `validate` entry point and does not require a paymaster contract. Every current
paymaster remains available as a specialized alternative and receives one routing index
through `sponsorTransaction(uint256)` (selector `0x217de4d8`).

Post-quantum schemes such as ML-DSA are not native signature schemes today. They must use an
`ARBITRARY` witness and validation-frame or custom-verifier logic that binds the proof to the
canonical signature hash. The toolkit currently ships no ML-DSA verifier, account, or
paymaster; [`contracts/docs/10-pq.md`](contracts/docs/10-pq.md) documents the integration
boundary and future pure-function direction.

Empty-code default accounts remain secp256k1-only. A secp256k1 multisig owner can place its
canonical entry at index 1, let the multisig count that entry for execution, and let a later
default-code PAYMENT frame against the same codeless owner reuse it—one envelope entry and
no second signature. An account using an `ARBITRARY` post-quantum witness cannot use that
default payer path without compatible account code or delegation.

## Contents

| Path | What |
|---|---|
| [`solidity/`](solidity/) | Submodule — compiles the EIP-8141 opcode surface plus non-normative fixture opcodes |
| [`revm/`](revm/) | Submodule — executes the EIP-8141 opcode surface plus host-supplied fixture context |
| [`foundry-core/`](foundry-core/) | Submodule — teaches Foundry's compiler layer the experimental `@future` EVM target |
| [`foundry/`](foundry/) | Submodule — `forge` with the frame cheatcodes and opt-in Anvil transaction path |
| [`contracts/soldeer.lock`](contracts/soldeer.lock) | Exact Kernel v3.3, Solady, forge-std, and ExcessivelySafeCall package resolution; `forge soldeer install` restores them under `contracts/dependencies/` |
| [`spec/EIP8141.md`](spec/EIP8141.md) | Exact pinned upstream FrameTx specification |
| [`contracts/`](contracts/) | The Foundry project: accounts in `src/accounts`, digest formatters in `src/formatters`, policy in `src/policy`, EIP helper libraries in `src/eips`, **all tests** in `test/` |
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
the envelope signature. WebAuthn fixtures do construct a real assertion and execute
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
   sponsorship, sponsoring another sender with PAYMENT-only authority, shifted signature routing, exact scopes, and ETH
   funding. The inherited negatives also show that out-of-range routing, wrong
   secp256k1/P256 signatures, and a selected malformed `ARBITRARY` signature fail. Add
   account-specific policy cases alongside them. If the policy trusts keys or proof forms not
   enumerated by the positive signature hook, override
   `accountUnauthorizedSignatures()` with entries the policy is guaranteed to reject.
3. Run the focused test:

```bash
../foundry/target/debug/forge test --allow-local-compiler --match-contract MyAccountTest -vvv
```

Paymaster implementations have the parallel
[`contracts/test/PaymasterTestSuite.sol`](contracts/test/PaymasterTestSuite.sol). Its
four hooks provide the deployed paymaster, one trusted signature, scalar index-selecting
calldata, and accepted max cost; inherited cases require sponsorship of all configured account targets:
`OwnerAccount`, `MultisigAccount`, `SessionKeyAccount` through its owner, `P256Account`,
`FrameKernel` through native P256, `WebAuthnAccount`, the migrated Kernel
v3.3 proxy, and the EIP-7702-delegated EOA. Every case uses one shared, shifted signature
envelope, and inherited negatives show that wrong supported signatures plus a
malformed selected `ARBITRARY` sponsor signature are refused. Sender-specific signature policies can override
`_preparePaymasterForAccount(address)`;
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
and SENDER-frame effects. A second raw case proves the multisig-owner/index-1 default-payer
reuse path. There is currently no Anvil WebAuthn end-to-end test, and no ML-DSA verifier or
transaction path is shipped.

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
`--enable-eip8151` when a test also needs those
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

Account and paymaster contracts live under
[`contracts/src/accounts`](contracts/src/accounts); stateless digest formatters live under
[`contracts/src/formatters`](contracts/src/formatters). Their notes and tests are in
[`contracts/docs`](contracts/docs) and [`contracts/test`](contracts/test).

| Contract | Kind | Demonstrates |
|---|---|---|
| `OwnerAccount.sol` | Account | The canonical single-owner starting point |
| `MultisigAccount.sol` | Account | k-of-n over protocol-verified signatures, with no signature parsing |
| `SessionKeyAccount.sol` | Account | Cross-frame constraints for a delegated key, with expiry via the expiry verifier frame |
| `P256Account.sol` | Account | Native protocol-verified P256 metadata, `keccak256(qx || qy)[12:]` signer identity, and self-call key rotation |
| [`FrameKernel.sol`](contracts/src/accounts/FrameKernel.sol) | Account | Scheme-scoped native authorities plus modular formatted-P256 keys; the kernel authorizes and verifies P256 while stateless formatters such as [`WebAuthnFormatter`](contracts/src/formatters/WebAuthnFormatter.sol) only produce the signed digest |
| `WebAuthnAccount.sol` | Account | A strict WebAuthn assertion carried as an `ARBITRARY` witness and verified at precompile `0x100` |
| [`KernelV33FrameAccount.sol`](contracts/src/accounts/KernelV33FrameAccount.sol) | Migration adapter | A 1,014-byte, storage-free compatibility shim for an unhooked Kernel v3.3 ECDSA root; it adds Frame validation and delegates the complete legacy surface to the exact prior implementation |
| [`EOA7702FrameAccount.sol`](contracts/src/accounts/EOA7702FrameAccount.sol) | Migration adapter | Same-address EIP-7702 delegation with secp256k1-only Frame approval and plain ETH receipt |
| `SponsoringPaymaster.sol` | Paymaster | Third-party sponsorship authorized by a protocol-verified secp256k1 signer |
| `P256Paymaster.sol` | Paymaster | Third-party sponsorship authorized by a protocol-verified native P256 signer |
| `WebAuthnPaymaster.sol` | Paymaster | Third-party sponsorship authorized by a strict WebAuthn assertion |

[`contracts/docs/09-p256-and-webauthn.md`](contracts/docs/09-p256-and-webauthn.md)
documents the two P256 paths, their APIs, exact WebAuthn witness profile, public-mempool
status, and test boundaries. [`contracts/docs/10-pq.md`](contracts/docs/10-pq.md) explains
how a future post-quantum verifier would use `ARBITRARY` witness bytes and records that no
ML-DSA verifier, account, or paymaster is currently shipped. `contracts/docs/01-eoa-default-code.md`
covers the no-contract EOA path.
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

**EIP-8151 has a separate opt-in.** Compile contracts whose `ecrecover` mutability
matters against solc's `@future` target. Anvil's `--enable-eip8151` remains off by default
and requires Prague-or-later canonical Ethereum execution. It does not enable FrameTx.
See [the proposal status table](spec/README.md) for the other selected drafts.

## When the spec changes

```bash
tools/check-spec-drift.sh
```

Verifies local snapshot checksums and compares all selected sources with one resolved
`ethereum/EIPs` master revision. It exits non-zero on drift or errors; add `--diff` to
print changed source text. Explanatory notes and fixture documentation are separate.
[VERSIONS.md](VERSIONS.md) maps each spec area to the code implementing it, so you can go
straight to what a given change affects.

## Status

Proof of concept. The working tree includes compiler support, synthetic Forge execution,
and opt-in Anvil raw RPC with frame receipts, traces, replay and expiry verification.
The published gitlinks predate this migration; see [VERSIONS.md](VERSIONS.md) for pins
and verification.
Current working-tree support and remaining gaps are recorded in [spec/README.md](spec/README.md).
Keyed nonces use the current EIP-8250 format; recent-root verification, raw POST_TX execution,
public-pool policy, gossip, and complete Amsterdam state-gas integration remain pending.
EIP-8298 is tracked without assigning its TBD opcode. ML-DSA is not a native scheme and
no ready verifier is shipped. EIP-8151 retains its explicit Ethereum-only opt-in.
