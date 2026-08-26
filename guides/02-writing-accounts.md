# Writing EIP-8141 accounts

## The one idea to internalise

**The protocol verifies signatures before any of your code runs, but your account must check
what each signature signed.**

Every `SECP256K1`/`P256` entry is checked before frame execution. An entry with empty `msg`
is checked against the
canonical transaction signature hash; an entry with a 32-byte `msg` is checked against that
explicit digest. Both are protocol-valid. Only the empty-`msg` case necessarily commits to
this transaction's frame list.

An account using those native schemes does not repeat cryptographic verification. An account
using an `ARBITRARY` entry must verify that entry's witness itself; WebAuthn is the
toolkit's concrete example. Ordinary accounts use `validate(uint256 signatureIndex)`
(selector `0xce4d01a3`): the VERIFY frame supplies exactly one signature entry assigned to
that account. Only a
multisig policy uses `validate(uint256[] signatureIndices)` (selector `0x25b90494`) to
aggregate several entries. Because frame calldata is part of `compute_sig_hash(tx)`,
canonical signatures commit to either routing form along with the rest of the transaction.

The account asks *which selected key signed*, requires that the entry signed this
transaction, and then decides whether it trusts that key:

```solidity
function validate(uint256 signatureIndex) external {
    if (FrameTxLib.sigScheme(signatureIndex) == FrameTxLib.SCHEME_ARBITRARY) revert();
    if (!FrameTxLib.signedThisTx(signatureIndex)) revert();
    if (FrameTxLib.sigSigner(signatureIndex) != owner) revert();

    uint256 scope = FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex());
    if (scope == FrameTxLib.SCOPE_NONE) revert();
    FrameTxLib.approve(scope);
}
```

That is the whole policy path for a single-owner account. Omitting the `0x02` check
would let a valid owner signature over an unrelated explicit digest authorize replaceable
`SENDER` frames. Compare with ERC-4337, where the account also parses a signature blob and
runs `ecrecover` itself.

## Native P256 versus WebAuthn

These are two different signature paths even though both ultimately use the P256 curve:

| | Native P256 | WebAuthn |
|---|---|---|
| Transaction scheme | `P256` (`0x02`) | `ARBITRARY` (`0x00`) |
| Raw entry | `r || s || qx || qy` | Canonical ABI assertion witness |
| Pre-frame work | Protocol verifies the signature and derives a signer | Protocol only performs structural checks |
| Contract-visible evidence | Scheme, resolved signer, and whether `msg` is empty | Scheme, `msg`, witness length, and witness bytes |
| Account check | Trust the selected `keccak256(qx || qy)[12:]` signer | Reconstruct WebAuthn data and call P256VERIFY at `0x100` |

A native P256 entry's raw signature is deliberately opaque to EVM code. Its signer identity
is `address(uint160(uint256(keccak256(qx || qy))))`, and accounts should still require an
empty `msg` so the signature covers the canonical frame transaction. A WebAuthn authenticator
does not sign that hash directly. Put its assertion in an empty-`msg` `ARBITRARY` entry with
an empty signer field, use the canonical transaction hash as the base64url challenge, and
verify the witness in the account. The exact 2 KiB-bounded ABI, client-data JSON,
authenticator flags, constructors, and deliberate omissions are specified in
[`contracts/docs/09-p256-and-webauthn.md`](../contracts/docs/09-p256-and-webauthn.md).

P256 contracts require scheme `0x02`, and WebAuthn contracts require their exact
scheme-`0x00` assertion.

[`FrameKernel`](../contracts/src/accounts/FrameKernel.sol) supports both paths behind the
same `validate(uint256)` entry point. Its native secp256k1 and P256 authorities use the
protocol metadata directly. Its passkey witness remains an empty-`msg` `ARBITRARY` entry,
but contains a real WebAuthn P256 signature. The compact witness omits challenge-dependent
client JSON: the kernel reconstructs the canonical JSON from `TXPARAM(0x08)` and the
credential's configured origin before calling P256VERIFY. This keeps P256 as the actual
cryptography without putting self-referential assertion bytes in signed frame calldata.

## Post-quantum signatures use `ARBITRARY`

