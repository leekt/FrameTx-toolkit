# Source pins and working-tree verification

EIP-8141, EIP-7819, EIP-7851, and EIP-8151 remain draft or pre-inclusion proposals. The root
repository records exact upstream bases so future changes can be diffed against known inputs,
alongside the published submodule commits that implement the current toolkit.

| Component | Pinned at | Date | Source |
|---|---|---|---|
| **EIP-8141 upstream base** | `064f49621d05ce25323def867a6a2ed9275d3570` | 2026-08-11 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8141.md` |
| **EIP-7819 upstream base** | `d420fc4b289e298682006b2ea09355065cf50f99` | 2026-04-09 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-7819.md` |
| **EIP-7851 upstream base** | `07f3bb3626d4db1f2ac501734fec5b3d32e185c5` | 2026-05-14 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-7851.md` |
| **EIP-8151 upstream base** | `bf7a4067f263bf7ce01c1511de48473e281d885d` | 2026-07-27 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8151.md` |
| **revm gitlink** | `2f96f6cb10d9649bbc81fbe3c3af4ea907eb8fba` | 2026-08-17 | [leekt/revm](https://github.com/leekt/revm) — branch `feat/native-sigdatacopy` |
| **foundry gitlink** | `db4c80aad096f674ece950323e20d3dcab882a54` | 2026-08-17 | [leekt/foundry](https://github.com/leekt/foundry) — branch `feat/frame-tx-txparam-context` |
| **solidity gitlink** | `bd2feb3527039628a9fa8a675e432ea2cf5975ec` | 2026-08-17 | [leekt/solidity](https://github.com/leekt/solidity) — branch `feat/eip8141-frame-opcodes` |

[`spec/EIP8141.md`](spec/EIP8141.md) is not an exact vendored snapshot. Its normative body is
the upstream base above with the local native `SIGDATACOPY` split. It retains the pinned
scalar payload, baseline modes, and baseline selectors. Its
[final appendix](spec/EIP8141.md#toolkit-appendix-non-normative-tooling-fixture-profile)
documents the EIP-8250/8272/7906-inspired host context as a non-normative fixture only; it
does not claim transaction-wire support for those extensions.

## Reproducibility status

The gitlinks above contain the implementation used by the verification matrix below. A clone
of this root revision can initialize those exact published commits, build patched solc, and
build Foundry against its immutable REVM pin.

Three forks, and deliberately not more: `foundry` patches all twelve revm crates to the
`revm` fork at `2f96f6cb10d9649bbc81fbe3c3af4ea907eb8fba` and patches no other upstream package.
`Cargo.lock` records that same immutable revision. Foundry disables the now-unused
`alloy-evm/rpc` feature in two crates because that upstream adapter constructs `TxEnv`
directly and cannot initialize EIP-7851's authentication marker. See
[guides/04-foundry.md](guides/04-foundry.md#how-the-context-reaches-the-evm) for why
that constraint shaped the design.

## Checking whether the spec moved

```bash
tools/check-spec-drift.sh
```

It fetches `EIPS/eip-8141.md` twice: once at the exact source pin above and once from current
`ethereum/EIPs` master. It diffs those two upstream files. The local overlay is reported as
such but is not used as the equality baseline, because its native split and appendix would
otherwise be misreported as upstream drift.

## What to re-check when the spec changes

| Spec area | If it changes, revisit |
|---|---|
| Opcode numbers | `revm/crates/bytecode/src/opcode.rs`, `solidity/libevmasm/Instruction.{h,cpp}` |
| Stack layouts or operand order | `revm/crates/interpreter/src/instructions/frame_tx.rs`, the arity table in `solidity/libevmasm/Instruction.cpp`, every account in `contracts/src/accounts` |
| `APPROVE` scope semantics | `frame_tx.rs` (the subset rule), `contracts/test/FrameTest.sol`, all account tests |
| `TXPARAM` / `FRAMEPARAM` / `SIGPARAM` parameter tables and `SIGDATACOPY` | `frame_tx.rs`, `guides/02-writing-accounts.md` |
| Non-normative extended context, `POST_TX`, or B6-B9 fixture behavior | the final appendix in `spec/EIP8141.md`, `FrameTxContext`, `setFrameTx`, `FrameTxLib.sol`, and `FrameTxLib.t.sol` |
| The frame context shape | `revm/crates/context/interface/src/host.rs` (`FrameTxContext`), the `setFrameTx` cheatcode, `FrameTest.sol` |
| Signature schemes or the canonical sig hash | Any account reading `SIGPARAM`, and the fixtures in `FrameTest.sol` |
| Anything about frame *transaction* execution | anvil: `foundry/crates/anvil/src/eth/backend/frame_tx.rs` and `crates/primitives/src/transaction/frame.rs`, plus the integration tests in `crates/anvil/tests/it/frame_tx.rs` |
| EIP-7819 address, gas, collision, code, nonce, or activation rules | `revm/crates/primitives/src/eip7819.rs`, `revm/crates/interpreter/src/instructions/host.rs`, `revm/crates/context/src/context.rs`, solc's instruction/version/gas metadata, and Anvil's `enable_eip7819` configuration/tests |
| EIP-7851 designation versions, sender/auth rules, opcode, gas, or activation | revm's bytecode/context/handler/interpreter EIP-7851 paths, solc's instruction/version/gas metadata, and Anvil's `enable_eip7851` configuration/admission/tests |
| EIP-8151 eligibility, ECRecover output/gas/warmth, or activation | `revm/crates/precompile/src/secp256k1.rs`, `revm/crates/handler/src/precompile_provider.rs`, Foundry's stateful precompile/replay/access-list paths, and solc's EVM-version/mutability/formal-model metadata |

## Local overlay and fixture differences

Within the EIP-8141 overlay, only native `SIGDATACOPY` changes the pinned normative body. The
B6-B9 allocation, extended context, provisional gas, and EIP-7851 opcode assignment below are
explicitly non-normative toolkit choices.

| Divergence | Why |
|---|---|
| The `APPROVE` opcode is spelled `approvetx` in Solidity and Yul | `approve` is the ERC-20 method name; reserving it as a compiler builtin would break a large share of existing contracts. The opcode byte `0xaa` is unchanged. |
| `SIGDATACOPY` is a standalone opcode at `0xb5` | This local normative split replaces pinned `SIGPARAM(0x04)` with fixed arity 4 and copy-style operand order. The normative body, solc fork, revm fork, and `FrameTxLib` apply it. |
| The tooling fixture assigns `RECENTROOTREFLOAD` through `EVENTDATACOPY` to `0xb6`-`0xb9` | This is a local compiler/interpreter allocation after native `SIGDATACOPY`, documented only in the non-normative appendix. It does not assign final upstream opcodes or transaction fields. |
| Fixture `TXTRACE` uses flat gas `100`; `TXDIFF` uses `100` as its warm total | Direct TXDIFF selectors access host state on both diff hits and misses. Only the applicable EIP-2929 cold premium is added. The tests pin a local experiment; no consensus gas schedule is claimed. |
| The frame context is an `Arc`-backed scoped thread-local, not part of `TxEnv` | Putting it on shared revm transaction types broke unrelated crates. Scoped installation restores nested contexts on every return path; a native host can instead override `Host::frame_context()`. |
| Anvil activation is explicit and scalar-only | Frame transactions are disabled by default, require `--enable-frame-transactions`, and are rejected on Amsterdam state-gas and non-Ethereum execution profiles. Enabled pre-Amsterdam Ethereum nodes install the canonical `0x8141` verifier after inherited source replay. |
| Anvil already exposes the EIP-7997 factory behavior | The exact `0x4e59...956c` address and runtime are installed by Anvil's existing default CREATE2 deployer support. It is not Glamsterdam-gated and the injected account keeps nonce `0`, so this is functional reuse rather than exact EIP-7997 activation-state modeling. |
| EIP-7819 activation is explicit | Solc exposes `setdelegate(salt, target)` only at `@future`. REVM additionally requires a default-off configuration bit and Prague-or-later rules; Anvil exposes that bit as `--enable-eip7819` and preserves it across reset. |
| EIP-7851 uses toolkit-local opcode `0xf7` | The pinned EIP still declares `SETSELFDELEGATE_OPCODE = TBD`, while `0xf6` is already assigned to EIP-7819. The compiler, VM, and tests consistently label `0xf7` non-normative and must move together when upstream allocates a byte. |
| EIP-7851 activation is explicit and Ethereum-only | Solc exposes `setselfdelegate(target)` only at `@future`. REVM requires a default-off bit and Prague-or-later rules; Anvil exposes `--enable-eip7851` only on its canonical Ethereum profile and preserves it across reset. ECDSA-disabled senders remain usable by object-form simulation, impersonation, and Frame custom authentication, but signed Ethereum envelopes are rejected. |
| EIP-8151 activation is explicit and Ethereum-only | The proposal has no assigned execution fork. REVM and Foundry use a default-off bit under Prague-or-later rules without inventing a Hegotá `SpecId`; Anvil exposes `--enable-eip8151` only on its canonical Ethereum profile. Solc changes high-level `ecrecover` from `pure` to `view` only at `@future`. |

## Working-tree verification

These results were rerun on 2026-08-17 against the source content in the published submodule
commits above. Foundry's final clean dependency check used the immutable REVM revision recorded
in both its manifest and lockfile.

| Suite | Result |
|---|---|
| `contracts/` — debug `forge test` | 83 passed, 0 failed, 0 skipped |
| `foundry` — `foundry-primitives --lib` | 61 passed, 0 failed |
| `foundry` — anvil `frame_tx` backend units | 38 passed, 0 failed |
| `foundry` — `foundry-evm-core --lib` | 80 passed, 0 failed |
| `foundry` — anvil library tests (excluding 3 process-exiting Clap tests) | 149 passed, 0 failed |
| `foundry` — anvil `frame_tx::` integrations | 27 passed, 0 failed |
| `foundry` — anvil EIP-7819 CLI unit | 1 passed, 0 failed |
| `foundry` — anvil EIP-7819 integrations | 4 passed, 0 failed |
| `foundry` — anvil dedicated EIP-7851 integrations | 9 passed, 0 failed; Frame coexistence also passed in the Frame suite |
| `foundry` — anvil EIP-8151 integrations | 8 passed, 0 failed |
| `foundry` — `foundry-cheatcodes --lib` | 70 passed, 0 failed |
| `foundry` — isolated `FrameTx.t.sol` fixture | 2 passed, 0 failed |
| `foundry` — anvil all-target/all-feature clippy with `-D warnings` | Blocked by 8 pre-existing Frame-path diagnostics outside EIP-7819/EIP-7851/EIP-8151 |
| `revm` — `cargo test --workspace --lib` | 518 passed, 1 ignored |
| `revm` — workspace lib tests without default features | 518 passed, 1 ignored |
| `revm` — workspace all-feature clippy with `-D warnings` | Passed |
| `revm` — exact `revm-precompile ecrecover_code_restriction` regression | 1 passed, 0 failed |
| `solidity` — default-EVM `isoltest` (non-semantic, no SMT) | 5068 passed, 0 failed; 106 version-inapplicable tests skipped; semantic suite disabled |
| `solidity` — `@future` `isoltest` (non-semantic, no SMT) | 5039 passed, 0 failed; 135 version-inapplicable tests skipped; semantic suite disabled |
| `solidity` — focused EIP-7819 compiler/Yul fixtures | 7 passed, 0 failed |
| `solidity` — focused EIP-7851 compiler/Yul fixtures | 8 passed, 0 failed |
| `solidity` — focused EIP-8151 mutability fixtures | 4 default and 4 `@future` cases passed |
| `solidity` — EIP-8151 solver-backed SMT fixtures | Not run: this build has `USE_Z3=OFF`, and Z3/cvc5 are unavailable; the fixtures compile through `@future` code generation |
