# 01 — EOA with default code

The simplest possible frame transaction: a plain EOA, **no contract code, no EIP-7702
delegation**, sending a frame transaction.

There is no contract in this example. That is the point — the account's validation logic is
supplied by the protocol itself. This directory is documentation only: no source file, no
compiler run.

Spec: [`spec/EIP8141.md`](../../spec/EIP8141.md), section [Default code](../../spec/EIP8141.md)
(search for `##### Default code`).

---

## Why an account with an empty code hash can still validate

When a frame is executed, the protocol resolves the frame's target:

```
resolved_target = frame.target if frame.target is not None else tx.sender
```

and then checks the target's code hash. If it is the empty code hash
(`0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`, i.e. `keccak256(b"")`),
the protocol does **not** call user code — there is none. Instead it runs the **default code**:
a protocol-defined behaviour that is specified in prose, not deployed as bytecode anywhere.

So "the account has no code" does not mean "the account cannot validate". It means the EVM
never gets asked. The default code is the lowest common denominator of account functionality
that EIP-8141 guarantees every address has, for free, with no deployment and no delegation.

The default code only does something in `VERIFY` mode. In `DEFAULT` and `SENDER` mode it
"returns successfully as if calling empty code" — which is exactly the behaviour a call to an
EOA has today (a value transfer to an EOA still just works).

## The exact requirements

Verbatim from the spec, for a frame whose `resolved_target` has the empty code hash:

- If `mode` is `VERIFY`:
  - `allowed_scope = frame.flags & APPROVE_SCOPE_MASK` (`APPROVE_SCOPE_MASK == 0x3`).
  - If `allowed_scope == APPROVE_SCOPE_NONE` (`0x0`), **revert**.
  - `sig_index = 0` if `allowed_scope & APPROVE_EXECUTION != 0` (i.e. scope `0x2` or `0x3`),
    else `sig_index = 1` (i.e. scope `0x1`, payment-only).
  - If there is not a `SECP256K1` signature at index `sig_index` such that
    `resolved_signer == resolved_target` **and** `sig.msg == Bytes()` (empty), **revert**.
  - Call `APPROVE(allowed_scope)`.
- If `mode` is `SENDER` or `DEFAULT`: return successfully as if calling empty code.

Four things are load-bearing and easy to get wrong:

1. **The scope comes from the frame's flags, not from calldata.** The default code approves
   exactly `frame.flags & 0x3` — never more, never less. `flags = 0x0` on a `VERIFY` frame
   against a codeless account is an immediate revert, and a reverting `VERIFY` frame makes the
   **whole transaction invalid**.
2. **The signature index is positional and derived from the scope.** Scope `0x3` or `0x2`
   (anything containing `APPROVE_EXECUTION`) reads signature **0**; scope `0x1` (payment only,
   i.e. an EOA acting as a sponsor/paymaster) reads signature **1**. There is no search: if the
   signature at that exact index is not the right one, the frame reverts. A transaction where
   an EOA sender approves execution (scope `0x2`) *and* a second codeless EOA sponsors payment
   (scope `0x1`) must therefore lay its signature list out as `[sender_sig, sponsor_sig]`, in
   that order.
3. **`sig.msg` must be empty.** An empty `msg` means "this signature is over
   `compute_sig_hash(tx)`", the canonical transaction signature hash. A 32-byte explicit digest
   is rejected by the default code, so an EOA's approval is always bound to this exact
   transaction, on this chain, at this nonce.
4. **`resolved_signer` must equal `resolved_target`.** For the sender's own frame
   (`target = null`), both resolve to `tx.sender`, and a signature entry with an empty `signer`
   field also resolves to `tx.sender` — so the common case needs no `signer` bytes on the wire
   at all. For a *sponsor* frame the `target` is the sponsor's address, and the sponsor's
   signature entry must carry an explicit 20-byte `signer` equal to it.

Note that the protocol has already verified every `SECP256K1`/`P256` signature in the envelope
*before any frame runs* — against the signature hash when `msg` is empty, against the explicit
32-byte digest otherwise. The default code does no `ecrecover`: it
only asks "is the already-verified signer at index N the account I am validating for?". This is
the same idea the smart-account examples in this repo implement with `SIGPARAM` — the default
code is just the protocol-supplied version of it.

The resulting `APPROVE(0x3)` does what it does for any account: sets `sender_approved = true`,
increments the sender's nonce **once**, sets `payer = tx.sender`, and collects `max_cost` from
the sender.

## Minimal transaction layout

Two frames. This is EIP-8141 "Example 1" from the spec's Examples section, applied to a
codeless account.

| Frame | Mode     | Caller        | Flags                                        | Target        | Value | Data      | Purpose |
| ----- | -------- | ------------- | -------------------------------------------- | ------------- | ----- | --------- | ------- |
| 0     | `VERIFY` (1) | `ENTRY_POINT` (`0xaa`) | `0x3` — `APPROVE_EXECUTION_AND_PAYMENT` | **null** (⇒ `tx.sender`) | 0 | empty | Default code checks signature 0 and calls `APPROVE(0x3)` |
| 1     | `SENDER` (2) | `tx.sender`   | `0x0` — `APPROVE_SCOPE_NONE`                 | callee        | any   | calldata  | The actual work, executed as the sender |

Signature list:

| Index | `scheme`          | `signer` | `msg` | `signature`            |
| ----- | ----------------- | -------- | ----- | ---------------------- |
| 0     | `0x1` `SECP256K1` | empty (⇒ `tx.sender`) | empty (⇒ signature hash) | `v ‖ r ‖ s` (65 bytes) |

