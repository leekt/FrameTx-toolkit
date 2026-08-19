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
Signature indices remain in the frame glue; the opcode-free policy receives only the
canonical signers resolved from the entries that the signed VERIFY calldata selected.

The frame glue reads the selected entries with `sigparam`, inspects frames with
`frameparam`, and approves with `approvetx`. It is exercised against a real EVM by the
account tests in `test/`.

All Solidity account examples implement the common
`IFrameAccount.validate(uint256[] signatureIndices)` entry point (selector
`0x25b90494`). A VERIFY frame passes the indices assigned to that account instead of making
every account scan the whole signature envelope. The frame data is covered by every
canonical transaction signature, so the selected-index routing cannot be changed without
invalidating those signatures. Each example also derives `allowed_scope` from the current
frame: `BOTH` when it validates and pays for itself, `EXECUTION` when an external paymaster
pays, and `PAYMENT` when it acts as the payer for another already-approved sender.

The last role works at the EVM level and through private inclusion, but these examples read
account policy from storage. When such an account pays for a different `tx.sender`, those
reads are outside the sender's storage and therefore fail the public-mempool validation
rule. A public-pool paymaster needs a policy compatible with that rule, such as the
immutable-backed sponsoring example.

Separating an authorisation policy from its entrypoint is how you would write this anyway;
the stock-tooling boundary just happens to fall in the same place.

## Reusable conformance suites

New account tests should inherit
[`AccountTestSuite`](test/AccountTestSuite.sol). Deploy and initialize the subject in
`setUp()`, then implement only:

```solidity
function accountUnderTest() internal view returns (address);
function accountAuthorizationSignatures()
    internal view
    returns (IFrameVm.FrameTxSignature[] memory);
```

The inherited tests shift valid authorization entries away from signature zero and verify
all three account roles: self-validation plus payment (`BOTH`), validation with a later
paymaster (`EXECUTION`), and payment for another sender (`PAYMENT`). They also prove that
unselected valid signatures are ignored, that the exact scope is approved, and that the
account accepts ordinary ETH funding. The default distractors avoid the signers returned by
the positive hook; a policy with other trusted keys or proof types overrides
`accountUnauthorizedSignatures()`. Account-specific policy tests remain in the concrete test
contract. The three `accountSuite*` address hooks may also be overridden if a subject uses a
default fixture address.

New paymaster tests should inherit
[`PaymasterTestSuite`](test/PaymasterTestSuite.sol) and provide the deployed target, its
trusted protocol signatures, calldata selecting their signature indices, and an accepted
max-cost fixture through `_paymasterUnderTest()`, `_paymasterTestSignatures()`,
`_paymasterTestCall(uint256[])`, and `_paymasterTestMaxCost()`. Its shared, shifted signature
envelope tests that the paymaster sponsors `OwnerAccount`, `MultisigAccount`,
`SessionKeyAccount`, and both minimal Yul runtimes, while refusing a misrouted paymaster
index. A paymaster that does not use signature entries returns an empty array; an allowlist
or proof policy can override `_preparePaymasterForAccount(address)` for per-sender setup.
The `_paymasterSuite*` address hooks avoid collisions with a paymaster that reserves a
default fixture address.
These are opcode-level approval tests; end-to-end ETH charging and refunds still belong in
transaction-level Anvil tests.

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
