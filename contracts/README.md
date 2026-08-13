# Foundry project

Foundry works here, but only for half the problem. Understanding which half saves
a lot of confusion.

## What Foundry can and cannot do

| | Policy layer (`src/`) | Frame glue (`../examples/*.sol`) |
|---|---|---|
| `forge build` | Yes | **No** |
| `forge test` | Yes, including fuzz | **No** |
| Contains frame opcodes | No | Yes |

Two independent blockers, both verified rather than assumed:

**Foundry cannot compile frame contracts.** `evm_version` is validated against a
closed enum, and `@future` is not in it:

```
$ forge build            # with evm_version = "@future"
Error: foundry config error: Unknown evm version: @future for setting `evm_version`
```

There is also no passthrough for solc's `experimental` setting, which `@future`
requires. Pointing `solc` at the patched binary does not help.

**Foundry could not execute them anyway.** Its EVM is revm, which has no
`0xaa`/`0xb0`–`0xb4`. Etching the real `APPROVE` sequence and calling it:

```
APPROVE 0xaa executed ok: no
TXPARAM 0xb0 executed ok: no
```

Both halt as invalid opcodes. Even with a compiled artifact, `forge test` cannot
exercise frame semantics — there is no frame context in revm for `sigparam` or
`frameparam` to report on.

## The split, and why it is good design anyway

EIP-8141 hands the account a much smaller job than ERC-4337 does. The protocol
verifies every signature against the canonical signature hash before any frame
runs, so the account never touches elliptic curves. What is left is a **policy**
question: given the keys that provably signed and the frames about to execute,
approve or not?

That policy is ordinary Solidity, and it is where the bugs are — threshold
counting, duplicate signers, session-key expiry, target allowlists, selector
extraction. `src/FrameAccountPolicy.sol` holds it, and `forge test` covers it
including fuzz runs.

The frame glue — read the signers with `sigparam`, inspect frames with
`frameparam`, approve with `approvetx` — is a handful of lines with no branching
logic. It is exercised against a real EVM by the account tests in `test/`, which run the
compiled runtimes under the patched revm.

So the split is not a workaround grafted on to dodge a tooling limit; separating
an authorisation policy from its entrypoint is how you would write this anyway.
The tooling boundary just happens to fall in the same place.

## Usage

```bash
forge test          # policy layer, stock solc, no frame opcodes
forge test -vvv     # with traces
forge fmt           # formats src/ and test/
```

Building the frame-glue contracts, which Foundry cannot:

```bash
./script/build-frame-accounts.sh
# or, if the submodule is not built:
SOLC=/path/to/patched/solc ./script/build-frame-accounts.sh
```

That compiles every `../examples/*/*.sol` with the patched compiler and writes
artifacts to `out-frame/<Name>/`. It refuses to run against a stock solc rather
than emitting subtly wrong output. The runtime bytecode it produces is what you
paste into the Go harness to test frame semantics — see
[guides/02-writing-accounts.md](../guides/02-writing-accounts.md#testing-an-account).

## If you want `forge test` to run frame semantics

It would take patching revm to add the six opcodes and a frame-transaction
context, then teaching Foundry's `evm_version` enum about the fork. That is a
real project and nothing here depends on it. Until then the Go harness is the
only environment that implements EIP-8141, and it is the one the examples are
verified against.
