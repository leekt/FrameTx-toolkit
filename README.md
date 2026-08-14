# FrameTx Toolkit

Everything needed to write and run [EIP-8141](spec/EIP8141.md) frame transaction contracts:
a patched **revm/Foundry** that executes them, a patched **solc** that compiles them, and
worked smart accounts with tests.

EIP-8141 is a **draft**. Every component here is pinned to an exact commit — see
[VERSIONS.md](VERSIONS.md) — so a future spec revision can be diffed against a known
baseline rather than guessed at.

```bash
git clone --recurse-submodules https://github.com/leekt/FrameTx-toolkit.git
cd FrameTx-toolkit/contracts && forge test        # 53 tests
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
| [`solidity/`](https://github.com/leekt/solidity/tree/feat/eip8141-frame-opcodes) | Submodule — compiles the six new opcodes |
| [`revm/`](https://github.com/leekt/revm/tree/feat/eip8141-frame-opcodes) | Submodule — executes the six new opcodes |
| [`foundry/`](https://github.com/leekt/foundry/tree/feat/eip8141-frame-opcodes) | Submodule — `forge` with the frame cheatcodes |
| [`spec/EIP8141.md`](spec/EIP8141.md) | The pinned spec text, vendored |
| [`contracts/`](contracts/) | The Foundry project: accounts in `src/accounts`, policy in `src/policy`, **all tests** in `test/` |
| [`guides/`](guides/) | Build, write, and what does not work yet |
| [`tools/check-spec-drift.sh`](tools/check-spec-drift.sh) | Detect whether the spec moved |

## Guides

1. **[Building](guides/01-build.md)** — compiling both submodules, and verifying you have
   the patched compiler.
2. **[Writing accounts](guides/02-writing-accounts.md)** — the opcodes, the parameter
   tables, the `APPROVE` scope rules, and the constraints that will bite you.
3. **[Limitations](guides/03-limitations.md)** — what is not implemented and where this
   toolkit knowingly diverges from the spec. **Read this before planning work.**
4. **[Foundry and revm](guides/04-foundry.md)** — the patched forge, and what is still
   needed for `forge test` and anvil to handle frame transactions.

## Accounts

All under [`contracts/src/accounts`](contracts/src/accounts), each with notes in
[`contracts/docs`](contracts/docs) and tests in [`contracts/test`](contracts/test).

| Account | Demonstrates |
|---|---|
| `account.yul` | The smallest real account, 19 bytes, and how to emit the opcodes on **stock** solc via `verbatim` |
| `OwnerAccount.sol` | The canonical starting point |
| `MultisigAccount.sol` | k-of-n over protocol-verified signatures, with no signature parsing |
| `SessionKeyAccount.sol` | Cross-frame introspection to constrain a delegated key |
| `SponsoringPaymaster.sol` | Third-party gas sponsorship |

`contracts/docs/01-eoa-default-code.md` covers the no-contract EOA path.

## Two things that will trip you up

**The `APPROVE` builtin is spelled `approvetx`.** The spec calls the opcode `APPROVE`, but
that is the ERC-20 method name and appears in a large share of deployed Solidity; reserving
it as a compiler builtin would break existing contracts. The opcode byte `0xaa` is
unchanged. `approve` stays free for your own code.

**anvil accepts frame transactions.** Send a type `0x06` envelope via
`eth_sendRawTransaction` and it is validated, mined and executed — including atomic
batches and the default-code EOA path. `forge test` additionally exercises accounts in
isolation via the `setFrameTx` cheatcode. Per-frame receipts are not yet exposed over
RPC; see [guides/04-foundry.md](guides/04-foundry.md).

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
