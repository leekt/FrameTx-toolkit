# Source pins and working-tree verification

EIP-8141, EIP-7819, EIP-7851, and EIP-8151 remain draft or pre-inclusion proposals. The root
repository records exact upstream bases so future changes can be diffed against known inputs,
alongside the submodule state that implements the current toolkit.

| Component | Pinned at | Date | Source |
|---|---|---|---|
| **EIP-8141 upstream base** | `13d1b37672b8fb321c7e880b521cfe375683c9e4` | 2026-08-17 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8141.md` |
| **EIP-8141 SIGDATACOPY split** | PR [ethereum/EIPs#12187](https://github.com/ethereum/EIPs/pull/12187) at `687f6c55a21cac327f60de9c164d59446b91ef97` | 2026-08-18 | `lightclient/EIPs@frames-sigdatacopy` |
| **EIP-7819 upstream base** | `d420fc4b289e298682006b2ea09355065cf50f99` | 2026-04-09 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-7819.md` |
| **EIP-7851 upstream base** | `07f3bb3626d4db1f2ac501734fec5b3d32e185c5` | 2026-05-14 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-7851.md` |
| **EIP-8151 upstream base** | `bf7a4067f263bf7ce01c1511de48473e281d885d` | 2026-07-27 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8151.md` |
| **revm gitlink** | `7f08164fc954021eae96bbc75c675486ff775f82` | 2026-08-18 | [leekt/revm](https://github.com/leekt/revm) — branch `feat/native-sigdatacopy` |
| **foundry gitlink** | `fcec1e9335ffd966da07c524080bb85b9b3e50d5` | 2026-08-18 | [leekt/foundry](https://github.com/leekt/foundry) — branch `feat/frame-tx-txparam-context` |
| **solidity gitlink** | `bd2feb3527039628a9fa8a675e432ea2cf5975ec` | 2026-08-17 | [leekt/solidity](https://github.com/leekt/solidity) — branch `feat/eip8141-frame-opcodes` (no change needed for the master-spec rebase: selectors are runtime data) |
| **foundry-core gitlink** | `3a0ad16e2c154c8131fd2791f418f561e1347ef2` | 2026-08-18 | [leekt/foundry-core](https://github.com/leekt/foundry-core) — branch `feat/evm-version-future`, based on `foundry-rs/foundry-core@d61ff900` |

[`spec/EIP8141.md`](spec/EIP8141.md) is not an exact vendored snapshot. Its normative body is
the upstream base above with the native `SIGDATACOPY` split applied exactly as in
[ethereum/EIPs#12187](https://github.com/ethereum/EIPs/pull/12187): `SIGDATACOPY` is a
standalone opcode at `0xb5` and `SIGPARAM(0x03)` reports the signature length for `ARBITRARY`
entries only. The body carries the master-spec envelope — `fees` and `limits` sublists,
EIP-8037 state-gas budgets, two-dimensional receipts, `FRAME_TX_INTRINSIC_COST = 12000`,
`TX_VALUE_COST`, and the EIP-7825 execution cap. Its
[final appendix](spec/EIP8141.md#toolkit-appendix-non-normative-tooling-fixture-profile)
documents the EIP-8250/8272/7906-inspired host context as a non-normative fixture only; it
does not claim transaction-wire support for those extensions.

## Reproducibility status

A clone of this root revision initializes the exact submodule commits recorded by its
gitlinks, builds patched solc, and builds Foundry against its immutable REVM and
foundry-core pins.

Four forks, and deliberately not more: `foundry` patches all twelve revm crates to the
`revm` fork at `7f08164fc954021eae96bbc75c675486ff775f82`, and repoints its existing
foundry-core patch (`foundry-compilers`, `foundry-block-explorers`, `foundry-fork-db`) to
the `foundry-core` fork, whose only change is the experimental `@future` EVM version in
the compilers crates. That is what lets `forge build` compile the frame contracts natively
(`evm_version = "@future"` plus `experimental = true` drive the patched solc over standard
JSON — solc's `settings.experimental` and foundry's `experimental` config key already
existed upstream). `Cargo.lock` records those immutable revisions, which are the commits
the `revm` and `foundry-core` gitlinks pin. Foundry disables the now-unused
`alloy-evm/rpc` feature in two crates
because that upstream adapter constructs `TxEnv` directly and cannot initialize EIP-7851's
authentication marker. See
[guides/04-foundry.md](guides/04-foundry.md#how-the-context-reaches-the-evm) for why that
constraint shaped the design.

## Checking whether the spec moved

```bash
tools/check-spec-drift.sh
```

It fetches `EIPS/eip-8141.md` twice: once at the exact source pin above and once from current
`ethereum/EIPs` master. It diffs those two upstream files. The local overlay is reported as
such but is not used as the equality baseline, because its native split and appendix would
otherwise be misreported as upstream drift. Once PR #12187 merges, the only expected local
delta against master is the appendix.

## What to re-check when the spec changes

| Spec area | If it changes, revisit |
|---|---|
| Opcode numbers | `revm/crates/bytecode/src/opcode.rs`, `solidity/libevmasm/Instruction.{h,cpp}` |
| Stack layouts or operand order | `revm/crates/interpreter/src/instructions/frame_tx.rs`, the arity table in `solidity/libevmasm/Instruction.cpp`, every account in `contracts/src/accounts` |
| `APPROVE` scope semantics | `frame_tx.rs` (the subset rule), `contracts/test/FrameTest.sol`, all account tests |
| `TXPARAM` / `FRAMEPARAM` / `SIGPARAM` parameter tables and `SIGDATACOPY` | `frame_tx.rs`, `guides/02-writing-accounts.md`, `FrameTxLib.sol` (fixture selectors live at `0x80+` so newly assigned normative selectors never collide) |
| Wire format, `fees`/`limits` lists, or the signature hash | `foundry/crates/primitives/src/transaction/frame.rs` (RLP + pinned vectors), anvil `frame_tx.rs`, the `setFrameTx` cheatcode structs, `FrameTest.sol` |
| Gas constants, EIP-7825 cap, or EIP-8037 charge points | `frame.rs` `gas` module and `gas_limits()`, anvil `run_frames` settlement, `revm/crates/interpreter` |
| Receipt shape | `foundry/crates/primitives/src/transaction/receipt.rs` (`FrameReceipt` and the pinned hex vector), anvil receipts |
| Non-normative extended context, `POST_TX`, or B6-B9 fixture behavior | the final appendix in `spec/EIP8141.md`, `FrameTxContext`, `setFrameTx`, `FrameTxLib.sol`, and `FrameTxLib.t.sol` |
| The frame context shape | `revm/crates/context/interface/src/host.rs` (`FrameTxContext`), the `setFrameTx` cheatcode, `FrameTest.sol` |
| Signature schemes or the canonical sig hash | Any account reading `SIGPARAM`, and the fixtures in `FrameTest.sol` |
| Anything about frame *transaction* execution | anvil: `foundry/crates/anvil/src/eth/backend/frame_tx.rs` and `crates/primitives/src/transaction/frame.rs`, plus the integration tests in `crates/anvil/tests/it/frame_tx.rs` |
| EIP-7819 address, gas, collision, code, nonce, or activation rules | `revm/crates/primitives/src/eip7819.rs`, `revm/crates/interpreter/src/instructions/host.rs`, `revm/crates/context/src/context.rs`, solc's instruction/version/gas metadata, and Anvil's `enable_eip7819` configuration/tests |
| EIP-7851 designation versions, sender/auth rules, opcode, gas, or activation | revm's bytecode/context/handler/interpreter EIP-7851 paths, solc's instruction/version/gas metadata, and Anvil's `enable_eip7851` configuration/admission/tests |
| EIP-8151 eligibility, ECRecover output/gas/warmth, or activation | `revm/crates/precompile/src/secp256k1.rs`, `revm/crates/handler/src/precompile_provider.rs`, Foundry's stateful precompile/replay/access-list paths, and solc's EVM-version/mutability/formal-model metadata |

## Local overlay and fixture differences

Within the EIP-8141 overlay, only native `SIGDATACOPY` changes the pinned normative body,
and that change is byte-for-byte the pending upstream fix (PR #12187). The B6-B9 allocation,
the `0x80+` fixture selectors, extended context, provisional gas, and the EIP-7851 opcode
assignment below are explicitly non-normative toolkit choices.

| Divergence | Why |
|---|---|
| The `APPROVE` opcode is spelled `approvetx` in Solidity and Yul | `approve` is the ERC-20 method name; reserving it as a compiler builtin would break a large share of existing contracts. The opcode byte `0xaa` is unchanged. |
| `SIGDATACOPY` is a standalone opcode at `0xb5`; `SIGPARAM(0x03)` is ARBITRARY-only | This is [ethereum/EIPs#12187](https://github.com/ethereum/EIPs/pull/12187), applied ahead of its merge. The normative body, solc fork, revm fork, and `FrameTxLib` follow it exactly. |
| Fixture `TXPARAM` selectors moved from `0x0C`-`0x10` to `0x80`-`0x84` | Upstream assigned `TXPARAM(0x0C)` to `state_gas_left`, colliding with the fixture legacy nonce. The fixture block now sits at `0x80+`, clear of any plausible normative growth; `0x0D`-`0x7F` and `0x85+` halt as undefined. |
| State gas is metered for EIP-8141's own charge points only | The envelope carries per-frame `limits = [execution, state]`, budgets flow through `TXPARAM(0x0C)`/`FRAMEPARAM(0x09-0x0B)`, receipts report `gas_used = [execution, state]`, settlement and the payer charge include the state dimension, and the two account-creation charges (value-bearing frame, `APPROVE` sender creation) are charged at `STATE_BYTES_PER_NEW_ACCOUNT * CPSB`. Opcode-level EIP-8037 charging (`SSTORE`, code deposit) and cross-frame refill attribution are **pending**: EIP-8037 itself is not implemented in the forks, so those receipts' state dimension reflects only the frame-level charges. |
| The tooling fixture assigns `RECENTROOTREFLOAD` through `EVENTDATACOPY` to `0xb6`-`0xb9` | This is a local compiler/interpreter allocation after native `SIGDATACOPY`, documented only in the non-normative appendix. It does not assign final upstream opcodes or transaction fields. |
| Fixture `TXTRACE` uses flat gas `100`; `TXDIFF` uses `100` as its warm total | Direct TXDIFF selectors access host state on both diff hits and misses. Only the applicable EIP-2929 cold premium is added. The tests pin a local experiment; no consensus gas schedule is claimed. |
| The frame context is an `Arc`-backed scoped thread-local, not part of `TxEnv` | Putting it on shared revm transaction types broke unrelated crates. Scoped installation restores nested contexts on every return path; a native host can instead override `Host::frame_context()`. |
| Anvil activation is explicit | Frame transactions are disabled by default, require `--enable-frame-transactions`, and are rejected on Amsterdam node-level state-gas and non-Ethereum execution profiles (the frame-scoped state pools here do not compose with a node that meters EIP-8037 globally). Enabled pre-Amsterdam Ethereum nodes install the canonical `0x8141` verifier after inherited source replay. |
| Public-mempool rules are constants only | `MAX_VERIFY_GAS` and `MAX_VERIFY_STATE_GAS` are recorded in `foundry-primitives`. Anvil is a local mempool in the spec's sense — it accepts raw frame transactions without the public-propagation validation-prefix policy, which the spec explicitly permits for local pools. |
| Anvil already exposes the EIP-7997 factory behavior | The exact `0x4e59...956c` address and runtime are installed by Anvil's existing default CREATE2 deployer support. It is not Glamsterdam-gated and the injected account keeps nonce `0`, so this is functional reuse rather than exact EIP-7997 activation-state modeling. |
| EIP-7819 activation is explicit | Solc exposes `setdelegate(salt, target)` only at `@future`. REVM additionally requires a default-off configuration bit and Prague-or-later rules; Anvil exposes that bit as `--enable-eip7819` and preserves it across reset. |
| EIP-7851 uses toolkit-local opcode `0xf7` | The pinned EIP still declares `SETSELFDELEGATE_OPCODE = TBD`, while `0xf6` is already assigned to EIP-7819. The compiler, VM, and tests consistently label `0xf7` non-normative and must move together when upstream allocates a byte. |
| EIP-7851 activation is explicit and Ethereum-only | Solc exposes `setselfdelegate(target)` only at `@future`. REVM requires a default-off bit and Prague-or-later rules; Anvil exposes `--enable-eip7851` only on its canonical Ethereum profile and preserves it across reset. ECDSA-disabled senders remain usable by object-form simulation, impersonation, and Frame custom authentication, but signed Ethereum envelopes are rejected. |
| EIP-8151 activation is explicit and Ethereum-only | The proposal has no assigned execution fork. REVM and Foundry use a default-off bit under Prague-or-later rules without inventing a Hegotá `SpecId`; Anvil exposes `--enable-eip8151` only on its canonical Ethereum profile. Solc changes high-level `ecrecover` from `pure` to `view` only at `@future`. |
| Wire reference vectors are self-pinned | The previous go-ethereum cross-check (`leekt/go-ethereum@fix/eip8141-frame-tx`) implements the pinned envelope and predates the `fees`/`limits` format. `frame.rs` pins vectors generated by this implementation, including a dev-key-signed vector over the new canonical signature hash; regenerate the cross-check once the reference adopts the new wire format. |

The new normative warming text (sender/coinbase/precompiles pre-warmed, `ENTRY_POINT` and
frame targets not) matches behavior the revm fork already implements; see
`outer_sender_is_prewarmed_without_warming_zero_value_entry_point` and
`frame_two_target_is_warm_after_frame_one_success` in
`revm/crates/handler/src/mainnet_builder.rs`.

## Working-tree verification

These results were rerun on 2026-08-18 against the working-tree submodule sources, with
Foundry building revm from the sibling submodule path.

| Suite | Result |
|---|---|
| `contracts/` — debug `forge test`, native `@future` build (no external artifact script) | 99 passed, 0 failed, 0 skipped |
| `contracts/` — stock forge 1.7.1, `FOUNDRY_PROFILE=policy` | 14 passed, 0 failed |
| `contracts/` — native artifacts byte-identical to the retired script's (`OwnerAccount` 435 B, `MultisigAccount` 463 B, `SessionKeyAccount` 1448 B, `SponsoringPaymaster` 878 B) | Verified |
| `foundry` — `foundry-config --lib` | 231 passed, 0 failed |
| `foundry-core` — `foundry-compilers-artifacts-solc` EVM-version tests | 2 passed, 0 failed |
| `revm` — `cargo test --workspace --lib` | 520 passed, 0 failed |
| `foundry` — `foundry-primitives --lib` | 62 passed, 0 failed |
| `foundry` — anvil `frame_tx` backend units | 42 passed, 0 failed |
| `foundry` — anvil `frame_tx::` integrations | 27 passed, 0 failed |
| `foundry` — anvil library tests (excluding 3 process-exiting Clap tests) | 151 passed, 0 failed |
| `foundry` — anvil EIP-7819 (`setdelegate`) integrations | 4 passed, 0 failed |
| `foundry` — anvil EIP-7851 integrations | 11 passed, 0 failed |
| `foundry` — anvil EIP-8151 integrations | 8 passed, 0 failed |
| `foundry` — `foundry-evm-core --lib` | 80 passed, 0 failed |
| `foundry` — `foundry-cheatcodes --lib` | 70 passed, 0 failed |
| `foundry` — isolated `FrameTx.t.sol` fixture | 1 passed, 0 failed |
| `foundry` — workspace `cargo check --all-targets` | Clean |
| `solidity` — no rebase needed | The master-spec changes assign runtime selector values only; the instruction set, bytes, and arities are unchanged from `bd2feb352` |