EIP-8141 reserves schemes `0x03` through `0xff`; this toolkit does not assign one to
ML-DSA. An ML-DSA experiment must carry its application-defined proof material in an
`ARBITRARY` (`0x00`) entry with an empty `signer`. Validation-frame or custom-verifier code
copies the bytes with `SIGDATACOPY`, verifies them, binds the result to the canonical
transaction signature hash and the account's key policy, and only then calls `APPROVE`.

The toolkit currently ships no ML-DSA witness ABI, verifier, account, or paymaster. Gas and
public-mempool eligibility therefore depend on the verifier an application eventually
implements; no native verification charge or signer identity exists. See
[`contracts/docs/10-pq.md`](../contracts/docs/10-pq.md).

## The opcodes

Stack is listed **top first**, matching the spec's tables and the order you write arguments
in Yul. `APPROVE` through `SIGDATACOPY` are the pinned upstream EIP-8141 surface.
The `0xb6`-`0xb9` rows are the toolkit's non-normative tooling-fixture profile, not additions
to the transaction encoding in the normative spec body.

| Opcode | Byte | Builtin | Stack | Returns |
|---|---|---|---|---|
| `APPROVE` | `0xaa` | **`approvetx`** | offset, length, scope | — (exits the frame) |
| `TXPARAM` | `0xb0` | `txparam` | param | value |
| `FRAMEDATALOAD` | `0xb1` | `framedataload` | offset, frameIndex | word |
| `FRAMEDATACOPY` | `0xb2` | `framedatacopy` | memOffset, dataOffset, length, frameIndex | — |
| `FRAMEPARAM` | `0xb3` | `frameparam` | frameIndex, param | value |
| `SIGPARAM` | `0xb4` | `sigparam` | signatureIndex, param | value |
| `SIGDATACOPY` | `0xb5` | `sigdatacopy` | memOffset, dataOffset, length, signatureIndex | — |
| `RECENTROOTREFLOAD` | `0xb6` | `recentrootrefload` | field, referenceIndex | value |
| `TXTRACE` | `0xb7` | `txtrace` | index, param | value |
| `TXDIFF` | `0xb8` | `txdiff` | param, address, in3 | value |
| `EVENTDATACOPY` | `0xb9` | `eventdatacopy` | eventIndex, memOffset, dataOffset, length | — |

> **`approvetx`, not `approve`.** The spec calls the opcode `APPROVE`, but `approve` is the
> ERC-20 method name and appears in a large share of deployed Solidity. Reserving it as a
> builtin would break existing contracts, so this fork spells it `approvetx`. The opcode
> byte `0xaa` is unchanged. `approve` remains free for your own functions and variables.

### Parameter tables

Normative `TXPARAM`: `0x00` tx type · `0x01` scalar wire `nonce` · `0x02` sender ·
`0x03`-`0x05` `fees` fields · `0x06` max cost · `0x07` blob count · `0x08` **canonical
signature hash** · `0x09` frame count · `0x0A` current frame index · `0x0B` signature
count · `0x0C` state gas left in the current frame. All other selectors are undefined and
exceptional-halt.

`FRAMEPARAM`: `0x00` resolved_target · `0x01` limits.execution · `0x02` mode · `0x03`
flags · `0x04` len(data) · `0x05` status (halts for the current or a later frame) · `0x06`
allowed_scope · `0x07` atomic_batch · `0x08` value · `0x09` limits.state · `0x0A`
gas_used.execution and `0x0B` gas_used.state (both halt for the current or a later frame).
Modes `0`-`2` are the normative `DEFAULT`, `VERIFY`, and `SENDER` values; mode `3`
(`POST_TX`) exists only in the fixture profile described below.

`SIGPARAM`: `0x00` resolved_signer · `0x01` scheme · `0x02` msg · `0x03` len(signature)
(ARBITRARY entries only; protocol-validated schemes halt).

`SIGDATACOPY` reads only `ARBITRARY` signature bytes. It zero-fills past the end like
`CALLDATACOPY` and exceptional-halts for protocol-validated schemes. On **stock** solc,
standalone Yul can emit it as
`verbatim_4i_0o(hex"b5", memOffset, dataOffset, length, sigIdx)`.

The rest of this subsection describes only the non-normative fixture profile.

`RECENTROOTREFLOAD`: `0x00` source id · `0x01` consensus slot · `0x02` opaque root. It costs
3 gas. An undefined field or out-of-bounds supplied reference index exceptional-halts. The
fixture does not verify roots or define their wire encoding.

