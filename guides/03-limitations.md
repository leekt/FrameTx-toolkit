# Limitations and known divergences

Read this before planning work on top of the toolkit. Some of these will change what you
can attempt.

## The big one: no devnet path

**A frame transaction cannot be submitted to a running node.** Only the execution layer is
implemented. Frame transactions can be *executed and inspected* through the Go test harness;
they cannot be gossiped, pooled, or sent over RPC.

| Missing | Consequence | Where it would go |
|---|---|---|
| Transaction pool | Cannot submit a frame transaction at all | `core/txpool/` — the EIP's entire Mempool section, including `MAX_VERIFY_GAS` and the four recognised validation prefixes. `params.FrameTxMaxVerifyGas` and `FrameTxMaxNonCanonicalPM` are defined but unused |
| JSON-RPC | Cannot send or read one over RPC | `internal/ethapi/` |
| Networking | No gossip, no blob sidecar wrapper | `eth/protocols/eth/` |

The txpool is the highest-value next step: with it plus a thin RPC path, contracts become
testable against a real node.

The mempool rules are also the largest single chunk of unimplemented spec, and they are not
cosmetic — they are the DoS defence for validation frames. Anything you build here should be
assumed to face additional constraints once they land.

## Deliberate divergences

### `APPROVE` is spelled `approvetx` in Solidity and Yul

`approve` is the ERC-20 method name and appears in a very large share of deployed Solidity.
Registering it as a compiler builtin would break existing contracts that use it as a
function or identifier name. The opcode byte `0xaa` is unchanged, so bytecode is unaffected;
only the mnemonic differs.

`approve` remains usable as an ordinary identifier, even on `@future`. There is a regression
test pinning that: `test/libyul/yulSyntaxTests/frame_transaction_approve_never_reserved.yul`.

### `SIGPARAM`'s copy form is not a named builtin

`SIGPARAM` has an operand-dependent stack effect: params `0x00`–`0x03` take 2 operands and
return 1, while param `0x04` takes 5 and returns none. Solidity's `InstructionInfo` is
fixed-arity and cannot express that, so only the metadata form is a builtin. The copy form
is reachable via `verbatim_5i_0o(hex"b4", ...)` in standalone Yul.

### Why this is worth raising upstream

`SIGPARAM` appears to be the first EVM instruction whose **stack arity depends on a runtime
operand value**. Ethereum has consistently gone the other way, at real cost:

- `LOG0`–`LOG4` is the identical problem — an operation with a variable number of stack
  items — solved with **five separate opcodes** (arity 2, 3, 4, 5, 6) rather than one `LOG`
  taking a topic count.
- `PUSH1`–`PUSH32`, `DUP1`–`DUP16`, `SWAP1`–`SWAP16` spend ~130 opcodes encoding arity into
  the opcode byte instead of accepting it as an operand.
- EOF does have variable-shape instructions, but keeps them statically analyzable: `DUPN` /
  `SWAPN` / `EXCHANGE` read an **immediate from the bytecode**, and `CALLF` / `RETF` derive
  arity from the type section. Never from a stack value.

Both mature implementations encode this assumption structurally: solc's `InstructionInfo` has
`int args; int ret;` and geth's `operation` has `minStack int; maxStack int;`. Neither schema
can represent a variable-arity opcode, and both have covered every opcode across every fork.

EIP-8141 also breaks its **own** convention here: it allocates two separate opcodes for frame
data (`FRAMEDATALOAD` `0xb1`, `FRAMEDATACOPY` `0xb2`, mirroring `CALLDATALOAD` /
`CALLDATACOPY`) but overloads a single opcode for signature data. `0xb5` onward is
unallocated, so there is no opcode-space pressure justifying the difference.

**Suggested fix:** split the copy form into its own opcode, e.g. `SIGDATACOPY` at `0xb5` with
fixed arity 4 (`memOffset, dataOffset, length, signatureIndex`) — exactly parallel to
`FRAMEDATACOPY`. This costs one opcode from an unallocated range and makes the instruction
set uniform and representable in every fixed-arity toolchain.

The cost of not doing so is not hypothetical: it produced two defects in this toolkit. solc
can only expose one of the two forms as a builtin, and geth's interpreter needed an explicit
stack-depth guard where `minStack` could only promise two operands — without it, three bytes
of bytecode panicked the node.

### Calldata pricing follows EIP-7623, not EIP-7976

EIP-8141 specifies EIP-7623 pricing (`STANDARD_TOKEN_COST` 4, floor 10). The geth branch is
otherwise post-Amsterdam, which reprices calldata to 64/64 under EIP-7976. The
implementation follows the EIP text, so **frame transactions and other transactions in the
same block price calldata differently**. Flipping this is one constant in
`core/types/tx_frame.go` (`GasLimits`).

### Modelled as a standalone `frameTime` fork

EIP-8141 is not assigned to a named fork upstream, so the geth branch introduces its own
`frameTime`, gated on Bogota. If the EIP is scheduled into a real fork, this should be
folded into that fork's activation instead.

### `APPROVE` in a STATICCALL context

The spec has `APPROVE` mutating state (nonce increment, payer, `max_cost` collection) inside
a frame it also describes as a `STATICCALL`. This implementation resolves it the way the
spec text intends: `APPROVE`'s writes go directly to the StateDB and bypass the
interpreter's write-protection guards, making it the sole permitted state change in a VERIFY
frame.

Other clients may diverge here until the authors clarify. If you are writing something that
depends on the exact boundary, treat it as unsettled.

## Solidity-side gaps

- **No Solidity-level syntax.** The opcodes are inline-assembly and Yul builtins only. There
  is no `block.`-style global, and no high-level `approve` statement. Everything goes through
  `assembly {}`.
- **Semantic tests not run.** solc's semantic test suite needs `libevmone`, which is not
  installed; 1509 tests are skipped. Syntax, view/pure and Yul tests all pass.
- **The `@future` EVM version is a placeholder.** When EIP-8141 gets a real fork name, the
  gate in `liblangutil/EVMVersion.h` (`hasFrameTransaction()`) should move to it.

## Spec status

EIP-8141 is a **Draft** (created 2026-01-29). It is not final and details have already
shifted — several third-party write-ups describe an older opcode set (`TXPARAMLOAD` /
`TXPARAMSIZE` / `TXPARAMCOPY`) and inverted `APPROVE` scope values. **Always check the spec
in `ethereum/EIPs`, not a summary.**

Run `tools/check-spec-drift.sh` to see whether the pinned spec has moved, and consult
[VERSIONS.md](../VERSIONS.md) for the map from spec areas to affected code.
