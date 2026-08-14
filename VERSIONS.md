# Pinned versions

EIP-8141 is a **draft**. Everything here is pinned to an exact commit so a future
spec revision can be diffed against a known baseline rather than guessed at.

| Component | Pinned at | Date | Source |
|---|---|---|---|
| **EIP-8141 spec** | `064f49621d05ce25323def867a6a2ed9275d3570` | 2026-08-11 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8141.md` |
| **revm** | `ce7886e` | 2026-08-13 | [leekt/revm](https://github.com/leekt/revm) — branch `feat/eip8141-frame-opcodes` |
| **foundry** | `9a2aa86` | 2026-08-14 | [leekt/foundry](https://github.com/leekt/foundry) — branch `feat/eip8141-frame-opcodes` |
| **solidity** | `9daabdb8d7b85777dac402796e3149d50a06be7c` | 2026-08-12 | [leekt/solidity](https://github.com/leekt/solidity) — branch `feat/eip8141-frame-opcodes` |

The spec text as of that commit is vendored at [`spec/EIP8141.md`](spec/EIP8141.md),
so the toolkit is self-contained and the diff is always available locally.

Three forks, and deliberately not more: `foundry` patches all twelve revm crates to
the `revm` fork and touches nothing else in the dependency graph. See
[guides/04-foundry.md](guides/04-foundry.md#how-the-context-reaches-the-evm) for why
that constraint shaped the design.

## Checking whether the spec moved

```bash
tools/check-spec-drift.sh
```

It fetches the current `EIPS/eip-8141.md` from `ethereum/EIPs` and diffs it against
the vendored copy. A non-empty diff means the implementations may need revisiting.

## What to re-check when the spec changes

| Spec area | If it changes, revisit |
|---|---|
| Opcode numbers | `revm/crates/bytecode/src/opcode.rs`, `solidity/libevmasm/Instruction.{h,cpp}` |
| Stack layouts or operand order | `revm/crates/interpreter/src/instructions/frame_tx.rs`, the arity table in `solidity/libevmasm/Instruction.cpp`, every account in `contracts/src/accounts` |
| `APPROVE` scope semantics | `frame_tx.rs` (the subset rule), `contracts/test/FrameTest.sol`, all account tests |
| `TXPARAM` / `FRAMEPARAM` / `SIGPARAM` parameter tables | `frame_tx.rs`, `guides/02-writing-accounts.md` |
| The frame context shape | `revm/crates/context/interface/src/host.rs` (`FrameTxContext`), the `setFrameTx` cheatcode, `FrameTest.sol` |
| Signature schemes or the canonical sig hash | Any account reading `SIGPARAM`, and the fixtures in `FrameTest.sol` |
| Anything about frame *transaction* execution | anvil: `foundry/crates/anvil/src/eth/backend/frame_tx.rs` and `crates/primitives/src/transaction/frame.rs`, plus the integration tests in `crates/anvil/tests/it/frame_tx.rs` |

## Known divergences from the pinned spec

These are deliberate.

| Divergence | Why |
|---|---|
| The `APPROVE` opcode is spelled `approvetx` in Solidity and Yul | `approve` is the ERC-20 method name; reserving it as a compiler builtin would break a large share of existing contracts. The opcode byte `0xaa` is unchanged. |
| `SIGPARAM`'s 5-operand copy form is not a named builtin | Its stack arity depends on a runtime operand value, which no fixed-arity instruction model can express — solc and revm both declare arity as a constant. See [the upstream note](guides/03-limitations.md#why-this-is-worth-raising-upstream). Reachable via `verbatim_5i_0o(hex"b4", ...)`. |
| The frame context is a thread-local, not part of `TxEnv` | Putting it on shared revm types broke unrelated crates. A host that models frame transactions natively overrides `Host::frame_context()` and ignores the slot. |
| Per-frame receipts not exposed over RPC | anvil executes frame transactions and mines them, but the `[status, gas_used, logs]` sub-receipts are not yet queryable. |

## Verified state at these pins

| Suite | Result |
|---|---|
| `contracts/` — `forge test` | 53 passed, 0 failed |
| `foundry` — anvil frame tx integration | 11 passed, 0 failed |
| `foundry` — envelope unit tests | 17 passed, 0 failed |
| `revm` — `cargo test --workspace --lib` | 0 failures, clean with `--all-features` |
| `solidity` — `isoltest` (non-semantic) | 5062 passed, 0 failed |