Why two frames and not one: the validation phase has to be static so the mempool can check it
cheaply, so the approval lives in its own `VERIFY` frame. A `SENDER` frame executed before
`sender_approved` is true makes the transaction invalid, so frame order matters.

Constraints the static validity rules impose on this layout (spec §Constraints):

- `frame.mode == SENDER or frame.value == 0` — only the `SENDER` frame may carry value. To send
  ETH, put the amount on frame 1 and point `target` at the recipient (spec Example 1a).
- `frame.flags & APPROVE_EXECUTION` requires `frame.target is None or frame.target == tx.sender`
  — a frame can only approve execution for the sender itself, which is why frame 0's target is
  null.
- `ATOMIC_BATCH_FLAG` (`0x4`) is invalid on a `VERIFY` frame, so frame 0 can never be `0x7`.

To batch, append more `SENDER` frames and set `ATOMIC_BATCH_FLAG` on every frame in the batch
except the last (spec Example 2).

To be sponsored, it is not enough to append a sponsor frame: frame 0 must also **drop from
`0x3` to `0x2`** (`APPROVE_EXECUTION` only), because `APPROVE_PAYMENT` reverts if `payer` is
already set. The layout becomes spec Example 3's prefix — frame 0 `VERIFY`/`0x2`/null target,
frame 1 `VERIFY`/`0x1` targeting the sponsor — with signatures `[sender_sig, sponsor_sig]`,
the sponsor's carrying an explicit 20-byte `signer`. Neither batching nor sponsorship needs any
code deployed at either address. Leaving frame 0 at `0x3` and appending the sponsor frame
makes the transaction invalid (frame 1 reverts, and a reverting `VERIFY` frame is fatal).

## What the Anvil tests prove

The working-tree integration suite at
[`foundry/crates/anvil/tests/it/frame_tx.rs`](../../foundry/crates/anvil/tests/it/frame_tx.rs)
submits signed type-`0x06` envelopes through Anvil's raw JSON-RPC path and asserts resulting
state. Its default-code cases pin both self-relay and sponsorship:

- `default_code_verify_approves_the_scope_its_flags_name` mines the canonical-hash case and
  observes the later SENDER frame's storage write;
- `default_code_verify_without_an_approval_scope_is_not_mined` proves scope zero approves
  nothing;
- `default_code_verify_with_an_explicit_msg_is_not_mined` uses a correctly signed explicit
  digest, proving signature validity alone is insufficient;
- `default_code_payment_only_scope_uses_signature_index_one` proves a codeless sponsor pays
  and the user operation executes;
- `default_code_payment_only_scope_ignores_a_signature_at_another_index` moves the sponsor
  signature away from index 1 and proves positional selection is enforced.

The positive self-relay integration also checks that the sender nonce advances once, the
payer loses value plus a non-zero fee, the SENDER target receives value and writes storage,
and the mined transaction is retrievable as type `0x06`. These tests are part of the recorded
Foundry gitlink; see [VERSIONS.md](../../VERSIONS.md#reproducibility-status).

## Why this matters

Essentially every account on Ethereum today is an EOA with an empty code hash. Without the
default code, frame transactions would be a feature only for accounts that first deploy a
contract or install an EIP-7702 delegation — a migration cliff in front of ~every user.

With it, an existing EOA gets, on day one and with zero on-chain setup: batching (multiple
`SENDER` frames, atomically if desired), sponsored gas (a second `VERIFY` frame with a sponsor),
paying fees in ERC-20 (spec Example 3), and the ability to *be* a sponsor for someone else
(spec: "users can use any EOA as a paymaster thanks to the default code"). The spec's own
rationale section (§Externally Owned Account (EOA) support) states this as the goal.

It also gives the protocol a hard floor: every address, forever, has at least this much account
functionality, so tooling can assume it rather than probing for it.

## Notes on the spec

Things that are underspecified or surprising, flagged rather than guessed:

- **Gas cost of the default code is not specified.** The spec says what the default code *does*
  but never assigns a separate cost; contrast the expiry verifier frame, where it explicitly
  says "the frame consumes gas according to normal EVM execution rules". Do not treat a
  client's current account-access charge as a spec guarantee.
- **Out-of-range `sig_index` is not called out.** If `allowed_scope == 0x1` and the transaction
  carries fewer than two signatures, the spec's phrasing ("if there is not a `SECP256K1`
  signature at index `sig_index` such that…") implies a revert. Anvil's implementation uses a
  bounds-checked lookup and rejects the frame when the entry is absent.
- **The non-existent-account case is not literally covered.** The spec keys the default code on
  the *empty code hash*; an account that has never been touched has no hash at all. Anvil's
  `target_has_no_code` accepts a missing account, the canonical empty-code hash, and the zero
  hash. This is the obviously intended reading, since such an account is codeless by any
  definition, but the spec text does not say it explicitly.
- **The positional signature indices are a real footgun.** `0` for anything approving execution
  and `1` for payment-only is arbitrary-looking, and nothing in the encoding marks which entry
  is which; a wallet that reorders the signature list silently breaks validation. The rule is
  clearly stated, just fragile.
- **Payment-only default code depends on frame order.** A codeless sponsor's frame has scope
  `0x1`, and `APPROVE_PAYMENT` requires `sender_approved == true` already, so the sponsor's
  `VERIFY` frame must come *after* the sender's. The spec states each half (in the `APPROVE`
  section and the default code section) but never joins them in one place.
