# FrameTx Toolkit

Everything needed to write and run [EIP-8141](https://forkcast.org/eips/8141) frame transaction contracts:
a patched **revm/Foundry** that executes them, a patched **solc** that compiles them, and
worked smart accounts with tests.

EIP-8141 is a **draft**. The upstream spec base and each published submodule gitlink are
recorded at exact commits in [VERSIONS.md](VERSIONS.md).

## Getting started

Nothing gets installed: the patched solc and forge/anvil are built inside the submodules
and invoked by path, so your existing `forge` (`~/.foundry/bin`) and any system solc stay
untouched.

**1. Get the stack** (the gitlinks pin the exact revm/foundry commits the tests expect;
stale binaries built from older submodule states will fail):

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
cd FrameTx-toolkit
# or, updating an existing clone:
git pull && git submodule update --init --recursive
```

**2. Build the two patched tools** (once, then incremental). Foundry's manifest pins the
revm fork (all twelve crates) and the foundry-core fork (compilers with the `@future` EVM
version) at exact commits, so cargo fetches the right sources automatically — you never
build them separately unless you are hacking on them:

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
../foundry/target/debug/forge test      # builds everything, frame contracts included
```

The project's default profile sets `evm_version = "@future"`, `experimental = true`, and
`solc = "../solidity/build/solc/solc"`, so the patched forge compiles `src/accounts`,
`src/frame`, and `src/eips` natively and rebuilds them like any other source. Tests etch
the resulting runtimes (`vm.getDeployedCode`) and drive them through the patched revm via
the `setFrameTx` cheatcode.

For real signed type-`0x06` envelopes, receipts, and state gas, run the patched node:

```bash
foundry/target/debug/anvil --enable-frame-transactions   # plus --enable-eip7819 / --enable-eip7851 / --enable-eip8151 as needed
```

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
| [EIP-8141](https://forkcast.org/eips/8141) | Frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Considered (CFI) | Compiler, VM, and opt-in Anvil raw-RPC path implemented, including receipts, traces, and fork replay |
| [EIP-7906](https://forkcast.org/eips/7906) | Transaction assertions via state-diff opcode | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied EVM fixture only; wire and trace construction pending |
| [EIP-8250](https://forkcast.org/eips/8250) | Keyed nonces for frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied context only; wire and state integration pending |
| [EIP-8272](https://forkcast.org/eips/8272) | Recent roots for frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied context only; wire and root verification pending |
| [EIP-7819](https://forkcast.org/eips/7819) | `SETDELEGATE` instruction | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler, REVM, and explicit Anvil opt-in implemented with gas, collision, refund, clearing, nonce, and immediate-effect coverage |
| [EIP-7851](https://forkcast.org/eips/7851) | Code-controlled EOA delegation | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler, REVM, and Ethereum-only Anvil opt-in implemented; upstream leaves the opcode TBD, so the toolkit explicitly uses non-normative `0xf7` |
| [EIP-8151](https://forkcast.org/eips/8151) | Account-code-restricted `ecRecover` | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler mutability/formal modeling, REVM, and Ethereum-only Foundry/Anvil opt-in implemented with raw-code, gas, warmth, replay, and access-list coverage |

Fork inclusion statuses are sourced from Forkcast as of 2026-08-16. The local
[implementation document](spec/EIP8141.md) has a normative body based on pinned EIP-8141
master (with the `fees`/`limits` envelope and EIP-8037 state-gas budgets) plus the native
`SIGDATACOPY` split of [EIPs PR #12187](https://github.com/ethereum/EIPs/pull/12187),
followed by a clearly non-normative appendix for the context-only
EIP-8250/8272/7906 tooling fixture. The appendix does not define transaction-wire semantics
for those extensions.

A fresh clone checks out the exact verified compiler, VM, and tooling commits. See
[Building the toolkit](guides/01-build.md) for the required build order.

## What EIP-8141 changes

A frame transaction (type `0x06`) decomposes a transaction into a sequence of **frames** —
contract calls that validate the transaction, approve gas payment, and execute the user's
operations. Validity and gas payment become programmable.

The consequence that matters for contract authors: **the protocol verifies signatures before
your code runs.** Every `SECP256K1`/`P256` entry is checked against either the canonical
transaction hash (empty `msg`) or its explicit digest before frame execution begins. An
account no longer runs `ecrecover`; it asks which key signed, requires the canonical-hash
case when authorizing frames, and applies policy. Solidity accounts share the
`validate(uint256[] signatureIndices)` ABI (selector `0x25b90494`). The array tells the
account which entries in `tx.signatures` belong to its policy; canonical signatures commit
to that routing because the VERIFY frame's calldata is part of the transaction hash. The
core of a single-owner validator is:

```solidity
function validate(uint256[] calldata signatureIndices) external {
    bool ownerSigned;
    for (uint256 i; i < signatureIndices.length; ++i) {
        uint256 sigIndex = signatureIndices[i];
        if (FrameTxLib.sigScheme(sigIndex) == FrameTxLib.SCHEME_ARBITRARY) continue;
        if (FrameTxLib.signedThisTx(sigIndex) && FrameTxLib.sigSigner(sigIndex) == owner) {
            ownerSigned = true;
            break;
        }
    }
    if (!ownerSigned) revert();

    uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
    if (scope == FrameTxLib.SCOPE_NONE) revert();
    FrameTxLib.approve(scope);
}
```

Deriving the current frame's allowed scope lets the same account validate and pay for
itself (`BOTH`), validate while a paymaster supplies ETH (`EXECUTION`), or pay for another
already-approved sender (`PAYMENT`). The standalone Yul account implements the same ABI for
exactly one selected index and treats empty calldata as its ETH-funding path.

## Contents

| Path | What |
|---|---|
| [`solidity/`](https://github.com/leekt/solidity/tree/feat/eip8141-frame-opcodes) | Submodule — compiles the pinned/native surface plus non-normative fixture opcodes |
| [`revm/`](https://github.com/leekt/revm/tree/feat/native-sigdatacopy) | Submodule — executes the pinned/native surface plus host-supplied fixture context |
| [`foundry/`](https://github.com/leekt/foundry/tree/feat/frame-tx-txparam-context) | Submodule — `forge` with the frame cheatcodes |
| [`spec/EIP8141.md`](spec/EIP8141.md) | Master-spec normative overlay (with PR #12187's SIGDATACOPY split) plus a non-normative tooling-fixture appendix |
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
account validation and approval behavior, but not type-`0x06` wire encoding or pool admission.

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
../foundry/target/debug/forge test
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
../foundry/target/debug/forge test --match-contract MyAccountTest -vvv
```

Paymaster implementations have the parallel
[`contracts/test/PaymasterTestSuite.sol`](contracts/test/PaymasterTestSuite.sol). Its
four hooks provide the deployed paymaster, trusted signatures, index-selecting calldata,
and accepted max cost; inherited cases require sponsorship of every toolkit account family
using one shared, shifted signature envelope. A paymaster with no signature authorization
returns an empty signature array; sender-specific setup can override
`_preparePaymasterForAccount(address)`.

### Full Anvil transactions

Use this path to test canonical signed type-`0x06` envelopes, admission, execution, receipts,
traces, and replay:

```bash
# From the repository root
cargo build --manifest-path foundry/Cargo.toml --locked --bin anvil
foundry/target/debug/anvil --hardfork prague --enable-frame-transactions
```

Anvil accepts frame transactions only as signed raw bytes through `eth_sendRawTransaction`.
Object-form `eth_sendTransaction` and `eth_call` do not construct them, and `cast send` does
not yet have a frame-transaction builder. The transaction types and signing examples live in:

- `foundry/crates/primitives/src/transaction/frame.rs`
- `foundry/crates/anvil/tests/it/frame_tx.rs`

Run the existing end-to-end transaction suite without starting a separate node:

```bash
# From the repository root
cargo test --manifest-path foundry/Cargo.toml --locked -p anvil --test it frame_tx
```

`--enable-frame-transactions` is independent of the experimental proposal flags. Add
`--enable-eip7819`, `--enable-eip7851`, or `--enable-eip8151` when a test also needs those
features.

## Guides

1. **[Building](guides/01-build.md)** — the three-submodule build order and artifact generation.
2. **[Writing accounts](guides/02-writing-accounts.md)** — the opcodes, the parameter
   tables, the `APPROVE` scope rules, and the constraints that will bite you.
3. **[Limitations](guides/03-limitations.md)** — what is not implemented and where this
   toolkit knowingly diverges from the spec. **Read this before planning work.**
4. **[Foundry and revm](guides/04-foundry.md)** — the patched Forge, Anvil activation and
   support boundaries, receipts, tracing, and replay.

## Accounts

All under [`contracts/src/accounts`](contracts/src/accounts), each with notes in
[`contracts/docs`](contracts/docs) and tests in [`contracts/test`](contracts/test).

| Account | Demonstrates |
|---|---|
| `account.yul` | A minimal owner account with the shared one-index validation ABI, emitted on **stock** solc via `verbatim` |
| `OwnerAccount.sol` | The canonical starting point |
| `MultisigAccount.sol` | k-of-n over protocol-verified signatures, with no signature parsing |
| `SessionKeyAccount.sol` | Cross-frame introspection to constrain a delegated key, with expiry via the expiry verifier frame |
| `SponsoringPaymaster.sol` | Third-party gas sponsorship |

`contracts/docs/01-eoa-default-code.md` covers the no-contract EOA path.

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
local native-SIGDATACOPY overlay or tooling appendix to upstream as though they should be
identical.
[VERSIONS.md](VERSIONS.md) maps each spec area to the code implementing it, so you can go
straight to what a given change affects.

## Status

Proof of concept. Compiler support, synthetic Forge execution, and the opt-in Anvil raw-RPC
path are implemented in the published toolkit commits, including nested receipts, parity traces,
canonical raw-byte fork replay, and expiry-verifier activation. Keyed-nonce/recent-root/POST_TX
wire and state integration, public-pool policy, gossip, and Amsterdam state-gas compatibility
are not implemented. Experimental EIP-7819, EIP-7851, and EIP-8151 compiler/VM and opt-in
Anvil support is also present. Non-Ethereum execution profiles reject frame envelopes and mask
the Ethereum-only proposal flags. Not independently audited; not for production.
