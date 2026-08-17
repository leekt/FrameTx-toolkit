# FrameTx Toolkit

Everything needed to write and run [EIP-8141](https://forkcast.org/eips/8141) frame transaction contracts:
a patched **revm/Foundry** that executes them, a patched **solc** that compiles them, and
worked smart accounts with tests.

EIP-8141 is a **draft**. The upstream spec base and each published submodule gitlink are
recorded at exact commits in [VERSIONS.md](VERSIONS.md).

## EIP roadmap

| EIP | Change | Target fork | Inclusion status | Toolkit support |
|---|---|---|---|---|
| [EIP-7997](https://forkcast.org/eips/7997) | Deterministic factory contract | [Glamsterdam](https://forkcast.org/upgrade/glamsterdam) | Scheduled (SFI) | Exact factory address/runtime already available in Anvil; fork-gated activation and nonce `1` are not modeled |
| [EIP-8141](https://forkcast.org/eips/8141) | Frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Considered (CFI) | Compiler, VM, and opt-in Anvil raw-RPC path implemented, including receipts, traces, and fork replay |
| [EIP-7906](https://forkcast.org/eips/7906) | Transaction assertions via state-diff opcode | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied EVM fixture only; wire and trace construction pending |
| [EIP-8250](https://forkcast.org/eips/8250) | Keyed nonces for frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied context only; wire and state integration pending |
| [EIP-8272](https://forkcast.org/eips/8272) | Recent roots for frame transactions | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Host-supplied context only; wire and root verification pending |
| [EIP-7819](https://forkcast.org/eips/7819) | `SETDELEGATE` instruction | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler, REVM, and explicit Anvil opt-in implemented with gas, collision, refund, clearing, nonce, and immediate-effect coverage |
| [EIP-7851](https://forkcast.org/eips/7851) | Code-controlled EOA delegation | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler, REVM, and Ethereum-only Anvil opt-in implemented; upstream leaves the opcode TBD, so the toolkit explicitly uses non-normative `0xf7` |
| [EIP-8151](https://forkcast.org/eips/8151) | Account-code-restricted `ecRecover` | [Hegotá](https://forkcast.org/upgrade/hegota) | Proposed (PFI) | Compiler mutability/formal modeling, REVM, and Ethereum-only Foundry/Anvil opt-in implemented with raw-code, gas, warmth, replay, and access-list coverage |

Fork inclusion statuses are sourced from Forkcast as of 2026-08-16. The local
[implementation document](spec/EIP8141.md) has a normative body based on pinned EIP-8141
with native `SIGDATACOPY`, followed by a clearly non-normative appendix for the context-only
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
case when authorizing frames, and applies policy. A complete single-owner account:

```solidity
fallback() external {
    assembly {
        let signer := sigparam(0, 0x00)                 // who signed, per the protocol
        let signedThisTx := iszero(sigparam(0, 0x02))   // empty msg => canonical tx hash
        if and(eq(signer, sload(0)), signedThisTx) {
            approvetx(0, 0, 3)                          // execution + payment
        }
        revert(0, 0)
    }
}
```

The standalone Yul account compiles to a 27-byte runtime with this transaction-binding
check.

## Contents

| Path | What |
|---|---|
| [`solidity/`](https://github.com/leekt/solidity/tree/feat/eip8141-frame-opcodes) | Submodule — compiles the pinned/native surface plus non-normative fixture opcodes |
| [`revm/`](https://github.com/leekt/revm/tree/feat/native-sigdatacopy) | Submodule — executes the pinned/native surface plus host-supplied fixture context |
| [`foundry/`](https://github.com/leekt/foundry/tree/feat/frame-tx-txparam-context) | Submodule — `forge` with the frame cheatcodes |
| [`spec/EIP8141.md`](spec/EIP8141.md) | Pinned/native normative overlay plus a non-normative tooling-fixture appendix |
| [`contracts/`](contracts/) | The Foundry project: accounts in `src/accounts`, policy in `src/policy`, **all tests** in `test/` |
| [`guides/`](guides/) | Build, write, and what does not work yet |
| [`tools/check-spec-drift.sh`](tools/check-spec-drift.sh) | Detect whether the spec moved |

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
| `account.yul` | A 27-byte owner account bound to the canonical transaction hash, emitted on **stock** solc via `verbatim` |
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
path are implemented in the current working trees, including nested receipts, parity traces,
canonical raw-byte fork replay, and expiry-verifier activation. Keyed-nonce/recent-root/POST_TX
wire and state integration, public-pool policy, gossip, and Amsterdam state-gas compatibility
are not implemented. Experimental EIP-7819, EIP-7851, and EIP-8151 compiler/VM and opt-in
Anvil support is also present. Non-Ethereum execution profiles reject frame envelopes and mask
the Ethereum-only proposal flags. Not independently audited; not for production.
