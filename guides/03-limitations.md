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

This is worth raising with the EIP authors: no other EVM opcode varies its stack effect by
operand value, and it will be awkward for every fixed-arity toolchain, not just solc.

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