`TXTRACE` costs a provisional flat 100 gas and is valid only in the current `POST_TX` frame
(`mode == 3`). Its `index` is a global index into the relevant supplied trace vector:

| Param | Result |
|---|---|
| `0x00` | Balance-diff count (`index` must be zero) |
| `0x01` | Storage-diff count (`index` must be zero) |
| `0x02` | Deployed-contract count (`index` must be zero) |
| `0x03` / `0x04` / `0x05` | Balance entry account / before / after |
| `0x06` / `0x07` / `0x08` / `0x09` | Storage entry account / key / before / after |
| `0x0A` / `0x0B` | Deployed account / current code hash |
| `0x0C` | Event count (`index` must be zero) |
| `0x0D` / `0x0E` | Event emitter / topic count |
| `0x0F` / `0x10` / `0x11` / `0x12` | Event topic 0 / 1 / 2 / 3 |
| `0x13` | Event data length |
| `0x14` / `0x15` | Gas pre-charge / gas payer (`index` must be zero) |

`TXDIFF` is also `POST_TX`-only. Its provisional 100 gas is the warm total. Direct storage,
balance, and code-hash selectors access live host state on both supplied-diff hits and misses;
only the applicable EIP-2929 cold premium is added when that access is cold. The address-local
count selectors require `in3 == 0`; the index selectors take an address-local index and return
its global `TXTRACE` index:

| Param | `in3` | Result |
|---|---|---|
| `0x00` / `0x01` | Storage key | Storage value before / after |
| `0x02` / `0x03` | Zero | Account balance before / after |
| `0x04` / `0x05` | Zero | Account code hash before / after |
| `0x06` | Zero | Storage-diff count for address |
| `0x07` | Local storage index | Global storage-diff index |
| `0x08` | Zero | Event count for emitter |
| `0x09` | Local event index | Global event index |
| `0x0A` | Zero | Change flags: nonce `0x1`, balance `0x2`, storage `0x4`, code hash `0x8` |

`EVENTDATACOPY` is `POST_TX`-only. It costs 3 plus 3 per copied word and memory expansion,
and has strict source bounds: `dataOffset + length` must not exceed the selected event's data
length. It exceptional-halts instead of zero-filling an overrun.

On stock solc, standalone Yul can emit the four fixture-profile opcodes as
`verbatim_2i_1o(hex"b6", field, referenceIndex)`,
`verbatim_2i_1o(hex"b7", index, param)`,
`verbatim_3i_1o(hex"b8", param, account, in3)` and
`verbatim_4i_0o(hex"b9", eventIndex, memOffset, dataOffset, length)`.

Rather than remembering operand orders, Solidity accounts can use
[`contracts/src/frame/FrameTxLib.sol`](../contracts/src/frame/FrameTxLib.sol), which wraps
every defined introspection selector, all copy opcodes and `APPROVE` in typed internal
functions — see
[contracts/docs/07](../contracts/docs/07-frametx-library.md).

## APPROVE scopes

| Scope | Meaning | Requires |
|---|---|---|
| `0x0` | nothing | — |
| `0x1` | PAYMENT | `sender_approved` already true; payer holds `max_cost` |
| `0x2` | EXECUTION | `resolved_target == tx.sender` |
| `0x3` | both | `resolved_target == tx.sender`; holds `max_cost` |

The requested scope must be a **subset** of the frame's `flags & 0x3`, or `APPROVE` reverts.
Setting flags to `0x3` and calling `approvetx(0, 0, 1)` is fine; the reverse is not.

A reusable account should normally read `FRAMEPARAM(TXPARAM(0x0A), 0x06)` and approve that
current `allowed_scope`, rejecting zero. The same validation code can then fill three roles:

| Account role | Frame target | Allowed scope | Result |
|---|---|---|---|
| Validate and pay for itself | `tx.sender` | `0x3` (`BOTH`) | Grants execution and supplies ETH |
| Validate with an external paymaster | `tx.sender` | `0x2` (`EXECUTION`) | Grants execution; a later pay frame supplies ETH |
| Sponsor another account (payment only) | the sponsor account, not `tx.sender` | `0x1` (`PAYMENT`) | Supplies ETH after the sender has already approved execution |

The last row is the account sponsor-only role. It calls the account's normal validation
entry point in a PAYMENT-only frame; the account is not `tx.sender` and receives no execution
authority. A dedicated paymaster contract is optional, not required. Paymasters remain useful
when sponsorship needs a separate key, cost cap, funding pool, withdrawal policy, or service
boundary.

