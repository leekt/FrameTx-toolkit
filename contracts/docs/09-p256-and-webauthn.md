# Native P256 and WebAuthn

The toolkit supports two P256-backed authorization paths, with deliberately different trust
boundaries:

| | Native P256 | WebAuthn |
|---|---|---|
| EIP-8141 scheme | `P256` (`0x02`) | `ARBITRARY` (`0x00`) |
| Raw signature field | `r || s || qx || qy`, four 32-byte values | Canonical ABI assertion witness described below |
| Before frame execution | The protocol verifies P256 and resolves the signer | The protocol only checks the entry's structure |
| Visible to account code | Scheme, resolved signer, and `msg` metadata | Scheme, `msg`, length, and all witness bytes |
| P256 verification | Outside EVM frame execution | In the VERIFY frame through precompile `0x100` |

The native path is the simpler policy primitive. WebAuthn needs the `ARBITRARY` path because
an authenticator signs `authenticatorData || SHA-256(clientDataJSON)`, not the EIP-8141
transaction hash directly. Its client-data challenge carries that transaction hash instead.
`P256Account`/`P256Paymaster` still require exactly scheme `0x02`, while
`WebAuthnAccount`/`WebAuthnPaymaster` still require exactly their scheme-`0x00` assertion
profile. Post-quantum experiments likewise need `ARBITRARY` witness validation; see
[`10-pq.md`](10-pq.md).
See the local [EIP-8141 implementation profile](../../spec/EIP8141.md) and the primary
[EIP-8141](https://eips.ethereum.org/EIPS/eip-8141),
[EIP-7951](https://eips.ethereum.org/EIPS/eip-7951), and
[WebAuthn Level 3](https://www.w3.org/TR/webauthn-3/) documents for the underlying formats.

## Native P256 entries

A canonical native entry has:

| Entry field | Required value |
|---|---|
| `scheme` | `0x02` (`P256`) |
| `signer` | The 20-byte identity `keccak256(qx || qy)[12:]`, unless that identity is supplied implicitly as `tx.sender` |
| `msg` | Empty when authorizing the frame transaction |
| `signature` | `r || s || qx || qy`, exactly 128 bytes |

The protocol enforces the curve signature, low-`s` form, public-key validity, and equality
between the resolved signer and `keccak256(qx || qy)[12:]` before any frame runs. Raw bytes
for a protocol-validated entry are intentionally unavailable through `SIGDATACOPY`; account
code examines only its metadata. An explicit 32-byte `msg` can be a valid P256 signature,
but it does not authorize the replaceable frame list and these accounts reject it.

### `P256Account`

[`P256Account.sol`](../src/accounts/P256Account.sol) is a rotatable, single-key account.

| API | Behavior |
|---|---|
| `constructor(bytes32 qx, bytes32 qy)` | Rejects the all-zero pair and stores only the derived signer address |
| `validate(uint256 signatureIndex)` | Requires the selected entry to be a canonical native P256 signature from the stored signer, then approves the current allowed scope |
| `setP256Key(bytes32 qx, bytes32 qy)` | Rotates the signer; callable only when `msg.sender == address(this)`, as in a SENDER self-call |
| `p256Signer()` | Returns the current stored signer identity |
| `signerForKey(bytes32 qx, bytes32 qy)` | Returns the toolkit's `keccak256(qx || qy)[12:]` identity |
| `receive()` | Accepts ETH for self-payment or payment on behalf of another sender |

The constructor and rotation method reject only an all-zero pair; the protocol verifies that
a key carried by an actual native P256 signature is a valid curve point. Because
`validate` reads the rotatable signer from storage, using this account to pay for a different
`tx.sender` is an EVM/private-inclusion capability, not a public-mempool-compatible trace.

### `P256Paymaster`

[`P256Paymaster.sol`](../src/accounts/P256Paymaster.sol) has immutable `owner`,
`sponsorSigner`, and `maxSponsoredCost` values.

| API | Behavior |
|---|---|
| `constructor(bytes32 sponsorQx, bytes32 sponsorQy, uint256 maxSponsoredCost)` | Derives the immutable sponsor identity, records the deployment caller as owner, and can receive initial ETH |
| `sponsorTransaction(uint256 signatureIndex)` | Requires the selected entry to be a canonical native P256 signature from the sponsor, enforces the cost cap and exact `PAYMENT` scope, then approves payment |
| `withdraw(address payable to, uint256 amount)` | Owner-only withdrawal |
| `receive()` | Accepts sponsorship funding |

The signer is not rotatable. This runtime is not the draft's canonical paymaster runtime, so
the non-canonical paymaster rules apply.

## WebAuthn transaction entry

Both [`WebAuthnAccount.sol`](../src/accounts/WebAuthnAccount.sol) and
[`WebAuthnPaymaster.sol`](../src/accounts/WebAuthnPaymaster.sol) receive one selected
signature index directly. That entry must be:

| Entry field | Required value |
|---|---|
| `scheme` | `0x00` (`ARBITRARY`) |
| `signer` | Empty, as required for every `ARBITRARY` entry |
| `msg` | Empty, selecting the canonical EIP-8141 transaction signature hash |
| `signature` | The exact assertion witness below |

The raw witness of an empty-`msg` entry is elided while the canonical transaction signature
hash is computed. The VERIFY frame calldata, including the selected index, remains in that
hash. The account copies the chosen witness with `SIGDATACOPY`, reconstructs the WebAuthn
signed data, and treats the canonical transaction signature hash as the WebAuthn challenge.

## Exact assertion witness

The witness is exactly:

```solidity
abi.encode(
    bytes32 r,
    bytes32 s,
    bytes authenticatorData,
    bytes clientDataJSON
)
```

It is not a DER signature and it is not a browser's entire assertion object. The complete
encoded witness must be at least 256 bytes and no more than **2,048 bytes**. The decoder
accepts only canonical ABI. Both entrypoints check the `ARBITRARY` entry's reported length
before `SIGDATACOPY`, so an oversized witness is rejected before allocating memory:

| Offset | Word or tail |
|---|---|
| `0x00` | `r` |
| `0x20` | `s` |
| `0x40` | Authenticator-data offset, exactly `0x80` |
| `0x60` | Client-data offset, exactly `0xe0` |
| `0x80` | Authenticator-data length, exactly `37` |
| `0xa0` | First 32 bytes of authenticator data |
| `0xc0` | Final 5 bytes followed by zero padding |
| `0xe0` | Client-data length |
| `0x100` | Client-data bytes followed by zero padding |

The total length must equal `256 + ceil32(clientDataJSON.length)`. A re-encoding hash check
rejects shifted tails, non-zero padding, alternate encodings, and trailing bytes. The
client-data portion can therefore be at most 1,792 bytes, subject to the 2 KiB whole-witness
limit.

### Client adapter: DER to canonical ABI

A browser WebAuthn assertion using ES256 returns its P256 signature as ASN.1 DER. That byte
string cannot be placed directly in this witness. Here `n` is the P256 group order
`0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551`. The client adapter
must:

1. strictly decode one DER `SEQUENCE` containing exactly two minimally encoded, positive
   `INTEGER` values and reject indefinite or non-minimal lengths, negative or non-minimal
   integers, extra elements, and trailing bytes;
2. interpret the integers as `r` and `s`, require `0 < r < n` and `0 < s < n`, and reject
   either value if it does not fit in 32 bytes;
3. if `s > n / 2`, replace it with `n - s`;
4. left-pad each integer to `bytes32`; and
5. produce `abi.encode(bytes32(r), bytes32(s), rawAuthenticatorData, rawClientDataJSON)`.

Use the browser response's raw authenticator-data and client-data byte strings; parsing and
re-serializing the JSON risks changing the exact serialization this profile requires. The
low-`s` conversion does not invalidate ECDSA verification because `(r, n - s)` is the
mathematically equivalent signature.

Native EIP-8141 P256 signers have the same low-`s` responsibility before assembling their
different, fixed 128-byte `r || s || qx || qy` protocol signature. If a signer produces
`s > n / 2`, it must encode `n - s`; the local EIP-8141 profile rejects high-`s` native
entries before frame execution.

### Exact client-data JSON

The only accepted UTF-8 byte serialization is:

```json
{"type":"webauthn.get","challenge":"<challenge>","origin":"<origin>","crossOrigin":false}
```

Here:

- `<challenge>` is the canonical EIP-8141 transaction signature hash encoded as exactly 43
  characters of unpadded base64url;
- `<origin>` is the non-empty, exact byte string whose Keccak-256 hash was configured at
  deployment;
- `type` is exactly `webauthn.get`; and
- `crossOrigin` is exactly `false`.

Whitespace, field reordering, extra keys, duplicate keys, padded or non-canonical challenge
encoding, `crossOrigin: true`, and a `topOrigin` field are rejected. This is intentionally
narrower than the general W3C
[`CollectedClientData`](https://www.w3.org/TR/webauthn-3/#dictdef-collectedclientdata)
model. The contracts compare exact bytes; they do not parse or normalize an origin URL. A
deployer must therefore calculate `originHash = keccak256(bytes(expectedOrigin))` from the
precise origin serialization the client will emit.

### Exact authenticator data

The accepted `authenticatorData` is the common 37-byte assertion form described by the W3C
[authenticator-data structure](https://www.w3.org/TR/webauthn-3/#sctn-authenticator-data):

| Bytes | Meaning | Check |
|---|---|---|
| `0..31` | `rpIdHash` | Must equal the configured `SHA-256(RP ID)` value |
| `32` | Flags | Must satisfy every rule below |
| `33..36` | Big-endian signature counter | Present but not checked or stored |

Flag handling is exact:

| Flag | Mask | Rule |
|---|---:|---|
| User Presence (`UP`) | `0x01` | Always required |
| User Verification (`UV`) | `0x04` | Required when `requireUserVerification` is true; allowed otherwise |
| Backup Eligibility (`BE`) | `0x08` | Allowed |
| Backup State (`BS`) | `0x10` | Allowed only when `BE` is also set |
| Reserved bits 1 and 5 | `0x22` | Must be zero |
| Attested credential data (`AT`) | `0x40` | Must be zero |
| Extension data (`ED`) | `0x80` | Must be zero |

The implementation checks the BE/BS relationship but does not persist backup state. It also
does not enforce monotonic counters; the four counter bytes may be non-zero but are ignored.
The W3C [signature-counter guidance](https://www.w3.org/TR/webauthn-3/#sctn-sign-counter)
explains the clone-detection signal that this initial profile omits.

### Cryptographic check

After the structural and policy checks, the verifier computes:

```text
clientDataHash = SHA-256(clientDataJSON)
digest         = SHA-256(authenticatorData || clientDataHash)
P256VERIFY(digest, r, s, qx, qy)
```

[`P256Verifier.sol`](../src/crypto/P256Verifier.sol) calls EIP-7951 precompile `0x100` with
the 160-byte input `digest || r || s || qx || qy`. EIP-7951 accepts both high- and low-`s`
forms, so the toolkit additionally requires `0 < r < n` and `0 < s <= n / 2`. This rejects
the mathematically equivalent high-`s` replacement and keeps the accepted signature form
canonical. The precompile performs the curve-point and signature verification.

Canonical ABI and low-`s` checks eliminate avoidable alternate encodings of a witness whose
raw bytes are not themselves included in the transaction signature hash. They do not turn
WebAuthn into a native EIP-8141 P256 entry: the trust decision still happens in contract
execution.

## WebAuthn contract APIs

### `WebAuthnAccount`

| API | Behavior |
|---|---|
| `constructor(bytes32 qx, bytes32 qy, bytes32 rpIdHash, bytes32 originHash, bool requireUserVerification)` | Stores all credential policy as immutables; rejects an all-zero key pair or a zero RP/origin hash |
| `validate(uint256 signatureIndex)` | Requires the selected empty-`msg` `ARBITRARY` witness, verifies it against the canonical transaction hash, then approves the current non-zero allowed scope |
| Public immutable getters | Return `publicKeyX`, `publicKeyY`, `rpIdHash`, `originHash`, and `requireUserVerification` |
| `receive()` | Accepts ETH for self-payment or payment on behalf of another sender |

There is no key-rotation API. Deploy a new account to change the credential, RP ID, origin,
or UV policy.

### `WebAuthnPaymaster`

| API | Behavior |
|---|---|
| `constructor(bytes32 qx, bytes32 qy, bytes32 rpIdHash, bytes32 originHash, bool requireUserVerification, uint256 maxSponsoredCost)` | Stores credential policy and cost cap as immutables, records the deployment caller as owner, and can receive initial ETH |
| `sponsorTransaction(uint256 signatureIndex)` | Requires the selected assertion to be valid, enforces the cost cap and exact `PAYMENT` scope, then approves payment |
| Public immutable getters | Return owner, credential policy, and maximum sponsored cost |
| `withdraw(address payable to, uint256 amount)` | Owner-only withdrawal |
| `receive()` | Accepts sponsorship funding |

This is also a non-canonical paymaster.

## Account roles and public-mempool status

Both account implementations derive the current frame's `allowed_scope`, reject zero, and
therefore support all three reusable account roles:

| Role | Scope | `P256Account` | `WebAuthnAccount` |
|---|---:|---|---|
| Validate and pay for itself | `BOTH` (`0x03`) | Supported | Supported |
| Validate while a later paymaster pays | `EXECUTION` (`0x02`) | Supported | Supported |
| Sponsor another already-approved sender (payment only) | `PAYMENT` (`0x01`) | Supported in the EVM and through direct/private inclusion | Supported; immutable validation avoids a third-party SLOAD |

The last WebAuthn cell is not a blanket public-mempool guarantee. When an account with code
is used as a separate pay target, it is a non-canonical paymaster. Under the current draft it
is subject to the one-pending-transaction limit for that payer and to every generic
validation trace, opcode, gas, balance-reservation, and structural rule. The dedicated
`P256Paymaster` and `WebAuthnPaymaster` have the same non-canonical classification, as does
any future post-quantum paymaster.

`P256Account` is stricter: its pay-other validation reads `p256Signer` from storage outside
the different `tx.sender`, which violates the public-pool trace rule. That role is still valid
for direct execution or private inclusion.

## Reusable test coverage

[`AccountTestSuite.sol`](../test/AccountTestSuite.sol) is inherited by both account tests. It
checks the three roles above, shifted selected indices, unselected-proof rejection, exact
scope behavior, invalid selections, and ordinary ETH funding.

[`PaymasterTestSuite.sol`](../test/PaymasterTestSuite.sol) is inherited by all three example
paymaster tests: `SponsoringPaymasterTest`, `P256PaymasterTest`, and
`WebAuthnPaymasterTest`. Each paymaster must sponsor the same account matrix from a
shared signature envelope:

1. `OwnerAccount`
2. `MultisigAccount`
3. `SessionKeyAccount` through its owner path
4. `P256Account`
5. `WebAuthnAccount`
6. Migrated Kernel v3.3 proxy
7. EIP-7702-delegated EOA

The matrix appends the paymaster's single authorization entry after the account-specific
prefix, computes its shifted scalar index dynamically, and includes a wrong-selected-index
negative.

### What the Forge tests do not prove

The tests execute compiled bytecode, the real frame opcodes, SHA-256, and available
precompiles in patched revm, but `vm.setFrameTx` supplies synthetic transaction context.
Consequently:

- native P256 tests supply already-verified `scheme`, `signer`, and `msg` metadata with no
  raw protocol signature, so they test account/paymaster routing and policy rather than
  protocol P256 cryptography;
- WebAuthn tests use `vm.signP256` to create a real assertion and exercise P256VERIFY at
  `0x100`, but the challenge is a synthetic fixture hash rather than a hash decoded from a
  raw type-`0x06` transaction;
- the suites use a non-zero maximum cost and fund the intended payer, but do not model the
  final ETH debit, refund, or nonce transition; and
- they do not test transaction encoding, public-pool admission, mining, receipts, or replay.

The separate Anvil integration suite closes that boundary for native P256: it submits a raw
type-`0x06` envelope through the production `P256Account` runtime, rejects a corrupted public
key at admission, and checks the mined payer, nonce, and SENDER-frame effect. WebAuthn
remains without a claimed Anvil end-to-end test; no ML-DSA verifier or transaction path is
shipped.

## Runtime profile

The contracts project compiles at experimental solc EVM version `@future`. In this toolkit's
patched Foundry, `@future` maps to **Osaka**, the pre-Amsterdam profile that activates
P256VERIFY at address `0x100`. This mapping is required for the contract-verified WebAuthn
path; Amsterdam is intentionally not selected because its node-level state-gas rules are
incompatible with the current frame-transaction profile.

Forge uses that mapping automatically through `contracts/foundry.toml`. To execute a
WebAuthn validator in patched Anvil, start it explicitly with:

```bash
foundry/target/debug/anvil --hardfork osaka --enable-frame-transactions
```

This is a runtime requirement, not a claim that a raw WebAuthn transaction test already
exists.

## Deliberate omissions

This is a strict assertion verifier, not a relying-party implementation. It provides no:

- credential registration or attestation verification;
- attested-credential-data or authenticator-extension processing (`AT` and `ED` are rejected);
- signature-counter comparison, storage, or clone response;
- credential ID, user-handle, transport, or discoverable-credential processing;
- persistence of backup eligibility or backup state;
- tolerant JSON parsing, origin normalization, or RP-ID derivation; or
- WebAuthn account credential rotation.

Deployment code must obtain and validate the credential public key, RP ID, and origin through
its own trusted registration flow, compute `rpIdHash = sha256(bytes(rpId))` and
`originHash = keccak256(bytes(origin))` exactly, and decide whether UV is mandatory. The
contracts have not been independently audited and should not be treated as a complete
production WebAuthn security design.
