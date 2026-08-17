# 02 — Minimal Yul account (no compiler fork required)

A minimal EIP-8141 smart account: **27 bytes of runtime code**, written in standalone Yul.
It answers two questions during validation: *did the owner's key sign, and did it sign the
canonical hash of this transaction?* If both hold, it calls `APPROVE`.

The point of this example is that **no compiler fork is strictly needed**. Yul's
`verbatim_*` builtins emit arbitrary bytecode, so a stock `solc` can produce frame-aware
contracts today. The patched solc (`../../../solidity`) is nicer to read and emits two to
four fewer bytes for this account; both spellings are here.

## What the account does

```
signer := SIGPARAM(signatureIndex = 0, param = 0x00)   // resolved_signer
signedThisTx := SIGPARAM(signatureIndex = 0, param = 0x02) == 0
if signer == sload(0) && signedThisTx { APPROVE(offset = 0, length = 0, scope = 3) }
revert(0, 0)
```

Storage slot 0 holds the owner address. Nothing else is stored, and there is no
initializer — seed slot 0 from a factory, or add an `sstore` to the constructor.

**No `ecrecover` anywhere.** By the time this frame runs, the protocol has already
verified every `SECP256K1` / `P256` entry in `tx.signatures` against either the canonical
signature hash (empty `msg`) or its explicit digest (§ *Transaction Signatures*: "Every
protocol-validated signature in this list must validate successfully before any frame is
executed"). A malformed or invalid signature makes the transaction invalid before the EVM
is entered. So the account does not re-do the cryptography. It asks *which key signed* with
`SIGPARAM(0, 0x00)`, then requires
`SIGPARAM(0, 0x02) == 0`. Zero is the reserved EVM representation of an empty signature
`msg`, meaning the protocol checked this entry against `compute_sig_hash(tx)`. An explicit
digest is protocol-valid too, but does not bind the transaction's frame list and must not
authorize it.

**All validation is read-only.** A `VERIFY` frame runs under `STATICCALL` rules — the spec
allows only `APPROVE` to change state (§ *Frame Transaction* → *Behavior*: "Only `APPROVE`
can modify the state or transaction context in `VERIFY`"). `SLOAD` and `SIGPARAM` are both fine. A revert here
makes the whole transaction invalid, which is exactly the desired failure mode for a bad
signer.

## Required frame layout

`APPROVE(scope = 3)` succeeds only when the frame's own flags permit it
(`scope & ~(frame.flags & 0x3) == 0`) and `resolved_target == tx.sender`. That pins the
transaction to a `self_verify` prefix. Scope `3` also approves *payment*, so the account
itself is the payer and must hold at least `TXPARAM(0x06)` (`max_cost`) — `APPROVE` reverts
on insufficient balance. Use scope `2` plus a separate `pay` frame if a paymaster funds it
(example 06).

| Frame | Mode    | Flags               | Target                | Value | Data       | Purpose |
|-------|---------|---------------------|-----------------------|-------|------------|---------|
| 0     | VERIFY  | `0x3` (EXEC+PAYMENT)| null (⇒ `tx.sender`)  | 0     | empty      | Runs this account's code; approves execution and payment |
| 1     | SENDER  | `0x0`               | whatever you're calling | any | call data  | The actual user operation, `CALLER == tx.sender` |

And in `tx.signatures`:

| Index | Scheme      | `signer`               | `msg`  | Purpose |
|-------|-------------|------------------------|--------|---------|
| 0     | `SECP256K1` | the owner (slot 0)     | empty  | Signs `compute_sig_hash(tx)`; `SIGPARAM(0, 0x00)` returns this address |

Frame 0's `data` is unused — this account ignores `FRAMEDATALOAD` entirely. Frame 1 (and
any further `SENDER` frames) are covered by the signature because an empty `msg` means the
signature is over the canonical hash of the whole envelope, frame list included.

## Compiling

Portable version, works on any stock solc >= 0.8.5, the release that introduced
`verbatim_*`. Exact bytes remain compiler-version and EVM-version dependent; the table below
records the current patched compiler output used by this worktree.

```bash
cd contracts/src/accounts
solc --strict-assembly --bin account.yul
```

Fork version, needs the patched compiler:

```bash
../../../solidity/build/solc/solc \
  --strict-assembly --experimental --evm-version @future --bin account-builtins.yul
```

### Actual output

Every number below was produced with
`0.8.37-develop.2026.8.16+commit.70c3af1c.mod`; `runtime` is the creation output after the
`f3fe` trailer.

| File | Compiler | Flags | Runtime bytecode | Bytes |
|------|----------|-------|------------------|-------|
| `account.yul` | fork | none | `5f5fb460025fb41580825f5414161560175760035f5faa5b5f5ffd` | **27** |
| `account.yul` | fork | `--optimize` | `5f80b460025fb415905f5414166013575f80fd5b60035f80aa5f80fd` | 28 |
| `account-builtins.yul` | fork | none | `5f80b460025fb415905f5414166013575f80fd5b60035f80aa` | **25** |
| `account-builtins.yul` | fork | `--optimize` | `60025fb4155f80b45f5414166012575f80fd5b60035f80aa` | 24 |

Full creation code for the canonical 27-byte portable build
(`solc --strict-assembly --bin account.yul`):

```
601b600b5f39601b5ff3fe5f5fb460025fb41580825f5414161560175760035f5faa5b5f5ffd
```

Disassembly of the 27-byte runtime:

```
5f 5f b4       PUSH0 PUSH0 SIGPARAM       ; sigparam(0, 0x00) -> signer
60 02 5f b4    PUSH1 0x02 PUSH0 SIGPARAM ; sigparam(0, 0x02) -> msg
15             ISZERO                    ; signedThisTx
80 82 5f 54    DUP1 DUP3 PUSH0 SLOAD     ; retain flag, load owner
14 16 15       EQ AND ISZERO             ; reject unless owner && canonical hash
60 17 57       PUSH1 0x17 JUMPI          ; jump to revert on failure
60 03 5f 5f aa PUSH1 3 PUSH0 PUSH0 APPROVE
5b 5f 5f fd    JUMPDEST PUSH0 PUSH0 REVERT
```

## The two spellings

```yul
// portable — any solc, no flags, no fork
let signer := verbatim_2i_1o(hex"b4", 0, 0x00)
let signedThisTx := iszero(verbatim_2i_1o(hex"b4", 0, 0x02))
if and(eq(sload(0), signer), signedThisTx) {
    verbatim_3i_0o(hex"aa", 0, 0, 3)
}

// fork — patched solc, needs --experimental --evm-version @future
let signer := sigparam(0, 0x00)
let signedThisTx := iszero(sigparam(0, 0x02))
if and(eq(sload(0), signer), signedThisTx) {
    approvetx(0, 0, 3)
}
```

Note the builtin is **`approvetx`**, not `approve`: the bare name is deliberately left free
because it is the ERC-20 method name. The profile's other builtins use lowercased opcode
names, including `txparam`, `frameparam`, `sigparam`, and `sigdatacopy`.

`SIGDATACOPY` (`0xb5`) reads `ARBITRARY` signature bytes with fixed copy-style order:
`sigdatacopy(memOffset, dataOffset, length, signatureIndex)`.

### Why they aren't byte-identical

The fork version is two bytes shorter unoptimized and four shorter with `--optimize`,
because `approvetx` is known to the compiler as terminating control flow, so the
unreachable trailing `revert(0, 0)` is dropped. `verbatim_3i_0o(hex"aa", ...)` is an opaque
blob; solc must assume execution falls through it, and keeps the dead `5f80fd`. That is the
practical cost of the portable spelling: dead bytes and a slightly worse stack
layout, not correctness.

(Curiosity worth knowing before you reach for it: on the verbatim file `--optimize` makes
the output *larger*, 27 -> 28 bytes. The optimizer improves the stack layout around the
opaque blobs but also duplicates the revert tail. Measure, don't assume.)

## Verbatim argument order

**The first argument to `verbatim_Ni_Mo` ends up on TOP of the stack**, so the argument
list reads in the same order as the spec's stack tables (`top - 0` first). Do not trust
this from memory — here is the check, run against the fork:

`order.yul` is one line of code under its comment header:

```yul
object "O" { code { verbatim_3i_0o(hex"aa", 0x11, 0x22, 0x33) } }
```

```
$ solc --strict-assembly --asm --bin order.yul

======= order.yul (EVM) =======

Binary representation:
603360226011aa

Text representation:            # source-location comments elided
  0x33
  0x22
  0x11
  verbatimbytecode_aa
```

Same `603360226011aa` from stock 0.8.5, stock 0.8.30, and the fork — the convention has not
drifted across releases.

Observed: `PUSH1 0x33; PUSH1 0x22; PUSH1 0x11; AA`. The **last** argument is pushed
**first**, so the first argument (`0x11`) is on top when the opcode executes. Applied to
`APPROVE` (`top-0 = offset`, `top-1 = length`, `top-2 = scope`), `verbatim_3i_0o(hex"aa",
0, 0, 3)` means offset 0, length 0, scope 3 — which is what we want. The same convention
holds for the fork's builtins (`approvetx(offset, length, scope)`), so switching spellings
never reorders arguments.

Cross-checked against the working-tree revm implementation at
`revm/crates/interpreter/src/instructions/frame_tx.rs`: `sigparam` pops `sig_index` from the
top and uses the next slot as `param`, matching `sigparam(0, 0x00)` and
`verbatim_2i_1o(hex"b4", 0, 0x00)`.

## Deliberate omissions

- **The `msg` check is not optional.** This account requires `SIGPARAM(0, 0x02) == 0`, and
  `test_explicitDigestFromOwnerRefused` differs from the passing owner case only by setting
  an explicit digest. Removing the check would authorize replaceable `SENDER` frame lists.
- **No scheme check.** `SIGPARAM(0, 0x01)` would confirm the entry is `SECP256K1` rather
  than `P256`. Not needed for safety here: either way the protocol has verified the
  signature and resolved a signer address, and the account only trusts one address.
  `ARBITRARY` entries cannot fool it — requesting `resolved_signer` on one is an
  exceptional halt, not a zero return.
- **No `TXPARAM`/`FRAMEPARAM` inspection, no owner rotation, no execute function.** A
  `SENDER` frame calls targets directly with `CALLER == tx.sender`; this account needs no
  `execute()` entry point at all, which is most of why it is 27 bytes.
- **No replay-protection logic.** The nonce is incremented by `APPROVE` itself, in
  protocol.

## Spec notes: ambiguous or surprising

1. **`SIGPARAM` with no matching signature index is a halt, not a zero.** Out-of-bounds
   `signatureIndex` causes an exceptional halt. So an account cannot "probe" for an
   optional signature entry without first bounding the loop with
   `TXPARAM(0x0B)` (`len(signatures)`). Relevant to example 04, not to this one.
2. **`resolved_signer` for a signature with an absent `signer` field is `tx.sender`.** The
   spec says "If absent, `tx.sender` is used (for introspections as well)". For this
   account that is harmless (slot 0 would have to equal `tx.sender`), but it means
   `SIGPARAM(i, 0x00)` never returns the zero address for a protocol-validated entry, and
   an account that keys on it should be aware the value can come from the envelope's
   sender field rather than from key recovery.
3. **Ordering of the `ADDRESS != resolved_target` check versus the flags check is
   specified, but which one a client surfaces on failure is not.** Both revert; only error
   messages differ. Not load-bearing, but do not write tests that assert a specific reason
   string.
4. **The spec does not say whether `APPROVE`'s return-data region is observable anywhere.**
   `APPROVE` follows `RETURN` semantics for `[offset, offset+length)`, but a `VERIFY`
   frame's return data has no defined consumer in the frame model — nothing in the spec
   reads it. We pass `(0, 0)`; if you were hoping to signal something to a later frame
   through it, the spec is silent on how you would read it back.
