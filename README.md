# FrameTx Toolkit

Everything needed to write and run [EIP-8141](spec/EIP8141.md) frame transaction contracts:
a patched **go-ethereum** that executes them, a patched **solc** that compiles them, and
worked smart-account examples.

EIP-8141 is a **draft**. Every component here is pinned to an exact commit — see
[VERSIONS.md](VERSIONS.md) — so a future spec revision can be diffed against a known
baseline rather than guessed at.

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
```

## What EIP-8141 changes

A frame transaction (type `0x06`) decomposes a transaction into a sequence of **frames** —
contract calls that validate the transaction, approve gas payment, and execute the user's
operations. Validity and gas payment become programmable.

The consequence that matters for contract authors: **the protocol verifies signatures before
your code runs.** Every `SECP256K1`/`P256` entry in the envelope is checked against the
canonical signature hash before frame execution begins. An account no longer runs
`ecrecover`; it asks which key signed and applies a policy. A complete single-owner account:

```solidity
fallback() external {
    assembly {
        let signer := sigparam(0, 0x00)              // who signed, per the protocol
        if eq(signer, sload(0)) { approvetx(0, 0, 3) }  // approve execution + payment
        revert(0, 0)
    }
}
```

That compiles to about 20 bytes of validation logic.

## Contents

| Path | What |
|---|---|
| [`go-ethereum/`](https://github.com/leekt/go-ethereum/tree/fix/eip8141-frame-tx) | Submodule — executes frame transactions |
| [`solidity/`](https://github.com/leekt/solidity/tree/feat/eip8141-frame-opcodes) | Submodule — compiles the six new opcodes |
| [`spec/EIP8141.md`](spec/EIP8141.md) | The pinned spec text, vendored |
| [`examples/`](examples/) | Worked accounts and a paymaster |
| [`contracts/`](contracts/) | Foundry project — tested policy layer, plus a build script for the frame glue |
| [`guides/`](guides/) | Build, write, and what does not work yet |
| [`tools/check-spec-drift.sh`](tools/check-spec-drift.sh) | Detect whether the spec moved |

## Guides

1. **[Building](guides/01-build.md)** — compiling both submodules, and verifying you have
   the patched compiler.
2. **[Writing accounts](guides/02-writing-accounts.md)** — the opcodes, the parameter
   tables, the `APPROVE` scope rules, and the constraints that will bite you.
3. **[Limitations](guides/03-limitations.md)** — what is not implemented and where this
   toolkit knowingly diverges from the spec. **Read this before planning work.**

## Examples

| Example | Language | Demonstrates |
|---|---|---|
| [01 — EOA default code](examples/01-eoa-default-code/) | — | Validating with no contract at all; the migration path for existing EOAs |
| [02 — Minimal Yul account](examples/02-yul-minimal-account/) | Yul | The smallest real account, and how to emit the opcodes on **stock** solc via `verbatim` |
| [03 — Solidity owner account](examples/03-solidity-owner-account/) | Solidity | The canonical starting point |
| [04 — Multisig account](examples/04-multisig-account/) | Solidity | k-of-n over protocol-verified signatures, with no signature parsing |
| [05 — Session key account](examples/05-session-key-account/) | Solidity | Cross-frame introspection to constrain what a delegated key may do |
| [06 — Paymaster](examples/06-paymaster/) | Solidity | Third-party gas sponsorship |

## Two things that will trip you up

**The `APPROVE` builtin is spelled `approvetx`.** The spec calls the opcode `APPROVE`, but
that is the ERC-20 method name and appears in a large share of deployed Solidity; reserving
it as a compiler builtin would break existing contracts. The opcode byte `0xaa` is
unchanged. `approve` stays free for your own code.

**You cannot submit a frame transaction to a node yet.** The transaction pool, RPC and
networking layers are not implemented — only the execution layer. Contracts are exercised
through the Go test harness in `go-ethereum/core/eip8141_test.go`. See
[limitations](guides/03-limitations.md).

## When the spec changes

```bash
tools/check-spec-drift.sh
```

Exits non-zero and prints a diff if `ethereum/EIPs` has moved since the pin.
[VERSIONS.md](VERSIONS.md) maps each spec area to the code implementing it, so you can go
straight to what a given change affects.

## Status

Proof of concept. The execution layer and compiler support are implemented and tested; the
networking, pooling and RPC layers are not. Not audited, not for production.
