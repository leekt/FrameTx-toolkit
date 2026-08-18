# 04 — k-of-n multisig account (Solidity)

A 2-of-3 (or k-of-n) multisig smart account in ~40 lines of logic, with **no `ecrecover`, no
signature blob, and no per-signer offsets**.

`MultisigAccount.sol` is the whole account. There is no `execute()` function — see
[Where did `execute()` go?](#where-did-execute-go).

## What it does

The protocol validates every `SECP256K1` / `P256` entry against its selected message before
any frame runs. If one is invalid the transaction is invalid and this code never executes.
The account then counts only entries whose selected message is the canonical transaction
hash. Its entire job is:

1. `FrameTxLib.signatureCount()` (`TXPARAM 0x0B`) → how many signature entries does this
   transaction carry?
2. For each entry `i`:
   - `FrameTxLib.sigScheme(i)` → `scheme`. Skip anything that is not `SECP256K1`.
   - `FrameTxLib.signedThisTx(i)` → whether `msg` is `0`, meaning "signed over
     `compute_sig_hash(tx)`", i.e. over *this* transaction.
   - `FrameTxLib.sigSigner(i)` → `resolved_signer`. Skip unless it is a stored owner.
   - Require it to be strictly greater than the previously counted signer (dedup, below).
3. If the count reaches `threshold`, call `FrameTxLib.approve(...)`.

Order matters in step 2: **read `scheme` before `resolved_signer`**. Requesting
`resolved_signer` of an `ARBITRARY` entry is an *exceptional halt*, not a revert — it burns
the frame's gas and, since this is a VERIFY frame, invalidates the whole transaction.
Skipping foreign entries rather than rejecting them keeps the account composable with a
paymaster that carries its own signature in the same envelope.

The `msg == 0` check is a security requirement, not a formality. An entry with an explicit
32-byte digest is a signature an owner produced in some *other* context; the protocol will
happily validate it. Counting it would let anyone graft an unrelated owner signature onto an
arbitrary transaction.

## Dedup without scratch space

A VERIFY frame executes as a `STATICCALL`. No `SSTORE`, no `TSTORE`, no logs, no
state-changing calls — `APPROVE` is the only exception. **The obvious multisig
implementation, "mark each owner as used in a mapping and clear it at the end", is
structurally impossible here.** Neither is a transient-storage variant available.

Two ways out; this example takes the first:

| Approach | Cost | Requires |
|---|---|---|
| **Sorted signers** (used here) | one `uint256` compare per entry, one `SLOAD` per candidate | the wallet building the transaction must place owner entries in ascending address order |
| Bitmap of owner indices | one memory word, one `SLOAD` per candidate, plus index→owner storage | owners stored as an *indexed array*, and the frame data must carry each signer's index |

Sorted signers wins on simplicity: dedup collapses to `require(signer > prevSigner)`, owner
storage stays a plain `mapping(address => bool)`, and no hint data has to be passed in or
kept consistent. Its cost is an ordering obligation on the transaction builder — and getting
it wrong is not a soft failure: the `require` reverts the VERIFY frame, which makes the whole
transaction invalid. The bitmap
approach removes that obligation but needs an owner-index array that must be maintained
across owner rotations, and the indices have to be transported somewhere (frame data), which
is more moving parts for the same guarantee.

An O(k²) "have I seen this signer" scan over a memory list also works and imposes no
ordering, but it is strictly more code for the same result at realistic k.

Note that only *counted* signers must be ascending. Non-owner entries are skipped and do not
participate in the ordering, so a paymaster's signature can sit anywhere in the list.

## Can a relayer tamper with the signature list?

No. `compute_sig_hash` elides only the raw `signature` bytes of empty-`msg` entries; each
entry's `scheme`, `signer` and `msg`, and the entire `frames` list, are committed. Injecting,
removing or reordering entries changes the hash and invalidates the owners' signatures.

That also means the owners are signing the *frames*: this account does not need to inspect,
whitelist or replay-protect the calls being authorised. `nonce` and `chain_id` are in the
hash too, so there is no separate nonce to manage.

## Frame layout

The transaction must use the `self_verify` prefix (spec §Mempool → Mode Subclassifications).
`sender` is the account address, and at least `threshold` envelope signature entries must be
`SECP256K1` owner signatures with empty `msg`, in ascending address order.

| # | mode | flags | target | data | purpose |
|---|---|---|---|---|---|
| 0 | `VERIFY` (1) | `0x3` | account (or `None`) | `0x6901f668` (`validate()`) | counts owner signatures, `APPROVE(0x3)` — approves execution *and* pays the gas |
| 1 | `SENDER` (2) | `0x0` | whatever the owners want to call | that call's calldata | runs with `caller == ORIGIN == account` |

Frames 1..n can be any number of `SENDER` / `DEFAULT` frames; `sender_approved` is
transaction-scoped, so every subsequent `SENDER` frame runs as the account. That is safe
here precisely because the owners signed the canonical hash, which covers all of them.

With a paymaster instead of self-relay (`only_verify` + `pay` prefix):

| # | mode | flags | target | purpose |
|---|---|---|---|---|
| 0 | `VERIFY` (1) | `0x2` | account | same `validate()`, `APPROVE(0x2)` — execution only |
| 1 | `VERIFY` (1) | `0x1` | paymaster | paymaster approves payment |
| 2 | `SENDER` (2) | `0x0` | … | the user operation |

The same deployed bytecode serves both: `validate()` approves whatever the *current* frame's
flags allow, via `FrameTxLib.frameAllowedScope(FrameTxLib.currentFrameIndex())`
(`FRAMEPARAM(TXPARAM(0x0A), 0x06)` at the opcode level).
`APPROVE` reverts on a scope that is not a subset of `flags & 0x3`, so echoing the flags back
never grants more than the transaction asked for. The one frame where it does not work is a
frame with `flags & 0x3 == 0`: `APPROVE` also rejects scope `0`, so there `validate()` reverts
rather than approving nothing — which is correct, since such a frame is not allowed to approve.

Gas budget: the public mempool caps the validation prefix at `MAX_VERIFY_GAS = 100_000`,
*including* the 2800-per-`SECP256K1` intrinsic signature cost. A 3-of-5 signing burns 8400
there before frame 0 gets a single unit, so keep frame 0's `gas_limit` and the owner count
in view of that ceiling.

## Where did `execute()` go?

Nowhere — it was never needed. A `SENDER` frame *is* the execution: the protocol makes the
call with `caller = tx.sender`, so the account never has to dispatch one itself.

Concretely, against ERC-4337:

| ERC-4337 multisig | This account |
|---|---|
| `validateUserOp` decodes a packed `bytes signature` blob: k × 65 bytes, offsets, length checks | protocol hands over structured entries; the account reads metadata with two opcodes |
| k × `ecrecover` in contract code (~3000 gas each plus the parsing around it) | zero EC operations in contract code; the protocol verified them before frame 0 |
| must reconstruct and hash the `UserOperation` to know what was signed | `msg == 0` *means* "the canonical hash of this transaction" — nothing to reconstruct |
| `execute()` / `executeBatch()` plus an `onlyEntryPoint` modifier | none; `SENDER` frames are the batch |
| own nonce management (192-bit key + sequence) | `tx.nonce` is the sender's account nonce and is in the signed hash |
| EntryPoint contract, deposit/stake accounting, `validationData` time ranges | `APPROVE` scopes; expiry via the protocol's expiry verifier frame |
| storage-access rules enforced by an off-chain bundler spec | state *writes* blocked by `STATICCALL` in the EVM; read scoping (`SLOAD` only on `tx.sender`) is still a mempool rule |

The 4337 version of this contract is several hundred lines and its bugs live in the blob
parser. Here there is no blob and no parser.

Malicious-relayer surface also shrinks: 4337 bundlers can reorder or drop `UserOperation`s
and the account must defend with its own nonce scheme, whereas here the frame list and
signature metadata are inside the hash the owners signed.

## Storage layout

| Slot | Contents |
|---|---|
| 0 | `mapping(address => bool) isOwner` — owner flag at `keccak256(abi.encode(owner, 0))` |
| 1 | `uint256 threshold` |

The constructor-backed Foundry tests exercise this layout directly. Selectors:
`validate()` `0x6901f668`, `isOwner(address)` `0x2f54bf6e`, `threshold()` `0x42cde4e8`.

## Compiling

```bash
cd contracts
../foundry/target/debug/forge build
```

The current generated runtime is **463 bytes** (926 hex characters) in
`out/MultisigAccount.sol/MultisigAccount.json` (`deployedBytecode`). It is built with
`cbor_metadata = false`; all 463 bytes are runtime code and there is no metadata trailer.

Operand order is visible in the output if you want to confirm it: `600b b0` is
`TXPARAM(0x0B)`; `6001 80 82 b4` is `SIGPARAM` with the index on top and `param = 0x01`
below; `6006 600a b0 b3` is `FRAMEPARAM(TXPARAM(0x0A), 0x06)`; and the tail `5f 5f aa` is
`approvetx(0, 0, scope)` with `offset` on top.

## Verification scope

`test/MultisigAccount.t.sol` installs this exact generated runtime and executes its positive
and negative policy paths against the real opcodes in patched revm. The tests cover threshold
approval, ordering/dedup, foreign and arbitrary entries, explicit digests, P256 exclusion,
scope derivation, and `APPROVE_NONE`. Anvil's raw-RPC path is tested separately with simpler
accounts; this specific multisig has not been submitted over raw RPC.

## Spec points that are unclear or worth flagging

- **The `0` encoding of an empty `msg` is stated in the wrong section.** The `SIGPARAM` table
  says only "returns `msg`" and never mentions how an empty `msg` appears on the stack; the
  encoding is fixed one section earlier, in the signature-object rules: "The explicit 32-byte
  zero digest is invalid. This reserves the zero stack value as the EVM-visible representation
  of the transaction signing hash case." That single sentence is what this example's central
  check rests on, and a reader of the instruction section alone would not find it.
- **`APPROVE`'s behaviour in a non-`VERIFY` frame is not stated.** The instruction section
  imposes no mode restriction, so a `DEFAULT`-mode frame with `flags = 0x3` targeting this
  account appears able to reach `approvetx`. It is harmless — the same threshold of owner
  signatures over the same canonical hash is still required — but whether it is *intended* is
  not addressed. This account therefore does not gate `validate()` on mode or `msg.sender`.
- **Nothing bounds `len(signatures)`.** `MAX_FRAMES` is 64, but the signature list has no
  stated cap, so the loop bound comes from gas alone. Inside the public mempool
  `MAX_VERIFY_GAS` covers it; outside it (private relay), a large signature list is simply an
  expensive transaction the sender pays for.
- Surprising, though clearly specified: `resolved_signer` on an `ARBITRARY` entry is an
  *exceptional halt* rather than a revert or a zero return. In a VERIFY frame the difference
  is fatal — the whole transaction becomes invalid — which makes the scheme check mandatory
  rather than defensive.
