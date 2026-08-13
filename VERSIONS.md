# Pinned versions

EIP-8141 is a **draft**. Everything in this toolkit is pinned to the exact
versions below so that a future spec revision can be diffed against a known
baseline instead of guessed at.

| Component | Pinned at | Date | Source |
|---|---|---|---|
| **EIP-8141 spec** | `064f49621d05ce25323def867a6a2ed9275d3570` | 2026-08-11 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8141.md` |
| **go-ethereum** | `81d88d96ae33571f57558eee9bba35062ac7d867` | 2026-08-13 | [leekt/go-ethereum](https://github.com/leekt/go-ethereum) — branch `fix/eip8141-frame-tx` |
| **solidity** | `9daabdb8d7b85777dac402796e3149d50a06be7c` | 2026-08-12 | [leekt/solidity](https://github.com/leekt/solidity) — branch `feat/eip8141-frame-opcodes` |
| **revm** | `e8b061b6e506428b51870c3314ed2cbc08a161fc` | 2026-08-13 | [leekt/revm](https://github.com/leekt/revm) — branch `feat/eip8141-frame-opcodes` |
| **foundry** | `1953409` on `feat/eip8141-frame-opcodes` | 2026-08-13 | [leekt/foundry](https://github.com/leekt/foundry) — patches all revm crates to the fork |

The spec text as of that commit is vendored at [`spec/EIP8141.md`](spec/EIP8141.md),
so the toolkit is self-contained and the diff is always available locally.

## Checking whether the spec moved

```bash
tools/check-spec-drift.sh
```

It fetches the current `EIPS/eip-8141.md` from `ethereum/EIPs` and diffs it
against the vendored copy. A non-empty diff means the implementations may need
revisiting — start with the checklist below.

## What to re-check when the spec changes

Ordered by how likely a spec revision is to invalidate it.

| Spec area | If it changes, revisit |
|---|---|
| Opcode numbers or stack layouts | `solidity/libevmasm/Instruction.{h,cpp}`, `go-ethereum/core/vm/frame_ops.go`, `revm/crates/bytecode/src/opcode.rs` + `revm/crates/interpreter/src/instructions/frame_tx.rs`, every example |
| `APPROVE` scope semantics | `go-ethereum/core/vm/frame_ops.go` (`FrameContext.Approve`), examples 03–06 |
| Default code behaviour | `go-ethereum/core/state_transition.go` (`runDefaultVerifyCode`), example 01 |
| Gas constants / formulas | `go-ethereum/params/protocol_params.go`, `core/types/tx_frame.go` (`GasLimits`) |
| Signature schemes or the canonical sig hash | `core/types/tx_frame.go` (`ComputeSigHash`, `ValidateSignature`) |
| Atomic batch rules | `go-ethereum/core/state_transition.go` (`executeFrame` batch loop) |
| Expiry verifier code or address | `go-ethereum/params/protocol_params.go`, `core/genesis.go` |
| Mempool rules | `go-ethereum/core/txpool/frame_validation.go` (structural rules only; no simulation) |

## Known divergences from the pinned spec

These are deliberate. See [`guides/03-limitations.md`](guides/03-limitations.md).

| Divergence | Why |
|---|---|
| The `APPROVE` opcode is spelled `approvetx` in Solidity/Yul | `approve` is the ERC-20 method name; reserving it would break a large share of existing contracts. The opcode byte `0xaa` is unchanged. |
| `SIGPARAM`'s 5-operand copy form is not a named builtin | Its stack arity depends on a runtime operand value, which no fixed-arity instruction model can express — see [the upstream note](guides/03-limitations.md#why-this-is-worth-raising-upstream). Reachable via `verbatim_5i_0o(hex"b4", ...)`. |
| Calldata priced per EIP-7623 (4/16), not EIP-7976 (64/64) | The EIP specifies 7623. The geth branch is otherwise post-Amsterdam, so frame transactions and other transactions in the same block price calldata differently. |
| Modelled as a standalone `frameTime` fork | EIP-8141 is not assigned to a named fork upstream. |
| No RPC or networking; partial transaction pool | The pool accepts self-relay frame transactions using the spec's structural prefix rules, but does not simulate the prefix and rejects paymaster prefixes. Without RPC there is still no way to submit one to a running node. |
