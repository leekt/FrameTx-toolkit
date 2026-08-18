# Foundry project

The toolkit's patched Foundry both compiles and executes frame contracts: the default
profile drives the patched solc at the experimental `@future` EVM version, so `forge build`
and `forge test` cover the whole project.

## What runs where

| | Policy layer (`src/policy`) | Frame glue (`src/accounts`, `src/frame`, `src/eips`) |
|---|---|---|
| patched `forge build` | Yes | **Yes**, natively at `@future` |
| patched `forge test` | Yes, including fuzz | **Yes** |
| stock `forge` | Yes, via `FOUNDRY_PROFILE=policy` | **No** — `@future` is not in stock compilers, and the frame opcodes are invalid in stock revm |
| Contains frame opcodes | No | Yes |

`contracts/foundry.toml` sets `evm_version = "@future"`, `experimental = true` (solc
requires it with `@future`), and `solc = "../solidity/build/solc/solc"`. The toolkit's
foundry-core compilers fork adds the `@future` EVM version; stock Foundry rejects it:

```
$ forge build            # stock forge, with evm_version = "@future"
Error: foundry config error: Unknown evm version: @future for setting `evm_version`
```

Execution is patched separately: stock revm treats `0xaa` and `0xb0`–`0xb9` as invalid.
The account tests install compiled runtimes with `vm.etch` (from forge's own artifacts,
via `vm.getDeployedCode`) and execute them under the patched revm with host context from
the `setFrameTx` cheatcode. That cheatcode copies host-supplied context; it does not make
fixture nonce keys, recent roots, POST_TX traces, diffs, or events normative transaction
data. This is real opcode execution, not a Solidity mock.

## The policy/glue split, and why it is good design

EIP-8141 hands the account a much smaller job than ERC-4337 does. Before any frame runs, the
protocol verifies every protocol signature against either the canonical transaction hash or
its explicit digest, so the account never touches elliptic curves. What remains is a
**policy** question: which keys signed the canonical transaction hash, and should those keys
approve the frames about to execute?

That policy is ordinary Solidity, and it is where the bugs are — threshold
counting, duplicate signers, session-key expiry, target allowlists, selector
extraction. `src/policy/FrameAccountPolicy.sol` holds it, and `forge test` covers it
including fuzz runs; it stays compilable by stock tooling through the `policy` profile.

The frame glue — read the signers with `sigparam`, inspect frames with
`frameparam`, approve with `approvetx` — is a handful of lines with no branching
logic. It is exercised against a real EVM by the account tests in `test/`.

Separating an authorisation policy from its entrypoint is how you would write this anyway;
the stock-tooling boundary just happens to fall in the same place.

## Usage

```bash
../foundry/target/release/forge test          # builds everything, then policy + frame semantics
../foundry/target/release/forge test -vvv     # with traces
../foundry/target/release/forge fmt           # formats src/ and test/
```

Artifacts are metadata-free (`cbor_metadata = false`, `bytecode_hash = "none"`), so the
byte counts quoted in [`docs/`](docs/) refer to executable runtime code with no CBOR
trailer. Solar-based linting is disabled (`lint_on_build = false`): forge's native Solidity
frontend does not know the fork's builtins; the patched solc is the only frontend that
understands this dialect.

The root gitlinks and Foundry lockfile record the exact published compiler and VM commits; see
[VERSIONS.md](../VERSIONS.md#reproducibility-status).