The last row is valid EVM behavior and can be directly or privately included. If the payer's
validation reads its owner, threshold, session keys, or other policy from storage, however,
those reads are outside `tx.sender` and the transaction is not eligible for the public
mempool under the generic validation rules. This includes `P256Account`, whose rotatable
signer lives in storage. `WebAuthnAccount` keeps its credential policy in immutable code and
can avoid that specific third-party-storage read, but a separate coded pay target is still a
non-canonical paymaster: it remains subject to the draft's one-pending-transaction cap and
the generic validation and opcode rules.

The protocol-supplied **empty-code** account is narrower than these coded policies: it
remains secp256k1-only. A codeless secp256k1 owner may put its canonical entry at index `1`,
let a `MultisigAccount` count that same entry for execution, and let a later PAYMENT-only
frame against the owner reuse it through default code. That is one signature entry, not two.
An account using an `ARBITRARY` post-quantum witness needs compatible account code or
delegation to act as payer.

## Constraints that will bite you

**A VERIFY frame is a STATICCALL.** Ordinary account validation cannot use `SSTORE`,
`TSTORE`, logs, or state-changing calls; `APPROVE` is the protocol-defined exception. The
current public-prefix rules separately permit `SSTORE` to `tx.sender` inside the first
`deploy` frame, but that narrow deployment exception is not scratch storage for a deployed
validator. Validation that wants mutable scratch state has to be restructured — the multisig
example works around exactly this.

**A reverting VERIFY frame invalidates the entire transaction**, not just that frame. There
is no partial success and no receipt to inspect.

**`sender_approved` is transaction-scoped, not per-frame.** Once granted, *every* subsequent
`SENDER` frame runs as `tx.sender` — not just the one the validator looked at. A validator
that approves without committing to the full frame list authorises an open-ended set of
calls. The accounts in this toolkit require the canonical signature hash, which covers the
whole frame list. The session-key example additionally walks every frame to impose a narrower
target/selector/value policy.

**Treat `signatureIndex` as signed routing, not as trusted authentication by itself.**
An ordinary address-policy account must still reject an out-of-range index through normal
failure, require the canonical-hash case, and apply its key policy. It need not whitelist
native schemes before requesting a resolved signer: the protocol already verified them,
while `ARBITRARY` has no resolved signer and fails closed. Exact-algorithm, raw-witness, and
skip-unsupported policies still inspect the scheme. Receiving one index means that one entry
must authorize or validation must fail. Only a multisig should accept an index array and loop
over selected entries.

**A function calling `approvetx` cannot be `view`.** It changes state: it bumps the sender's
nonce, sets the payer and collects `max_cost`. Functions using only the introspection
opcodes cannot be `pure` but can be `view`.

## Compiling

```bash
solidity/build/solc/solc --experimental --evm-version @future --bin-runtime --optimize Account.sol
```

