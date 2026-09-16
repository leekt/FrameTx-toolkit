> Current source and support status: [spec baseline](../spec/README.md) and
> [working-tree reproducibility](../VERSIONS.md#reproducibility-status).

# Limitations and known divergences

Read this before planning work on top of the toolkit. Some of these will change what you
can attempt.

## Wire support and execution limits

With `--enable-frame-transactions`, the local Foundry checkout accepts scalar EIP-8141
and keyed EIP-8250 type-`0x06` envelopes through Anvil RPC. It mines and executes their
frames. Canonical recent-root verification, raw POST_TX, public-pool policy and gossip
remain incomplete.

| Status | Component | Detail |
|---|---|---|
| Implemented | Baseline Anvil RPC | Decode, validate, mine, retrieve, trace, and replay raw type-`0x06` transactions (scalar nonce, `fees`/`limits` envelope); atomic batches, default code, canonical raw-byte fork replay, and transaction-hash forks are covered by [`frame_tx.rs`](../foundry/crates/anvil/tests/it/frame_tx.rs). |
| Implemented | Frame receipts | Consensus receipt encoding and trie roots include the payer and ordered `[status, gas_used, logs]` frame results; RPC receipts expose these as `payer` and `frameReceipts`. |
| Implemented | Expiry activation | Enabled nodes install the canonical verifier at `0x8141` after source replay, and memory/fork resets restore it. |
| Missing | Ready post-quantum verifier | Schemes `0x03` through `0xff` remain reserved. ML-DSA would require an `ARBITRARY` witness plus validation-frame or custom-verifier code; no witness profile, verifier, account, paymaster, or raw Anvil path is shipped. |
| Partial | Selected AA extensions | EIP-8250 wire/state bookkeeping is implemented. EIP-8272 has a verifier-frame encoder; canonical verifier execution remains pending. EIP-7906 trace construction and raw `POST_TX` are pending, and EIP-8298 is spec-only while its opcode is TBD. |
| Missing | Prefix policy | The validation-prefix simulation and DoS rules from the spec are not implemented as a public transaction-pool admission policy. |
| Partial | Sponsorship RPC path | Raw-RPC sponsorship is covered end to end for both a default-code EOA sponsor (signature index 1) and a code-bearing sponsor contract in the `pay` frame; canonical-paymaster pool accounting is not. |
| Known divergence | Fee-field width | Upstream admits fee scalars below `2**256`. The Frame decoder represents them as 256-bit values, but the current Alloy/REVM transaction APIs are `u128`, so Foundry validation rejects any fee field above `u128::MAX`. |
| Partial | EIP-7997 factory | Anvil already installs the exact deterministic-factory address and runtime. It is available independently of Glamsterdam and has nonce `0`, not the activation-state nonce `1`. |
| Missing | Networking | No frame-transaction gossip or blob-sidecar wrapper is implemented. |

[VERSIONS.md](../VERSIONS.md#reproducibility-status) distinguishes published gitlinks
from this working-tree migration and records current checks. The locked Solidity
dependencies are unchanged.

## Activation and execution profiles

Frame transactions are off by default. `--enable-frame-transactions` enables the
profile only for Ethereum hard forks before Amsterdam. OP Stack, Tempo, Monad, and Amsterdam
state-gas profiles reject type `0x06` at submission instead of allowing it to reach a
partially compatible executor.

EIP-8151 is likewise disabled by default. `--enable-eip8151` requires Prague-or-later rules
and Anvil's canonical Ethereum profile. It changes precompile `0x01` from a stateless ECRecover
to a stateful raw-code check, so Foundry also exposes `enable_eip8151 = true` and the matching
CLI flag on shared EVM options. The proposal has no assigned hard fork; Prague is the minimum
toolkit execution baseline, not a claim of protocol inclusion. Solc classifies high-level
`ecrecover` as `view` only under `@future` so purity analysis and SMT modeling account for this
state dependency. This flag is independent of Frame activation.

Only raw signed envelopes are accepted. Object-form requests containing `type: 0x6` or
`frames` are rejected, so `eth_call` cannot accidentally reinterpret a Frame transaction as
an ordinary call. `trace_rawTransaction` and `trace_replayTransaction` do execute the raw
Frame path. On transaction-hash forks, Anvil fetches and hash-checks canonical raw bytes
instead of trying to reconstruct unknown typed fields from JSON-RPC.

## Deliberate divergences and design notes

### Post-quantum verification is not shipped

EIP-8141 reserves signature schemes `0x03` through `0xff`, and the toolkit follows that
allocation. An ML-DSA experiment must use an `ARBITRARY` (`0x00`) entry with an empty
`signer`, then copy and verify the application-defined witness in a validation frame or
custom verifier. The proof must bind to the canonical transaction signature hash and the
account's authorization policy.

No canonical witness encoding, ML-DSA verifier, account, paymaster, signer identity, gas
schedule, or raw Anvil test is provided. See
[`contracts/docs/10-pq.md`](../contracts/docs/10-pq.md) for this boundary and the possible
future pure-function validation direction.

### `APPROVE` is spelled `approvetx` in Solidity and Yul

`approve` is the ERC-20 method name and appears in a very large share of deployed Solidity.
Registering it as a compiler builtin would break existing contracts that use it as a
function or identifier name. The opcode byte `0xaa` is unchanged, so bytecode is unaffected;
only the mnemonic differs.

`approve` remains usable as an ordinary identifier, even on `@future`. There is a regression
test pinning that at
`solidity/test/libyul/yulSyntaxTests/frame_transaction_approve_never_reserved.yul`.

### `SIGDATACOPY` is a separate native opcode (now upstream)

The standalone `SIGDATACOPY` instruction is part of the official upstream pin as of
2026-08-23. The history below explains why the compiler and VM forks use its fixed four-item
stack shape; it is no longer a toolkit-local EIP-8141 divergence.

The original draft overloaded `SIGPARAM`: params `0x00`–`0x03` took 2 operands and returned
1, while param `0x04` took 5 and returned none. Solidity's `InstructionInfo` and revm's
opcode table both require one fixed stack effect per opcode.

The confirmed split keeps `SIGPARAM` metadata-only and assigns `SIGDATACOPY` to `0xb5` with
fixed arity 4. Its order is `sigdatacopy(memOffset, dataOffset, length, signatureIndex)`,
exactly parallel to `FRAMEDATACOPY`.

### Why the split matters

Ethereum has consistently encoded stack shape in the opcode rather than a runtime operand:

- `LOG0`–`LOG4` is the identical problem — an operation with a variable number of stack
  items — solved with **five separate opcodes** (arity 2, 3, 4, 5, 6) rather than one `LOG`
  taking a topic count.
- `PUSH1`–`PUSH32`, `DUP1`–`DUP16`, `SWAP1`–`SWAP16` spend ~130 opcodes encoding arity into
  the opcode byte instead of accepting it as an operand.
- EOF does have variable-shape instructions, but keeps them statically analyzable: `DUPN` /
  `SWAPN` / `EXCHANGE` read an **immediate from the bytecode**, and `CALLF` / `RETF` derive
  arity from the type section. Never from a stack value.

Both mature implementations encode this assumption structurally: solc's `InstructionInfo` has
`int args; int ret;` and revm's opcode table declares `stack_io(n, m)`. Neither schema
can represent a variable-arity opcode, and both have covered every opcode across every fork.

The former EIP-8141 shape also broke its **own** convention: it allocated two opcodes for frame
data (`FRAMEDATALOAD` `0xb1`, `FRAMEDATACOPY` `0xb2`, mirroring `CALLDATALOAD` /
`CALLDATACOPY`) but overloaded one opcode for signature metadata and data. The native split
makes the instruction set uniform and statically representable.

**Forward compatibility with EOF is the strongest form of this argument.** The EVM tolerates
a runtime-determined arity today only because it has no bytecode validation: stack underflow
is a runtime halt, which is why a hand-written depth check can paper over it. EOF reverses
that — [EIP-5450](https://eips.ethereum.org/EIPS/eip-5450) requires the stack height at every
instruction to be **statically determinable at validation time** so underflowing code can be
rejected before execution. The fixed-arity split remains expressible under that rule.

**Prior art, for whoever picks this up.** Instructions with variable arity are common, but in
every statically-verified VM the count comes from an *immediate in the instruction stream*,
never from a runtime stack value: JVM `invokevirtual` (constant-pool descriptor) and
`multianewarray`; CPython `CALL_FUNCTION(argc)`, `BUILD_TUPLE(n)`, `UNPACK_SEQUENCE(n)`; Wasm
`call_indirect`; CIL `call`. Even EOF's own `DUPN`/`SWAPN`/`EXCHANGE` take immediates. Where
the count is genuinely dynamic, these VMs *box* it — CPython's `CALL_FUNCTION_EX` takes a
fixed number of stack items with the arguments packed into one tuple.

Taking the count off the stack is essentially confined to VMs without static verification:
Forth (`n ROLL`, `n PICK`, `EXECUTE`, where stack-effect comments are only comments) and the
Lua VM (`OP_CALL`/`OP_RETURN` with `B=0` meaning "to the runtime stack top", part of why
untrusted Lua bytecode is unsafe to load).

The precedent that should carry the most weight is Bitcoin Script's `OP_CHECKMULTISIG`, which
had precisely this shape — pop `n`, then `n` pubkeys, then `m`, then `m` signatures. It is
regarded as one of Script's worst corners, and Tapscript
([BIP-342](https://github.com/bitcoin/bips/blob/master/bip-0342.mediawiki)) **disabled it** in
favour of the fixed-arity `OP_CHECKSIGADD`. The one major chain that shipped a
stack-determined-arity opcode later removed it.

### `APPROVE` in a STATICCALL context

The spec has `APPROVE` mutating state (nonce increment, payer, `max_cost` collection) inside
a frame it also describes as a `STATICCALL`. The current pinned revm implementation permits
the opcode's transaction-scoped approval update while ordinary state-changing opcodes remain
blocked, making `APPROVE` the sole permitted mutation in a VERIFY frame.

The current specification explicitly grants this exception; it is not an unresolved
conflict between `STATICCALL` and `APPROVE`. Ordinary state-changing instructions remain
prohibited throughout VERIFY, including nested calls. The 2026-09-16 source review
confirmed this requirement is unchanged.

## Current wire compatibility

The old integrated devnet envelope with flat fee fields and a trailing
`recent_root_references` list is rejected. EIP-8250 now preserves the nested `fees` list;
EIP-8272 uses leading verifier-frame calldata and adds no transaction field or opcode.
Rebuild and re-sign old vectors. [spec/README.md](../spec/README.md) records the current
payload, selectors, gas changes and implementation boundaries.

## Solidity-side gaps

- **No Solidity-level syntax.** The opcodes are inline-assembly and Yul builtins only. There
  is no `block.`-style global, and no high-level `approve` statement. Everything goes through
  `assembly {}`.
- **Semantic and solver-backed tests are environment-limited.** solc's semantic suite needs
  `libevmone`, which is not installed. The latest non-semantic, no-SMT runs passed 5068 tests
  at the default EVM and 5039 at `@future`; version-inapplicable and semantic suites were
  skipped. EIP-8151's SMT fixtures compile, but this build has `USE_Z3=OFF` and no Z3/cvc5, so
  solver assertions were not run. Syntax, view/pure, gas, object-compiler, side-effect, and
  Yul-interpreter results above describe the historical baseline; see VERSIONS for current checks.
- **The `@future` EVM version is a placeholder.** When the proposals' activation rules
  are implemented in a named compiler EVM target, their gates in
  `liblangutil/EVMVersion.h` should move from `future()`.

## Spec status

EIP-8141 remains Draft and is SFI for Hegotá. The selected supporting drafts are PFI.
The exact sources, fork-inclusion evidence, and current implementation boundaries are in
[spec/README.md](../spec/README.md). `spec/EIP8141.md` is an exact upstream snapshot;
historical fixture notes are in `spec/TOOLKIT-FIXTURES.md`.

Run `tools/check-spec-drift.sh` to check all selected proposals and their tracked dependencies.
[VERSIONS.md](../VERSIONS.md) distinguishes the published toolchain pins from this working tree.
