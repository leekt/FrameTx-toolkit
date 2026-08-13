# Limitations and known divergences

Read this before planning work on top of the toolkit. Some of these will change what you
can attempt.

## The big one: no devnet path

**A frame transaction still cannot be submitted to a running node**, though the pool now
accepts them internally. Frame transactions can be *executed and inspected* through the Go
test harness; they cannot yet be gossiped or sent over RPC.

| Status | Component | Detail |
|---|---|---|
| Partial | Transaction pool | `core/txpool/frame_validation.go` implements the spec's structural rules: validation-prefix shape matching, `MAX_VERIFY_GAS` (counting signature verification), no atomic batch in the prefix, no VERIFY frame after it. A self-relay transaction reaches the pending queue. |
| Missing | Prefix simulation | The spec also requires simulating the prefix and rejecting banned opcodes, storage reads outside `tx.sender`, state writes and calls to non-existent contracts. Without it, an accepted transaction can still be invalidated by third-party state changes — the DoS vector the trace rules exist to close. |
| Missing | Paymaster support | The `[only_verify, pay]` prefix is recognised but rejected (`ErrFramePaymaster`). Admitting it safely needs per-payer reservation accounting plus canonical-paymaster code matching, neither of which exists. |
| Missing | JSON-RPC | `internal/ethapi/` — no way to send or read one over RPC. |
| Missing | Networking | `eth/protocols/eth/` — no gossip, no blob sidecar wrapper. |

RPC is the cheapest remaining step to an end-to-end demo. Prefix simulation is the largest,
and paymaster support depends on it.

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

**Forward compatibility with EOF is the strongest form of this argument.** The EVM tolerates
a runtime-determined arity today only because it has no bytecode validation: stack underflow
is a runtime halt, which is why a hand-written depth check can paper over it. EOF reverses
that — [EIP-5450](https://eips.ethereum.org/EIPS/eip-5450) requires the stack height at every
instruction to be **statically determinable at validation time** so underflowing code can be
rejected before execution. An instruction whose arity depends on a stack value is not
expressible under that rule. As specified, `SIGPARAM` could not appear in validated EOF code
without either excluding it or weakening EOF validation.

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
