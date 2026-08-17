# Foundry project

The toolkit's patched Foundry executes frame contracts, but patched solc still has
to compile them separately. Understanding that boundary saves a lot of confusion.

## What Foundry can and cannot do

| | Policy layer (`src/policy`) | Frame glue (`src/accounts`, `src/frame`) |
|---|---|---|
| `forge build` | Yes | **No** |
| patched `forge test` | Yes, including fuzz | **Yes**, from `out-frame` artifacts |
| stock `forge test` | Yes | **No**, frame opcodes are invalid |
| Contains frame opcodes | No | Yes |

Compilation and execution are separate concerns:

**Foundry cannot compile frame contracts.** `evm_version` is validated against a
closed enum, and `@future` is not in it:

```
$ forge build            # with evm_version = "@future"
Error: foundry config error: Unknown evm version: @future for setting `evm_version`
```

There is also no passthrough for solc's `experimental` setting, which `@future`
requires. Pointing `solc` at the patched binary does not help.

**Stock Foundry cannot execute them.** Its EVM treats `0xaa` and `0xb0`–`0xb9`
as invalid. The toolkit pins Foundry to the published revm fork, which
implements the baseline/native opcodes plus the provisional tooling-fixture profile.
The `setFrameTx` cheatcode copies host-supplied context for those tests; it does not make
fixture nonce keys, recent roots, POST_TX traces, diffs, or events normative transaction data.

The account tests therefore build frame contracts with patched solc, install
their runtime bytecode with `vm.etch`, and execute it under patched revm. This is
real opcode execution, not a Solidity mock.

## The split, and why it is good design anyway

EIP-8141 hands the account a much smaller job than ERC-4337 does. Before any frame runs, the
protocol verifies every protocol signature against either the canonical transaction hash or
its explicit digest, so the account never touches elliptic curves. What remains is a
**policy** question: which keys signed the canonical transaction hash, and should those keys
approve the frames about to execute?

That policy is ordinary Solidity, and it is where the bugs are — threshold
counting, duplicate signers, session-key expiry, target allowlists, selector
extraction. `src/policy/FrameAccountPolicy.sol` holds it, and `forge test` covers it
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
SOLC=../solidity/build/solc/solc ./script/build-frame-accounts.sh
../foundry/target/release/forge test          # policy + frame semantics
../foundry/target/release/forge test -vvv     # with traces
../foundry/target/release/forge fmt           # formats src/ and test/
```

Building the frame-glue contracts, which Foundry cannot:

```bash
./script/build-frame-accounts.sh
# or, if the submodule is not built:
SOLC=/path/to/patched/solc ./script/build-frame-accounts.sh
```

That compiles every account and frame-library contract with the patched compiler using
`--no-cbor-metadata`, then writes ABI, creation-bytecode, and runtime-bytecode artifacts to
`out-frame/<Name>/`. `out-frame` is ignored and is not present in a fresh clone. The script
must run before tests so they cannot accidentally consume absent or stale bytecode. It
refuses stock solc rather than emitting subtly wrong output. The tests load those artifacts
directly — see
[guides/02-writing-accounts.md](../guides/02-writing-accounts.md#testing-an-account).

The root gitlinks and Foundry lockfile record the exact published compiler and VM commits; see
[VERSIONS.md](../VERSIONS.md#reproducibility-status).
