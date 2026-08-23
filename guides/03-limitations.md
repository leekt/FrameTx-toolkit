# Limitations and known divergences

Read this before planning work on top of the toolkit. Some of these will change what you
can attempt.

## The big one: only the baseline wire path exists

With `--enable-frame-transactions`, the patched Foundry commit accepts a baseline
type-`0x06` envelope through Anvil's `eth_sendRawTransaction`, mines it, and executes its
frames. This is a real local-node path, not a Go-only harness. It does not implement the
EIP-8250/8272/7906-inspired fixture fields on the wire, public-mempool policy, or peer gossip.

| Status | Component | Detail |
|---|---|---|
| Implemented | Baseline Anvil RPC | Decode, validate, mine, retrieve, trace, and replay raw type-`0x06` transactions (scalar nonce, `fees`/`limits` envelope); atomic batches, default code, canonical raw-byte fork replay, and transaction-hash forks are covered by [`frame_tx.rs`](../foundry/crates/anvil/tests/it/frame_tx.rs). |
| Implemented | Frame receipts | Consensus receipt encoding and trie roots include the payer and ordered `[status, gas_used, logs]` frame results; RPC receipts expose these as `payer` and `frameReceipts`. |
| Implemented | Expiry activation | Enabled nodes install the canonical verifier at `0x8141` after source replay, and memory/fork resets restore it. |
| Experimental | Toolkit-local ML-DSA-44 | Native pure-mode FIPS 204 verification at upstream-reserved scheme `0x03`, exact 3,732-byte wire, 50,000-gas placeholder, dedicated account/paymaster policy tests, and a raw production-account Anvil path. This is experimental and non-portable. |
| Missing | Fixture-inspired wire/state integration | No keyed-nonce list/state, recent-root list/verification, trace construction, or `POST_TX` suffix execution. Those fields exist only in synthetic `setFrameTx` fixtures. |
| Missing | Prefix policy | The validation-prefix simulation and DoS rules from the spec are not implemented as a public transaction-pool admission policy. |
| Partial | Sponsorship RPC path | A raw-RPC default-code sponsor is covered end to end; a contract `pay` frame and canonical-paymaster pool accounting are not. |
| Known divergence | Fee-field width | Upstream admits fee scalars below `2**256`. The Frame decoder represents them as 256-bit values, but the current Alloy/REVM transaction APIs are `u128`, so Foundry validation rejects any fee field above `u128::MAX`. |
| Partial | EIP-7997 factory | Anvil already installs the exact deterministic-factory address and runtime. It is available independently of Glamsterdam and has nonce `0`, not the activation-state nonce `1`. |
| Experimental opt-in | EIP-7819 `SETDELEGATE` | Solc `@future`, REVM, and explicit Anvil activation cover exact location/code, Prague gating, gas/refund, static mode, collision, clearing, nonce, warmth, reset, and immediate-effect behavior. |
| Experimental opt-in | EIP-7851 code-controlled delegation | Solc `@future`, REVM, and explicit Ethereum-only Anvil activation cover both designation versions, redelegation, sender and authorization rejection, gas/static/revert behavior, simulations, impersonation, reset, and Frame coexistence. Opcode `0xf7` is a non-normative local assignment because upstream remains TBD. |
| Experimental opt-in | EIP-8151 code-restricted ECRecover | Solc `@future`, REVM, and explicit Ethereum-only Foundry/Anvil activation cover exact raw-code eligibility, malformed input, output, gas, warmth, rollback, replay, overrides, access-list inference, reset, and EIP-7851 transitions. No named-fork activation or official EEST vectors exist. |
| Missing | Networking | No frame-transaction gossip or blob-sidecar wrapper is implemented. |

