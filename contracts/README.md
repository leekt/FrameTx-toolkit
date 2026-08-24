# Foundry project

The toolkit's patched Foundry both compiles and executes frame contracts: the default
profile drives the patched solc at the experimental `@future` EVM version, so `forge build`
and `forge test` cover the whole project. The Foundry fork maps `@future` to the
pre-Amsterdam **Osaka** EVM: this keeps the frame profile away from Amsterdam's incompatible
node-level state-gas rules while activating the [EIP-7951 P256VERIFY
precompile](https://eips.ethereum.org/EIPS/eip-7951) at `0x100` for WebAuthn verification.
All Solidity packages are declared in `foundry.toml`, locked by `soldeer.lock`, and restored
to the ignored `dependencies/` directory with `forge soldeer install`.

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
the `setFrameTx` cheatcode. That cheatcode copies host-supplied recent roots, POST_TX traces,
diffs, and events; it does not make them normative transaction data. This is real opcode
execution, not a Solidity mock.

## The policy/glue split, and why it is good design

EIP-8141 hands the account a much smaller job than ERC-4337 does. Before any frame runs, the
protocol verifies every `SECP256K1`/native `P256` signature against either the canonical
transaction hash or its explicit digest, so accounts using those schemes do not repeat
cryptography. What remains is a **policy**
question: which keys signed the canonical transaction hash, and should those keys approve
the frames about to execute? `ARBITRARY` entries are the
deliberate exception: their witness is contract-verified. `WebAuthnAccount` uses
`SIGDATACOPY`, SHA-256, and P256VERIFY because a WebAuthn authenticator signs structured
WebAuthn data rather than the transaction hash directly.

That policy is ordinary Solidity, and it is where the bugs are — threshold
counting, duplicate signers, session-key expiry, target allowlists, selector
extraction. `src/policy/FrameAccountPolicy.sol` holds it, and `forge test` covers it
including fuzz runs; it stays compilable by stock tooling through the `policy` profile.
Signature indices remain in the frame glue; the opcode-free policy receives only the
canonical signers resolved from the entry, or multisig entries, that the signed VERIFY
calldata selected.

The frame glue reads the selected entries with `sigparam`, inspects frames with
`frameparam`, and approves with `approvetx`. It is exercised against a real EVM by the
account tests in `test/`.

The ordinary Solidity accounts implement
`IFrameAccount.validate(uint256 signatureIndex)` (selector `0xce4d01a3`). Their VERIFY frame
passes exactly one assigned entry instead of
making the account scan the signature envelope. `MultisigAccount` implements the separate
`IMultisigFrameAccount.validate(uint256[] signatureIndices)` entry point (selector
`0x25b90494`) because its threshold policy genuinely aggregates entries. Every current
paymaster uses `sponsorTransaction(uint256)` (selector `0x217de4d8`). Frame data is covered
by every canonical transaction signature, so none of this selected-index routing can be
changed without invalidating those signatures. Each account also derives `allowed_scope`
from the current frame: `BOTH` when it validates and pays for itself, `EXECUTION` when an
external paymaster pays, and `PAYMENT` when it acts as the payer for another already-approved
sender. That last layout is the account's sponsor-only role: it uses the normal account
validation entry point, grants no execution authority to the sponsor, and requires no
dedicated paymaster contract. The paymaster examples remain useful specialized alternatives
with sponsor-specific keys, cost caps, funding, and withdrawal policy.

The generic `OwnerAccount` and `SessionKeyAccount` accept any protocol-validated scheme when
its resolved identity matches their configured address. `MultisigAccount` explicitly admits
secp256k1 and P256 identities in one threshold. The dedicated `P256*`, `WebAuthn*`, and
secp256k1 sponsoring contracts remain exact-algorithm policies.

Default empty-code accounts are a separate protocol policy and remain secp256k1-only. A
secp256k1 owner entry at index 1 can count in a multisig's execution selection and be reused
by that same owner's later default PAYMENT frame, with no second signature. An `ARBITRARY`
post-quantum witness cannot use this empty-code payer path without compatible code or delegation.

The last role always works at the EVM level and through direct or private inclusion. Most
examples, including the rotatable `P256Account`, read policy from storage. When such an
account pays for a different `tx.sender`, those reads are outside the sender's storage and
therefore fail the public-mempool validation rule. `WebAuthnAccount` embeds its credential
configuration in immutable code and can avoid that particular trace violation, but as a
separate pay target it is still a non-canonical paymaster: the draft's one-pending-transaction
cap and all generic validation and opcode rules apply.

Separating an authorisation policy from its entrypoint is how you would write this anyway;
the stock-tooling boundary just happens to fall in the same place.

## Account and paymaster examples

The reusable paymaster matrix includes the account examples and both migration adapters.

| Account | Authorization path | Mutable validation policy? |
|---|---|---|
| `OwnerAccount` | Selected supported native signer | Owner in storage |
| `MultisigAccount` | Threshold over selected native signers | Owners and threshold in storage |
| `SessionKeyAccount` | Owner or frame-constrained session key | Policy in storage |
| `P256Account` | Selected protocol-verified native P256 signer | Rotatable signer in storage |
| `WebAuthnAccount` | One selected, contract-verified `ARBITRARY` assertion | Immutable credential configuration |
| [`KernelV33FrameAccount`](src/accounts/KernelV33FrameAccount.sol) | Existing, unhooked Kernel v3.3 ECDSA root after a same-address proxy upgrade | Existing Kernel/validator storage; the 1,014-byte compatibility shim adds no storage, rejects hooked roots, and delegates the complete legacy surface to the exact prior implementation |
| [`EOA7702FrameAccount`](src/accounts/EOA7702FrameAccount.sol) | Existing EOA secp256k1 identity through EIP-7702 delegation | No adapter storage; EOA remains the authority |

| Paymaster | Authorization path | Public-pool classification |
|---|---|---|
| `SponsoringPaymaster` | Native secp256k1 sponsor signer | Non-canonical |
| `P256Paymaster` | Native P256 sponsor signer | Non-canonical |
| `WebAuthnPaymaster` | Strict WebAuthn assertion | Non-canonical |

The P256 and WebAuthn constructors, transaction entries, exact WebAuthn witness format, and
security boundaries are documented in
[`docs/09-p256-and-webauthn.md`](docs/09-p256-and-webauthn.md).
The post-quantum integration boundary, including the required `ARBITRARY` witness path and
the absence of a shipped ML-DSA verifier, account, or paymaster, is documented in
[`docs/10-pq.md`](docs/10-pq.md).
The production migration adapters, official Kernel pin, legacy execution coverage, and
rollback boundaries are documented in [`../guides/05-migration.md`](../guides/05-migration.md#executable-migration-examples).

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
trusted protocol signature, calldata selecting its authorization index, and an accepted
max-cost fixture through `_paymasterUnderTest()`, `_paymasterTestSignature()`,
`_paymasterTestCall(uint256)`, and `_paymasterTestMaxCost()`. Its shared, shifted signature
envelope tests that the paymaster sponsors `OwnerAccount`, `MultisigAccount`,
`SessionKeyAccount` through its owner, `P256Account`, `WebAuthnAccount`, the migrated Kernel
v3.3 proxy, and the EIP-7702-delegated
EOA, while refusing a misrouted paymaster index.
`SponsoringPaymasterTest`, `P256PaymasterTest`, and `WebAuthnPaymasterTest` all inherit this
matrix.
Sender-specific signature policies can override `_preparePaymasterForAccount(address)` for
per-sender setup. A paymaster authorized without a signature entry needs a policy-specific
suite because this shared suite deliberately proves single-index signature routing.
The `_paymasterSuite*` address hooks avoid collisions with a paymaster that reserves a
default fixture address.
These are opcode-level approval tests under synthetic `setFrameTx` context; they do not prove
wire admission, nonce transitions, or eventual ETH charging and refunds. Native P256 entries
are already-verified metadata fixtures. WebAuthn tests execute a
real P256 assertion through precompile `0x100`, but the assertion challenge is still a
synthetic transaction hash. No Anvil WebAuthn end-to-end test is claimed, and no ML-DSA
verifier or transaction path is shipped. The Anvil suite submits a raw native-P256 envelope
and proves the secp256k1 multisig-owner/index-1 default-payer reuse layout.

## Usage

```bash
../foundry/target/release/forge soldeer install
../foundry/target/release/forge test --allow-local-compiler       # policy + frame semantics
../foundry/target/release/forge test --allow-local-compiler -vvv  # with traces
../foundry/target/release/forge fmt           # formats src/ and test/
```

`--allow-local-compiler` explicitly trusts the path-based solc configured in
`foundry.toml`; build that executable from the repository's pinned Solidity submodule first.

Artifacts are metadata-free (`cbor_metadata = false`, `bytecode_hash = "none"`), so the
byte counts quoted in [`docs/`](docs/) refer to executable runtime code with no CBOR
trailer. Solar-based linting is disabled (`lint_on_build = false`): forge's native Solidity
frontend does not know the fork's builtins; the patched solc is the only frontend that
understands this dialect.

The root gitlinks and Foundry lockfile record the exact published compiler and VM commits; see
[VERSIONS.md](../VERSIONS.md#reproducibility-status).
