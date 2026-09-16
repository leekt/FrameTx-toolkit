# Source pins and verification

## Current specification snapshot

Checked 2026-09-16 against `ethereum/EIPs@90194cfa32915fc8a4ba5b7eea783774c2182b7f`.
The selected AA proposals are **8141, 7906, 8250, 8272, 8298 and 8151**. EIP-7819 and
EIP-7851 are excluded following their 2026-09-10 Hegotá DFI decisions. PFI proposals remain
eligible. [spec/sources.json](spec/sources.json) pins the selected sources and relevant gas/slot
dependencies by revision and checksum; [spec/inclusion.json](spec/inclusion.json) separately
pins the fork-inclusion evidence.

The [2026-09-16 review](spec/reviews/2026-09-16.md) refreshed EIP-8038's clarifications,
expanded coverage to 44 EIPs and verified all 9 inclusion records against
`ethereum/forkcast@ccfe45542b0753d3c7fd2c4a59411febeb883ac8`. The six selected AA proposals
and their inclusion decisions are unchanged. Source currency does not mean every tracked
proposal is fully implemented; the boundaries below still apply.

[spec/EIP8141.md](spec/EIP8141.md) is an exact upstream snapshot. Historical fixture-only
extensions are documented in [spec/TOOLKIT-FIXTURES.md](spec/TOOLKIT-FIXTURES.md), outside the
normative body. See [the spec baseline](spec/README.md) for current wire changes and limits.

## Reproducibility status

The following gitlinks pin the published toolchain, including the latest-spec migration
and removal of DFI features. Foundry's manifest and lockfile pin all twelve REVM crates
to the same published revision as the REVM submodule. Its foundry-core dependency remains
at the revision below. A recursive clone restores these sources without local path patches.