[VERSIONS.md](../VERSIONS.md#reproducibility-status) and the root gitlinks record this
reproducible current-spec stack. All four submodules use the pushed branch
`feat/eip8141-current-spec`: Solidity `cc3e100a84ab68aca75a2b48e576cfbcc7237caf`, revm
`cad0e9fc012f790719791ff274b76eb852689559`, foundry-core
`f415f6fef0a62f44c7faa83daa8e37b14f0e009b`, and Foundry
`ffe76454940945b3b8ae6c7a6a0ae2939b4ff126`. Their respective upstream bases are
`f985208342dc9d695a9097caf8206b11024df979`, `17a323dac0f893aef6a29d48692185495b366149`,
`78e5b57f86986eabd969a5fdf238b8159f7086fd`, and
`8bb78aeceda2eca7837d385e4f5bd39d6fc8bc71`. Foundry promotion passed 30/30 primitives,
44/44 Anvil unit, and 31/31 Anvil integration tests. A fresh recursive clone checks out these
exact revisions.

## Activation and execution profiles

Frame transactions are off by default. `--enable-frame-transactions` enables the
profile only for Ethereum hard forks before Amsterdam. OP Stack, Tempo, Monad, and Amsterdam
state-gas profiles reject type `0x06` at submission instead of allowing it to reach a
partially compatible executor.

EIP-7819 is separately disabled by default. `--enable-eip7819` activates opcode `0xf6` only
under Prague-or-later rules; pre-Prague execution still halts as not activated. The flag does
not enable Frame transactions, and `--enable-frame-transactions` does not enable EIP-7819.
Solc exposes the matching `setdelegate(salt, target)` builtin only under experimental
`@future`, because the draft still has no assigned compiler fork.

EIP-7851 is also disabled by default. `--enable-eip7851` is accepted only on Anvil's canonical
Ethereum execution profile and requires Prague-or-later rules. Solc exposes
`setselfdelegate(target)` only under `@future`. The pinned EIP does not assign an opcode; this
toolkit uses provisional `0xf7`, so emitted bytecode is not portable and must be regenerated
when upstream assigns a byte. The EIP-7851 flag does not imply either EIP-7819 or Frame
activation, though all three can coexist on the supported Ethereum profile.

EIP-8151 is likewise disabled by default. `--enable-eip8151` requires Prague-or-later rules
and Anvil's canonical Ethereum profile. It changes precompile `0x01` from a stateless ECRecover
to a stateful raw-code check, so Foundry also exposes `enable_eip8151 = true` and the matching
CLI flag on shared EVM options. The proposal has no assigned hard fork; Prague is the minimum
toolkit execution baseline, not a claim of protocol inclusion. Solc classifies high-level
`ecrecover` as `view` only under `@future` so purity analysis and SMT modeling account for this
state dependency. This flag is independent of Frame, EIP-7819, and EIP-7851 activation.

Only raw signed envelopes are accepted. Object-form requests containing `type: 0x6` or
`frames` are rejected, so `eth_call` cannot accidentally reinterpret a Frame transaction as
an ordinary call. `trace_rawTransaction` and `trace_replayTransaction` do execute the raw
Frame path. On transaction-hash forks, Anvil fetches and hash-checks canonical raw bytes
instead of trying to reconstruct unknown typed fields from JSON-RPC.

## Deliberate divergences and design notes

### ML-DSA-44 scheme `0x03` is toolkit-local

Upstream EIP-8141 reserves signature scheme `0x03`. The patched host assigns it to an
experimental ML-DSA-44 profile so native post-quantum policy can be tested before an
upstream wire is chosen. Its raw field is exactly `signature[2420] || publicKey[1312]`, its
identity is `low20(keccak256(0x03 || publicKey))`, it verifies pure FIPS 204 with an empty
context over the existing 32-byte FrameTx message, and it carries a provisional 50,000-gas
verification charge.

This is a consensus difference, not a convenience encoding: an upstream client rejects the
scheme, and a future upstream allocation may conflict. The RustCrypto implementation is
pinned but explicitly unaudited. The exact decoder, advisory note, gas/size consequences,
contracts, default-code boundary, and tests are in
[`contracts/docs/10-pq.md`](../contracts/docs/10-pq.md).

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

Other clients may diverge here until the authors clarify. If you are writing something that
depends on the exact boundary, treat it as unsettled.

## Solidity-side gaps

- **No Solidity-level syntax.** The opcodes are inline-assembly and Yul builtins only. There
  is no `block.`-style global, and no high-level `approve` statement. Everything goes through
  `assembly {}`.
- **Semantic and solver-backed tests are environment-limited.** solc's semantic suite needs
  `libevmone`, which is not installed. The latest non-semantic, no-SMT runs passed 5068 tests
  at the default EVM and 5039 at `@future`; version-inapplicable and semantic suites were
  skipped. EIP-8151's SMT fixtures compile, but this build has `USE_Z3=OFF` and no Z3/cvc5, so
  solver assertions were not run. Syntax, view/pure, gas, object-compiler, side-effect, and
  Yul-interpreter EIP-7819/EIP-7851 fixtures passed.
- **The `@future` EVM version is a placeholder.** When EIP-8141, EIP-7819, EIP-7851, or
  EIP-8151 gets a real fork assignment, its gate in `liblangutil/EVMVersion.h` should move from
  `future()`.

## Spec status

EIP-8141 is a **Draft** (created 2026-01-29), with an open official
[`execution-specs` tracker](https://github.com/ethereum/execution-specs/issues/2829) in the
[Bogota milestone](https://github.com/ethereum/execution-specs/milestone/29). It is not final
and details have already shifted — several third-party write-ups describe an older opcode set (`TXPARAMLOAD` /
`TXPARAMSIZE` / `TXPARAMCOPY`) and inverted `APPROVE` scope values. Check both upstream and
the local implementation overlay rather than relying on a summary.

Run `tools/check-spec-drift.sh` to compare current upstream EIP-8141 with exact official pin
`f767a1e8078e17c9b381a91d35a09492189ede1b`. [`spec/EIP8141.md`](../spec/EIP8141.md)
contains that current-master normative body, the non-normative ML-DSA-44 scheme `0x03`,
explanatory toolkit notes, and a separate non-normative tooling-fixture appendix; none of
those local deltas is the checker's byte-for-byte baseline.
Consult [VERSIONS.md](../VERSIONS.md) for the current stack's map from spec areas to affected
code.

For rollout planning rather than implementation details, see
[the migration guide](05-migration.md).
