# Source pins and verification

EIP-8141, EIP-7819, EIP-7851, and EIP-8151 remain draft or pre-inclusion proposals. The root
repository records exact upstream bases so future changes can be diffed against known inputs,
alongside the submodule state that implements the current toolkit.

| Component | Pinned at | Date | Source |
|---|---|---|---|
| **EIP-8141 upstream base** | `f767a1e8078e17c9b381a91d35a09492189ede1b` | 2026-08-23 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8141.md`; Draft; [execution-specs tracker #2829](https://github.com/ethereum/execution-specs/issues/2829) open in the [Bogota milestone](https://github.com/ethereum/execution-specs/milestone/29) |
| **EIP-7819 upstream base** | `d420fc4b289e298682006b2ea09355065cf50f99` | 2026-04-09 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-7819.md` |
| **EIP-7851 upstream base** | `07f3bb3626d4db1f2ac501734fec5b3d32e185c5` | 2026-05-14 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-7851.md` |
| **EIP-8151 upstream base** | `bf7a4067f263bf7ce01c1511de48473e281d885d` | 2026-07-27 | [ethereum/EIPs](https://github.com/ethereum/EIPs) — `EIPS/eip-8151.md` |
| **Solidity gitlink (`develop`)** | `4c6c547d9a35b23807f421692ac65c35f26f3d54` | 2026-08-24 | [leekt/solidity `develop`](https://github.com/leekt/solidity/tree/develop), with the current EIP-8141 compiler work merged into the fork's default development branch |
| **revm gitlink (`main`)** | `3c82639a34a104af73d9aea0e9b50b005caace81` | 2026-08-24 | [leekt/revm `main`](https://github.com/leekt/revm/tree/main), with the current EIP-8141 execution work merged into the fork's default branch |
| **Foundry gitlink (`master`)** | `6cfbfd4e76cb275e1974caebfbf3b88d13c70c37` | 2026-08-24 | [leekt/foundry `master`](https://github.com/leekt/foundry/tree/master), with the current FrameTx/Anvil integration and primary-branch dependency pins |
| **foundry-core gitlink (`main`)** | `f415f6fef0a62f44c7faa83daa8e37b14f0e009b` | 2026-08-24 | [leekt/foundry-core `main`](https://github.com/leekt/foundry-core/tree/main), including experimental `@future` compiler support |
| **ZeroDev Kernel v3.3 dependency** | `cd697c7e21715d015e0643af22310a99aa17433b` | 2025-04-03 | [zerodevapp/kernel](https://github.com/zerodevapp/kernel/tree/cd697c7e21715d015e0643af22310a99aa17433b), pinned at `contracts/vendor/kernel-v3.3` for the real factory/proxy/ECDSA-root migration fixture |

[`spec/EIP8141.md`](spec/EIP8141.md) is not an exact vendored snapshot, but its normative
body matches the upstream base above. That upstream revision includes the standalone
`SIGDATACOPY` opcode at `0xb5`, frame-entry target access charging, active-precompile
dispatch before default code, uniform calldata-floor token accounting, and the current
validation-prefix opcode restrictions. It also carries the `fees` and `limits` sublists,
EIP-8037 state-gas budgets, two-dimensional receipts, `FRAME_TX_INTRINSIC_COST = 12000`,
`TX_VALUE_COST`, and the EIP-7825 execution cap. A separate non-normative subsection assigns
upstream-reserved signature scheme `0x03` to the toolkit's experimental ML-DSA-44 profile;
that local wire is not part of the normative upstream body. The
[final appendix](spec/EIP8141.md#toolkit-appendix-non-normative-tooling-fixture-profile)
documents the EIP-8250/8272/7906-inspired host context as a non-normative fixture only; it
does not claim transaction-wire support for those extensions.

## Reproducibility status

The root gitlinks and the four toolchain forks' published default branches are aligned at the
revisions above. A recursive clone of this root revision also fetches the pinned Kernel v3.3
dependency. Foundry patches all twelve REVM crates to
`3c82639a34a104af73d9aea0e9b50b005caace81` and resolves its seven foundry-core-derived
packages at `f415f6fef0a62f44c7faa83daa8e37b14f0e009b`; `Cargo.lock` records those exact
revisions. The root checkout points at those same REVM and foundry-core commits, plus
Foundry `6cfbfd4e76cb275e1974caebfbf3b88d13c70c37`, Solidity
`4c6c547d9a35b23807f421692ac65c35f26f3d54`, and Kernel v3.3
`cd697c7e21715d015e0643af22310a99aa17433b`.

The EIP-8141 work is published on `develop` for Solidity, `main` for revm and foundry-core,
and `master` for Foundry; consumers no longer need a feature-branch checkout. The fetch-only
workflow in
[`.claude/commands/sync-submodules.md`](.claude/commands/sync-submodules.md) reports upstream
movement without unexpectedly replacing a developer's checked-out submodule state.

The foundry-core feature delta adds the experimental `@future` EVM version in the compilers
crates, while its upstream base also contains newer fork-db and dependency work. This is
what lets `forge build` compile the frame contracts natively (`evm_version = "@future"` plus
`experimental = true` drive the patched solc over standard JSON). Foundry disables the now-unused
`alloy-evm/rpc` feature in two crates
because that upstream adapter constructs `TxEnv` directly and cannot initialize EIP-7851's
authentication marker. See
[guides/04-foundry.md](guides/04-foundry.md#how-the-context-reaches-the-evm) for why that
constraint shaped the design.

The pinned Foundry integration commit includes RustCrypto `ml-dsa` exactly at `0.1.1` for
the local native scheme. That dependency and scheme are not upstream EIP-8141 requirements.
The crate's maintainers explicitly warn that the implementation has not been independently
audited.

## Checking whether the spec moved

```bash
tools/check-spec-drift.sh
```

It fetches `EIPS/eip-8141.md` twice: once at the exact source pin above and once from current
`ethereum/EIPs` master. It diffs those two upstream files. The local overlay is reported as
such but is not used as the equality baseline, because its explanatory toolkit notes,
experimental ML-DSA-44 scheme, and appendix would otherwise be misreported as upstream
drift. Scheme `0x03` and the appendix remain expected local deltas.

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
| Signature schemes or the canonical sig hash | `foundry/crates/primitives/src/transaction/frame.rs`, its Cargo dependency pin, Anvil raw tests, any account reading `SIGPARAM`, `FrameTxLib.sol`, `FrameTest.sol`, and `contracts/docs/10-pq.md` |
| Anything about frame *transaction* execution | anvil: `foundry/crates/anvil/src/eth/backend/frame_tx.rs` and `crates/primitives/src/transaction/frame.rs`, plus the integration tests in `crates/anvil/tests/it/frame_tx.rs` |
| EIP-7819 address, gas, collision, code, nonce, or activation rules | `revm/crates/primitives/src/eip7819.rs`, `revm/crates/interpreter/src/instructions/host.rs`, `revm/crates/context/src/context.rs`, solc's instruction/version/gas metadata, and Anvil's `enable_eip7819` configuration/tests |
| EIP-7851 designation versions, sender/auth rules, opcode, gas, or activation | revm's bytecode/context/handler/interpreter EIP-7851 paths, solc's instruction/version/gas metadata, and Anvil's `enable_eip7851` configuration/admission/tests |
| EIP-8151 eligibility, ECRecover output/gas/warmth, or activation | `revm/crates/precompile/src/secp256k1.rs`, `revm/crates/handler/src/precompile_provider.rs`, Foundry's stateful precompile/replay/access-list paths, and solc's EVM-version/mutability/formal-model metadata |

## Local overlay and fixture differences

Native `SIGDATACOPY` is now part of the pinned upstream normative body. The ML-DSA-44 scheme
`0x03`, B6-B9 allocation, `0x80+` fixture selectors, extended context, provisional gas, and
the EIP-7851 opcode assignment below remain explicitly non-normative toolkit choices.

| Divergence | Why |
|---|---|
| The `APPROVE` opcode is spelled `approvetx` in Solidity and Yul | `approve` is the ERC-20 method name; reserving it as a compiler builtin would break a large share of existing contracts. The opcode byte `0xaa` is unchanged. |
| Signature scheme `0x03` is toolkit-local ML-DSA-44 | Upstream reserves the value. The local host requires exact `signature[2420] || publicKey[1312]`, derives `low20(keccak256(0x03 || publicKey))`, verifies pure FIPS 204 with empty context over the selected 32-byte message, and charges a provisional 50,000 gas. The pinned Foundry revision uses unaudited RustCrypto `ml-dsa = 0.1.1`; see `contracts/docs/10-pq.md`. |
| Fee fields are narrower at the Foundry/Alloy boundary | The EIP admits canonical fee scalars below `2**256`, and the Frame wire decoder initially represents them as 256-bit values. The current transaction-trait and REVM fee APIs are `u128`, so validation rejects any fee field above `u128::MAX`. This is an explicit executable-profile limit, not an upstream constraint. |
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

The pinned implementation has been aligned and rechecked against the current spec revision,
including uniform calldata-floor tokens, frame-entry target charging, active-precompile
dispatch before default code, and current validation-prefix restrictions. The verification
rows below record those reruns; the explicit local divergences in this table remain.

## Verification

These results record the 2026-08-24 upstream-rebased integration runs. Foundry resolves the
exact REVM and foundry-core revisions listed above.

| Suite | Result |
|---|---|
| `contracts/` — debug `forge test`, native `@future` build (no external artifact script) | 324 passed, 0 failed, 0 skipped across 19 suites; includes ten account targets (the original eight plus migrated Kernel v3.3 and an EIP-7702-delegated EOA), four paymaster suites, legacy-4337 preservation, and both rollback paths |
| `contracts/` — stock forge 1.7.1, `FOUNDRY_PROFILE=policy` | 14 passed, 0 failed |
| `contracts/` — current native deployed-bytecode artifact lengths | `OwnerAccount` 579 B; `MultisigAccount` 726 B; `SessionKeyAccount` 1,537 B; `SponsoringPaymaster` 878 B; `MLDSAAccount` 918 B; `MLDSAPaymaster` 1,254 B |
| `foundry-core` — `foundry-compilers-artifacts-solc` | 49 unit and 3 doc tests passed; one doc test intentionally ignored |
| `revm` — `cargo test --workspace --all-targets` | Passed; one pre-existing flaky RPC test ignored; focused frame opcode tests 29/29 and handler tests 60/60 |
| `foundry` — `foundry-primitives transaction::frame::tests --lib` | 30 passed, 0 failed |
| `foundry` — anvil `frame_tx` backend units | 44 passed, 0 failed |
| `foundry` — anvil `frame_tx::` integrations | 31 passed, 0 failed; includes production P256 and ML-DSA raw envelopes plus multisig-owner/index-1 payer reuse |
| `foundry` — `cargo check -p anvil --lib` | Passed against the pinned REVM and foundry-core revisions |
| `solidity` — solc/isoltest current-spec regression set | Patched solc built; exceptional-read optimizer 2/2, datacopy optimizer 4/4, dynamic frame gas 1/1, `SIGDATACOPY` gas 1/1, `@future` syntax/mutability 4/4, and Osaka rejection gate 1/1 passed |
| `tools/check-spec-drift.sh` | Clean against `ethereum/EIPs@f767a1e8078e17c9b381a91d35a09492189ede1b` |