| Component | Pinned at | Date | Source |
|---|---|---|---|
| **Solidity gitlink (`develop`)** | `b10327c16ff95b15080ac5ba6abb1ff1ef3f06a3` | 2026-09-16 | [leekt/solidity `develop`](https://github.com/leekt/solidity/tree/develop), with the current EIP-8141 compiler work merged into the fork's default development branch |
| **revm gitlink (`main`)** | `cf4c47a0997295279a71a34ccc343b15c1d87e67` | 2026-09-16 | [leekt/revm `main`](https://github.com/leekt/revm/tree/main), with the current EIP-8141 execution work merged into the fork's default branch |
| **Foundry gitlink (`master`)** | `217047e6f39971f93c1aadba902751bfcbe37235` | 2026-09-16 | [leekt/foundry `master`](https://github.com/leekt/foundry/tree/master), with the current FrameTx/Anvil integration and primary-branch dependency pins |
| **foundry-core gitlink (`main`)** | `f415f6fef0a62f44c7faa83daa8e37b14f0e009b` | 2026-08-24 | [leekt/foundry-core `main`](https://github.com/leekt/foundry-core/tree/main), including experimental `@future` compiler support |
| **ZeroDev Kernel v3.3 Soldeer dependency** | `cd697c7e21715d015e0643af22310a99aa17433b` | 2025-04-03 | [zerodevapp/kernel](https://github.com/zerodevapp/kernel/tree/cd697c7e21715d015e0643af22310a99aa17433b), exact git revision in `contracts/soldeer.lock` for the real factory/proxy/ECDSA-root migration fixture |
| **Solady Soldeer dependency** | `3f2f5345261904463f5429c9031c3d2185c0f4fe` (`0.0.278`) | 2024-12-07 | [Vectorized/solady](https://github.com/Vectorized/solady/tree/3f2f5345261904463f5429c9031c3d2185c0f4fe), preserving the Kernel fixture's exact prior revision and providing the project-wide `solady/` import |
| **ExcessivelySafeCall Soldeer dependency** | `81cd99ce3e69117d665d7601c330ea03b97acce0` (`0.0.1`) | 2022-07-29 | [nomad-xyz/ExcessivelySafeCall](https://github.com/nomad-xyz/ExcessivelySafeCall/tree/81cd99ce3e69117d665d7601c330ea03b97acce0), exact git revision in `contracts/soldeer.lock` |
| **forge-std Soldeer dependency** | `1.16.2` | 2026-07-03 | Exact Soldeer registry archive, checksum, and extracted-folder integrity pinned in `contracts/soldeer.lock` |

Soldeer restores contract dependencies from `contracts/soldeer.lock`. The migration does not
change Kernel, Solady, forge-std, or ExcessivelySafeCall package pins.

## Checking whether the spec moved

```bash
tools/check-spec-drift.sh
tools/check-spec-drift.sh --offline
tools/check-spec-drift.sh --diff 8141 8250 8272
```

The checker verifies snapshot integrity, complete `requires` coverage, the EIP-8141 copy,
and fork-inclusion evidence. It resolves one current revision per upstream repository and
compares selected EIP contents and inclusion decisions. It exits 1 for upstream drift and
2 for invalid local data or fetch errors. It never updates snapshots or pins.

## What to re-check when the spec changes

| Spec area | Implementation |
|---|---|
| Opcodes, stack layouts and compiler effects | REVM bytecode/interpreter tables; Solidity Instruction, SemanticInformation, EVMDialect and gas metadata |
| Frame envelope, signature hash and gas limits | Foundry primitives `transaction/frame.rs`, its independent keyed RLP vector and Anvil raw-RPC tests |
| Nonce consumption, state-gas charges and rollback | Anvil `frame_tx.rs`, approval inspector, REVM journal protocol-storage methods |
| TXPARAM/FRAMEPARAM/SIGPARAM | REVM `frame_tx.rs`, FrameTxContext, Forge cheatcode, FrameTxLib |
| Receipts, EIP-7778 and EIP-8037 | Anvil settlement and block executor; frame receipts and cumulative accounting |
| Recent roots | Current EIP-8272 verifier-frame calldata and EIP-7843 slotNumber; no extra wire field or normative opcode |
| POST_TX | EIP-7906 fixture selectors; raw suffix execution, trace production and validation-preserving rollback remain pending |
| SETCODEFROM | EIP-8298 source/code retention, runtime/static restrictions, EIP-8038 gas; opcode remains TBD |
| ecRecover | EIP-8151 raw-code eligibility, access gas, warmth, replay and L2 state context |

## Current implementation limits

- Frame transactions execute on explicitly enabled pre-Amsterdam Ethereum profiles. State
  pools cover frame account creation and keyed-nonce first use, but full opcode-level
  EIP-8037 metering and cross-frame state refunds remain pending.
- Scalar EIP-8141 and keyed EIP-8250 are distinct accepted local wire layouts. This local
  development profile does not implement EIP-8250's fork-boundary switch, mempool eviction,
  or keyed public-pool replacement rules. The obsolete flat-fee/root envelope is rejected.
- Fee scalars are decoded as U256 but rejected above u128 because the Alloy/REVM fee APIs
  cannot represent larger values.
- EIP-7906 introspection and historical root data remain synthetic host fixtures; their
  provisional opcode allocation is not an upstream registry assignment. No raw POST_TX or
  current EIP-8272 canonical verifier is claimed.
- EIP-8298 is tracked as a specification; no executable opcode is assigned while upstream
  leaves it TBD.
- Anvil's existing EIP-7997 factory has the exact runtime/address but not the required
  fork-gated initialization and nonce 1.
- EIP-8151 remains explicitly enabled under Prague-or-later Ethereum rules; solc exposes its
  view mutability only at `@future`. EIP-7702's adopted ef0100 behavior remains supported.

## Latest review verification (2026-09-16)

The [specification review](spec/reviews/2026-09-16.md#verification) verified 44 EIP snapshots
and 9 fork-inclusion records against current upstream. All 447 tests run for the review
passed: native contracts 295, Anvil Frame backend 45, raw Frame RPC 32, EIP-8151 RPC 7,
REVM EIP-8038 constants 2, stock Osaka vFrame 54, and drift-checker regressions 12.
This was a focused review, not a complete toolchain rebuild or full EEST conformance run.

Before publication, locked dependency resolution confirmed all twelve REVM crates came from
the published revision above, with no unrelated lockfile changes. The 45 Anvil Frame backend
tests and 32 raw Frame RPC tests passed again against those git dependencies.

## Migration verification (2026-09-15)

Verified on 2026-09-15 from the modified checkout on macOS arm64, before publishing the
migration in the revisions above.

| Suite | Result |
|---|---|
| Toolchain builds | Patched solc, isoltest, Forge and Anvil built successfully |
| `contracts/` — patched Forge and solc, native `@future` | 295 passed across 15 suites; includes the current EIP-8250 Solidity selector wrappers |
| REVM bytecode, context, context-interface, handler, interpreter and precompile unit suites | 296 passed; includes unassigned DFI opcode bytes, separate legacy/keyed nonce selectors, and protocol storage warmth/original-value/rollback |
| Foundry primitives `transaction::frame::tests` | 35 passed; current keyed RLP/hash vector, malformed key-set rejection, legacy envelope rejection, state-gas bounds and recent-root verifier calldata |
| Anvil frame backend units | 45 passed |
| Anvil raw `frame_tx` integrations | 32 passed; fresh keys, key reuse, zero-key alias, approval surviving failed execution batches, default-code and contract sponsorship, receipts, traces and replay |
| Anvil EIP-8151 integrations | 7 passed; activation, exact raw-code eligibility, access gas/warmth, overrides, reset and replay |
| solc/isoltest focused regressions | 18 passed: frame syntax 4, ecRecover syntax/mutability 4, exceptional-read optimizer 2, copy optimizer 4, gas 2, Osaka gate 1, declined builtin rejection 1 |
| Anvil CLI | Both removed DFI flags rejected; FrameTx and EIP-8151 flags retained |
| Spec tooling | 4 tests passed; independent Python keyed vector matches Rust; EIP-8141 copy matches its snapshot; all 25 source checksums and live upstream comparisons clean |
| Formatting | Changed Rust files pass nightly rustfmt; changed Solidity files formatted with the contract project's configuration |

The compiler checks excluded semantic and SMT suites; they are not counted as passing.
Full Amsterdam opcode state-gas metering and public-pool/fork-boundary behavior remain
outside these results, as described above.

Representative commands (from the repository root):

```bash
cargo test --manifest-path revm/Cargo.toml --lib -p revm-bytecode -p revm-context \
  -p revm-context-interface -p revm-handler -p revm-interpreter -p revm-precompile
cargo test --manifest-path foundry/Cargo.toml --locked -p foundry-primitives \
  --lib transaction::frame::tests
cargo test --manifest-path foundry/Cargo.toml --locked -p anvil --lib --test it frame_tx
cargo test --manifest-path foundry/Cargo.toml --locked -p anvil --test it eip8151::
# From contracts/:
../foundry/target/debug/forge test --allow-local-compiler
```

## Published baseline verification (historical)

These results record the 2026-08-24 upstream-rebased integration runs before this migration.
They used the toolchain pins recorded in toolkit commit `4e8c359`.

| Suite | Result |
|---|---|
| `contracts/` — debug `forge test`, native `@future` build (no external artifact script) | 304 passed, 0 failed, 0 skipped across 17 suites; includes the account and paymaster matrices, legacy-4337 preservation, and both rollback paths |
| `contracts/` — stock forge 1.7.1, `FOUNDRY_PROFILE=policy` | 14 passed, 0 failed |
| `contracts/` — current native deployed-bytecode artifact lengths | `OwnerAccount` 579 B; `MultisigAccount` 726 B; `SessionKeyAccount` 1,537 B; `SponsoringPaymaster` 878 B |
| `foundry-core` — `foundry-compilers-artifacts-solc` | 49 unit and 3 doc tests passed; one doc test intentionally ignored |
| `revm` — `cargo test --workspace --all-targets` | Passed; one pre-existing flaky RPC test ignored; focused frame opcode tests 29/29 and handler tests 60/60 |
| `foundry` — `foundry-primitives transaction::frame::tests --lib` | 27 passed, 0 failed |
| `foundry` — anvil `frame_tx` backend units | 44 passed, 0 failed |
| `foundry` — anvil `frame_tx::` integrations | 31 passed, 0 failed; includes the production P256 raw envelope, multisig-owner/index-1 payer reuse, and a code-bearing sponsor contract in the `pay` frame creating a non-existent sender |
| `foundry` — `cargo check -p anvil --lib` | Passed against the pinned REVM and foundry-core revisions |
| `solidity` — solc/isoltest current-spec regression set | Patched solc built; exceptional-read optimizer 2/2, datacopy optimizer 4/4, dynamic frame gas 1/1, `SIGDATACOPY` gas 1/1, `@future` syntax/mutability 4/4, and Osaka rejection gate 1/1 passed |
| `tools/check-spec-drift.sh` | Clean against `ethereum/EIPs@7d1c8bfb945cbb53479217df3bf1da67b3aa445b` |