The toolkit's Foundry fork executes `@future` as the pre-Amsterdam **Osaka** EVM. This is
intentional: Osaka activates [EIP-7951](https://eips.ethereum.org/EIPS/eip-7951)'s
P256VERIFY precompile at `0x100`, while Amsterdam's node-level state-gas behavior is not
compatible with the current frame profile. A patched Anvil must likewise use
`--hardfork osaka --enable-frame-transactions` when executing a WebAuthn validator. There is
not yet an Anvil WebAuthn end-to-end test in this repository. The native-P256 Anvil regression
does submit a raw type-`0x06` transaction through `P256Account`, including a corrupted-key
admission negative and mined payer, nonce, and SENDER-effect assertions.

> `verbatim` is **not** available inside Solidity `assembly {}` blocks on any solc, stock or
> forked. Solidity account code using Frame opcodes therefore needs the patched compiler's
> named builtins.

## Testing an account

Accounts are tested with patched Forge against the real opcodes. Inherit
[`contracts/test/AccountTestSuite.sol`](../contracts/test/AccountTestSuite.sol), deploy and
initialize the subject in `setUp`, and implement its two hooks:

```solidity
contract MyAccountTest is AccountTestSuite {
    address constant ACCOUNT = address(0xACC0);
    address constant OWNER = address(0x0BEEF);

    function setUp() public {
        deployAccount("MyAccount", ACCOUNT);   // etches the compiled runtime
        vm.store(ACCOUNT, bytes32(0), bytes32(uint256(uint160(OWNER))));
    }

    function accountUnderTest() internal pure override returns (address) {
        return ACCOUNT;
    }

    function accountAuthorizationSignatures()
        internal
        pure
        override
        returns (IFrameVm.FrameTxSignature[] memory signatures)
    {
        signatures = new IFrameVm.FrameTxSignature[](1);
        signatures[0] = secpSig(OWNER);
    }
}
```

The inherited suite supplies shifted, non-zero signature indices and proves:

- validation and payment for the account itself (`BOTH`);
- validation while a later paymaster pays (`EXECUTION`);
- payment for another already-approved sender (`PAYMENT`);
- exact-scope approval and rejection when no scope is permitted;
- rejection when valid account signatures exist but are not selected;
- rejection of wrong secp256k1 and P256 signatures;
- rejection when the selected authorization is a malformed `ARBITRARY` signature; and
- an ordinary empty-calldata ETH funding path.

Keep policy-specific positive and negative cases in the concrete test. The suite inherits
`FrameTest`, whose `vm.setFrameTx` fixture installs transaction context while patched revm
executes the actual account bytecode and frame opcodes. If the account trusts additional
keys or proof forms not represented by `accountAuthorizationSignatures()`, override
`accountUnauthorizedSignatures()` so the routing-negative receives entries that policy is
guaranteed to reject. Override the `accountSuite*` address hooks as well if the subject uses
one of the suite's default fixture addresses. An `ARBITRARY` proof whose witness commits to
the canonical signature hash can also override `accountSuiteSigHash()`; the WebAuthn test
does so to build its assertion challenge.

Paymasters have the parallel
[`contracts/test/PaymasterTestSuite.sol`](../contracts/test/PaymasterTestSuite.sol). A
concrete paymaster test supplies `_paymasterUnderTest()`, `_paymasterTestSignature()`,
`_paymasterTestCall(uint256)`, and `_paymasterTestMaxCost()`. The inherited matrix uses one
shared, shifted signature envelope to require sponsorship of all configured targets:
`OwnerAccount`, `MultisigAccount`, `SessionKeyAccount` through its owner, `P256Account`,
`FrameKernel` through native P256, `WebAuthnAccount`, the migrated Kernel
v3.3 proxy, and the EIP-7702-delegated EOA, plus refusal of a misrouted paymaster index. The
matrix also refuses wrong secp256k1 and P256 sponsor signatures and a selected malformed
`ARBITRARY` sponsor signature. The secp256k1, P256, and WebAuthn paymaster tests all inherit
this matrix.

Sender-specific signature policies can override `_preparePaymasterForAccount(address)`.
A proof-only or allowlist-only paymaster needs a policy-specific suite because this shared
suite deliberately proves scalar signature-index routing.

Paymasters that reserve a default fixture address can override the `_paymasterSuite*`
address hooks.

These suites execute real bytecode and frame opcodes, but their `setFrameTx` transaction
context is synthetic. They do not test type-`0x06` admission, nonce changes, or eventual ETH
debits and refunds. Native P256 cases trust host-supplied, already-verified metadata rather
than a raw envelope signature. WebAuthn cases create a real P256 assertion and invoke
precompile `0x100`, but their challenge is the synthetic fixture's signature hash.
A raw Anvil case pins index-1 multisig-owner payer reuse. WebAuthn remains without a raw
end-to-end case, and no ML-DSA verifier or transaction path is shipped.

> [!warning] Always include a positive case
> `assertRefuses` passes if the call fails for *any* reason, including the account never
> being deployed. The reusable suites provide positive inherited cases; any standalone test
> must likewise contain at least one successful approval proving its setup is real.

## Reproducible bytecode

The generated examples compile with `--no-cbor-metadata`. Without it solc appends a CBOR
trailer containing compiler/source metadata; changing the compiler build or source then
changes that trailer as well as any changed code. Removing it makes each documented size
refer only to executable runtime bytecode:

```bash
solc --experimental --evm-version @future --bin-runtime --optimize --no-cbor-metadata Account.sol
```

For deployment you generally *want* metadata. Byte-count claims in these docs refer to
metadata-free builds (`--no-cbor-metadata`) so bytecode comparisons have one unambiguous
meaning; no current artifact-size claim includes a CBOR trailer.
